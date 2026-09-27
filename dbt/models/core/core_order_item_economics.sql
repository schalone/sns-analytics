{{ config(tags=['hourly']) }}
-- Economics per order item, for every item type, in both eras. Order-level amounts (discount,
-- service fee, refund, Stripe fee) are split across the order's items in proportion to line value.
-- core_bookings keeps the ticket rows; the conservation test runs here, where all items are present.
--
-- Controller decisions (task 6, 2026-09-27):
--  - "Which orders count" follows core_orders.sql, not the original brief: the legacy branch below
--    uses core_orders' own paid-status list (completed, processing, refunded) and total >= 0, with
--    NO archive-side date filter (core_orders.sql's ruling: the archive already ends at cutover).
--  - CMS refunds count only when status = 'Succeeded' (core_orders.sql's ruling: 'Completed' is not
--    a real CMS refund status; only 'Succeeded' returns money per AdminCommerceService.cs:214).
--  - Bronco seat rule: an item holds a seat only while its ticket is Active, Paid or Used, or when
--    the item has no matching ticket row at all. Any other status (Refunded, Transferred, ...)
--    cancels it.
with event_by_legacy_id as (
  select wordpress_source_id as woo_event_id, event_key
  from {{ ref('core_events') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(event_source = 'cms', 0, 1), event_key) = 1
),
stripe as (
  select order_key,
    sum(fee) as fee,
    -sum(if(type in ('refund', 'payment_refund'), amount, 0)) as refunded,
    countif(source_object = 'charge') > 0 as has_charge
  from {{ ref('core_stripe_transactions') }}
  where order_key is not null
  group by order_key
),
cms_refunds as (
  select order_key, sum(amount) as refunded
  from {{ ref('stg_cms__refunds') }}
  where status = 'Succeeded'
  group by order_key
),
bronco as (
  select i.order_item_key, i.order_key, 'webapp' as source_system,
    case i.item_type when 'ticket' then 'ticket' when 'giftCard' then 'gift_card' else 'other' end as item_kind,
    i.event_key,
    coalesce(o.paid_at, o.created_at) as purchased_at,
    coalesce(i.quantity, 1) as seats,
    coalesce(i.line_total, 0) as list_value,
    coalesce(i.line_total, 0) as weight_base,
    cast(null as float64) as line_discount,           -- bronco discount is order-level; allocated below
    coalesce(o.discount, 0) as order_discount,
    coalesce(o.service_fee, 0) as order_service_fee,
    coalesce(r.refunded, 0) as order_refunded,
    coalesce(o.total, 0) > 0 as card_paid,
    coalesce(t.status not in ('Active', 'Paid', 'Used'), false) as ticket_refunded
  from {{ ref('stg_cms__order_items') }} i
  join {{ ref('stg_cms__orders') }} o using (order_key)
  left join cms_refunds r using (order_key)
  left join {{ ref('stg_cms__tickets') }} t using (ticket_key)
  where o.source = 'webapp' and o.status in ('Paid', 'Partial Refund', 'Refunded')
),
legacy as (
  select li.order_item_key, li.order_key, 'woocommerce' as source_system,
    coalesce(p.product_kind, 'other') as item_kind_raw,
    m.event_key,
    coalesce(o.paid_at, o.created_at) as purchased_at,
    coalesce(li.quantity, 1) as seats,
    coalesce(li.subtotal, li.line_total, 0) as list_value,
    coalesce(li.line_total, 0) as weight_base,
    greatest(coalesce(li.subtotal, li.line_total, 0) - coalesce(li.line_total, 0), 0) as line_discount,
    0.0 as order_discount,
    0.0 as order_service_fee,
    case when coalesce(s.refunded, 0) > 0 then s.refunded when o.status = 'refunded' then coalesce(o.total, 0) else 0 end as order_refunded,
    coalesce(o.total, 0) > 0 as card_paid,
    false as ticket_refunded
  from {{ ref('stg_woo__order_line_items') }} li
  join {{ ref('stg_woo__orders') }} o using (order_key)
  left join {{ ref('stg_woo__products') }} p using (woo_product_id)
  left join event_by_legacy_id m on m.woo_event_id = p.woo_event_id
  left join stripe s using (order_key)
  where o.status in ('completed', 'processing', 'refunded')
    and o.total >= 0
),
items as (
  select order_item_key, order_key, source_system, item_kind, event_key, purchased_at, seats, list_value, weight_base,
    line_discount, order_discount, order_service_fee, order_refunded, card_paid, ticket_refunded
  from bronco
  union all
  select order_item_key, order_key, source_system,
    case item_kind_raw when 'ticket' then 'ticket' when 'gift_card' then 'gift_card' else 'other' end,
    event_key, purchased_at, seats, list_value, weight_base,
    line_discount, order_discount, order_service_fee, order_refunded, card_paid, ticket_refunded
  from legacy
),
weighted as (
  select *,
    case when sum(weight_base) over (partition by order_key) > 0
         then weight_base / sum(weight_base) over (partition by order_key)
         else 1 / count(*) over (partition by order_key) end as w
  from items
),
revenue as (
  select *,
    coalesce(line_discount, order_discount * w) as discount,
    order_service_fee * w as service_fee,
    list_value - coalesce(line_discount, order_discount * w) + order_service_fee * w as realized_revenue,
    order_refunded * w as refunded_amount
  from weighted
),
fees as (
  select r.*,
    case
      when coalesce(s.has_charge, false) then s.fee * r.w
      when r.card_paid then (sum(r.realized_revenue) over (partition by r.order_key) * {{ var('legacy_fee_rate') }} + {{ var('legacy_fee_fixed') }}) * r.w
      else 0
    end as processing_fee,
    case when coalesce(s.has_charge, false) then 'actual' when r.card_paid then 'estimated' else 'none' end as fee_source
  from revenue r
  left join stripe s using (order_key)
)
select order_item_key, order_key, source_system,
  {{ platform_era_of_source('source_system') }} as platform_era,
  item_kind, event_key, purchased_at, date(purchased_at, 'America/New_York') as purchase_date, seats,
  round(list_value, 6) as list_value,
  round(discount, 6) as discount,
  round(service_fee, 6) as service_fee,
  round(realized_revenue, 6) as realized_revenue,
  round(refunded_amount, 6) as refunded_amount,
  round(processing_fee, 6) as processing_fee,
  fee_source,
  round(realized_revenue - refunded_amount - processing_fee, 6) as net_distributable,
  round({{ var('sns_share_rate') }} * (realized_revenue - refunded_amount - processing_fee), 6) as sns_share,
  round({{ var('instructor_share_rate') }} * (realized_revenue - refunded_amount - processing_fee), 6) as instructor_share,
  ticket_refunded or (realized_revenue > 0 and refunded_amount >= realized_revenue - 0.005) as is_cancelled
from fees
