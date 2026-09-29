{{ config(tags=['hourly']) }}

-- Ruling 6, superseded by final-review I7: WooCommerce paid statuses. `select status, count(*) from
-- staging.stg_woo__orders group by 1` (checked 2026-09-27) -> completed 108834, failed 2235, refunded 1209,
-- cancelled 528, checkout-draft 17, processing 13, pending 2, on-hold 2. The 13 `processing` orders all fall in
-- the last three days before cutover ($3,120.37): paid orders the archive never saw completed. They count as paid
-- alongside `completed` and `refunded`. The archive ends at cutover, so no archive-side date filter is applied:
-- 13 completed orders dated 2026-06-19 (New York) were lost to it while their CMS copies are excluded as
-- `wordpressImport`. `platform_era` is by source_system (woocommerce -> legacy_event_tickets, else
-- bronco), not business_date, so this archive/CMS split has no bearing on it.
--
-- Final-review I6: CMS literals are the CMS's own spellings (sns-analytics-export-api, read-only):
--   order statuses counted as paid: Paid, Partial Refund, Refunded (WordPressImportService.IsPaidOrderStatus,
--     WordPressImportService.cs:2670-2675; Paid set at CheckoutService.cs:1425; Refunded / Partial Refund at
--     AdminCommerceService.cs:220 and :231);
--   refund statuses: Pending, Succeeded, Failed; only Succeeded returns money (AdminCommerceService.cs:214 sums
--     Status = 'Succeeded' for the order's refunded total).
-- The full value lists are enforced by accepted_values tests on the staging models.
--
-- Ruling 4: guest orders. `select countif(customer_id is null), countif(cast(customer_id as string)
-- = '0') from sipandscript_new_ds.orders` (checked 2026-09-27) -> 0 null, 40127 zero (of 112841).
-- Guests are represented by customer_id = 0, not NULL, so `customer_hash` is forced to NULL for
-- '0' as well as NULL below, keeping `is_first_order` from ever firing true for the guest bucket.

-- Legacy seat transfers: a transfer order with a root (core_seat_transfers) moved a seat of an earlier
-- paid order to another event. It is not a purchase: is_transfer is true, transfer_root_order_key names
-- the original order, it is never is_first_order, and the first-order ranking ignores it. A transfer with
-- no root is an ordinary order here (is_transfer false).

with cms_items as (
  select order_key,
    countif(item_type = 'ticket') as ticket_items, countif(item_type = 'giftCard') as gift_items, count(*) as items
  from {{ ref('stg_cms__order_items') }} group by order_key
),
cms_refunds as (
  select order_key, sum(amount) as refunded_amount from {{ ref('stg_cms__refunds') }} where status = 'Succeeded' group by order_key
),
cms as (
  select o.order_key, 'webapp' as source_system, o.order_number, o.status, o.created_at, o.paid_at,
    date(coalesce(o.paid_at, o.created_at), 'America/New_York') as business_date,
    case when i.ticket_items > 0 then 'ticket' when i.gift_items > 0 then 'gift_card' else 'other' end as order_type,
    o.total as gross_revenue, o.discount, o.service_fee, o.gift_card_applied, coalesce(r.refunded_amount, 0.0) as refunded_amount,
    -- one exported ticket order item is exactly one seat: the CMS creates one OrderItem per Ticket
    -- (CheckoutService.cs:229-250, one Ticket plus one Type = "Ticket" OrderItem per seat) and the export emits quantity 1 for every item
    -- (AnalyticsCommerceExportService.cs:154), so seats = the number of ticket items.
    coalesce(i.ticket_items, 0) as seats, o.promo_code, o.affiliate_key, o.member_key, o.customer_hash, o.billing_city, o.billing_state, o.billing_zip,
    o.stripe_checkout_session_id, o.updated_at
  from {{ ref('stg_cms__orders') }} o
  left join cms_items i using (order_key)
  left join cms_refunds r using (order_key)
  where o.source = 'webapp' and o.status in ('Paid', 'Partial Refund', 'Refunded')
),
woo_items as (
  select li.order_key,
    sum(case when p.product_kind = 'ticket' then li.quantity else 0 end) as seats,
    sum(case when p.product_kind = 'ticket' then li.line_total else 0 end) as ticket_amount,
    sum(case when p.product_kind = 'gift_card' then li.line_total else 0 end) as gift_amount,
    sum(case when p.product_kind = 'materials' then li.line_total else 0 end) as materials_amount
  from {{ ref('stg_woo__order_line_items') }} li left join {{ ref('stg_woo__products') }} p using (woo_product_id) group by li.order_key
),
woo as (
  select o.order_key, 'woocommerce' as source_system, o.woo_order_id as order_number, o.status, o.created_at, o.paid_at,
    date(coalesce(o.paid_at, o.created_at), 'America/New_York') as business_date,
    case when i.ticket_amount >= greatest(i.gift_amount, i.materials_amount) and i.seats > 0 then 'ticket'
         when i.gift_amount >= i.materials_amount and i.gift_amount > 0 then 'gift_card'
         when i.materials_amount > 0 then 'materials' else 'other' end as order_type,
    o.total as gross_revenue, o.discount, 0.0 as service_fee, 0.0 as gift_card_applied,
    case when o.status = 'refunded' then o.total else 0.0 end as refunded_amount,
    coalesce(i.seats, 0) as seats, cast(null as string) as promo_code, cast(null as string) as affiliate_key, cast(null as string) as member_key,
    case when o.woo_customer_id is null or o.woo_customer_id = '0' then null else o.woo_customer_id end as customer_hash,
    o.billing_city, o.billing_state, o.billing_zip, cast(null as string) as stripe_checkout_session_id, o.updated_at
  from {{ ref('stg_woo__orders') }} o left join woo_items i using (order_key)
  -- Excludes 1 of the completed/processing/refunded WooCommerce orders (id 374354, 2025-03-17): a $100
  -- discount applied against a $88.04 subtotal left `total` at -11.96. That is a real WooCommerce
  -- record (checked in sipandscript_new_ds.orders/order_line_items), not a staging bug, but a
  -- negative order total isn't revenue and would fail both `assert_net_not_above_gross` and the
  -- `gross_revenue >= 0` accepted_range test, so it is dropped here as a single known anomaly.
  where o.status in ('completed', 'processing', 'refunded')
    and o.total >= 0
),
unioned as (select * from cms union all select * from woo),
-- Ruling 5: the brief's per-order correlated subquery against core_metros
-- ("select ... from core_metros where ... order by ... limit 1" referencing the outer zip's
-- geog) is rejected by BigQuery: "Correlated subqueries that reference other tables are not
-- supported unless they can be de-correlated". Rewritten as a zip -> nearest-metro dimension
-- (join + qualify row_number()), then left-joined onto orders by zip code, which preserves the
-- brief's LEFT JOIN semantics (orders with no zip match, or no metro within radius, keep
-- billing_metro_key = NULL). With core_metros empty today (raw_cms has no rows), this join
-- matches nothing and billing_metro_key is NULL for every order, as expected.
zip_geo as (
  select zip_code, st_geogpoint(internal_point_lon, internal_point_lat) as geog from {{ source('public_geo', 'zip_codes') }}
),
zip_metro as (
  select z.zip_code, m.metro_key
  from zip_geo z
  join {{ ref('core_metros') }} m on st_dwithin(z.geog, m.center_geog, m.radius_miles * 1609.344)
  qualify row_number() over (partition by z.zip_code order by st_distance(z.geog, m.center_geog)) = 1
),
with_metro as (
  select u.*, zm.metro_key as billing_metro_key
  from unioned u
  left join zip_metro zm on zm.zip_code = left(u.billing_zip, 5)
),
transfer_roots as (
  select order_key, any_value(root_order_key) as transfer_root_order_key
  from {{ ref('core_seat_transfers') }}
  where root_order_key is not null
  group by order_key
)
select
  w.order_key, w.source_system, w.order_number, w.status, w.created_at, w.paid_at, w.business_date, w.order_type,
  w.gross_revenue, w.discount, w.service_fee, w.gift_card_applied, w.refunded_amount,
  w.gross_revenue - w.refunded_amount as net_revenue,
  w.seats, w.promo_code, w.affiliate_key, w.member_key, ci.customer_hash, coalesce(ci.identity_source, 'unresolved') as identity_source,
  w.billing_city, w.billing_state, w.billing_zip, w.billing_metro_key,
  w.stripe_checkout_session_id, w.updated_at,
  {{ platform_era_of_source('w.source_system') }} as platform_era,
  ci.customer_hash is not null and tr.order_key is null
    and row_number() over (partition by ci.customer_hash, tr.order_key is null order by w.created_at, w.order_key) = 1 as is_first_order,
  tr.order_key is not null as is_transfer,
  tr.transfer_root_order_key
from with_metro w
left join {{ ref('core_customer_identity') }} ci on ci.order_key = w.order_key
left join transfer_roots tr on tr.order_key = w.order_key
