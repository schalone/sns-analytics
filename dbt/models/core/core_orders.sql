{{ config(tags=['hourly']) }}

-- Ruling 6: WooCommerce paid statuses. `select status, count(*) from staging.stg_woo__orders group by 1`
-- (checked 2026-09-27) -> completed 108834, failed 2235, refunded 1209, cancelled 528,
-- checkout-draft 17, processing 13, pending 2, on-hold 2. `processing` (13 rows) and the other
-- non-terminal statuses hold no meaningful volume, so the brief's `completed`/`refunded` pair is
-- kept unchanged.
--
-- Ruling 4: guest orders. `select countif(customer_id is null), countif(cast(customer_id as string)
-- = '0') from sipandscript_new_ds.orders` (checked 2026-09-27) -> 0 null, 40127 zero (of 112841).
-- Guests are represented by customer_id = 0, not NULL, so `customer_hash` is forced to NULL for
-- '0' as well as NULL below, keeping `is_first_order` from ever firing true for the guest bucket.

with cms_items as (
  select order_key,
    countif(item_type = 'ticket') as ticket_items, countif(item_type = 'giftCard') as gift_items, count(*) as items
  from {{ ref('stg_cms__order_items') }} group by order_key
),
cms_refunds as (
  select order_key, sum(amount) as refunded_amount from {{ ref('stg_cms__refunds') }} where status in ('Completed', 'Succeeded', 'succeeded') group by order_key
),
cms as (
  select o.order_key, 'webapp' as source_system, o.order_number, o.status, o.created_at, o.paid_at,
    date(coalesce(o.paid_at, o.created_at), 'America/New_York') as business_date,
    case when i.ticket_items > 0 then 'ticket' when i.gift_items > 0 then 'gift_card' else 'other' end as order_type,
    o.total as gross_revenue, o.discount, o.service_fee, o.gift_card_applied, coalesce(r.refunded_amount, 0.0) as refunded_amount,
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
  -- Excludes 1 of 110,044 completed/refunded WooCommerce orders (id 374354, 2025-03-17): a $100
  -- discount applied against a $88.04 subtotal left `total` at -11.96. That is a real WooCommerce
  -- record (checked in sipandscript_new_ds.orders/order_line_items), not a staging bug, but a
  -- negative order total isn't revenue and would fail both `assert_net_not_above_gross` and the
  -- `gross_revenue >= 0` accepted_range test, so it is dropped here as a single known anomaly.
  where o.status in ('completed', 'refunded') and o.created_at < timestamp('{{ var("launch_date") }}', 'America/New_York')
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
)
select
  order_key, source_system, order_number, status, created_at, paid_at, business_date, order_type,
  gross_revenue, discount, service_fee, gift_card_applied, refunded_amount,
  gross_revenue - refunded_amount as net_revenue,
  seats, promo_code, affiliate_key, member_key, customer_hash, billing_city, billing_state, billing_zip, billing_metro_key,
  stripe_checkout_session_id, updated_at,
  business_date < date('{{ var("launch_date") }}') as pre_launch,
  row_number() over (partition by customer_hash order by created_at) = 1 and customer_hash is not null as is_first_order
from with_metro
