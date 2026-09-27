{{ config(tags=['hourly']) }}
-- Economics per order item, for every item type, in both eras. Order-level amounts (discount,
-- service fee, and bronco refunds) and Stripe fees are split across the order's items in proportion
-- to line value, falling back to an equal split when every line in the order is worth zero.
-- core_bookings keeps the ticket rows; the conservation test runs here, where all items are present.
--
-- Which orders count: bronco orders with source = 'webapp' and status in ('Paid', 'Partial Refund',
-- 'Refunded'); legacy orders with status in ('completed', 'processing', 'refunded') and total >= 0,
-- with no date cutoff -- the archive already ends at the platform cutover.
--
-- Refunds: a bronco item's refunded_amount is the order's succeeded CMS refund total, split by
-- weight. A legacy item's refunded_amount is the order's matched Stripe refund total, split by
-- weight, when that total is above zero; otherwise, on an order whose own status is 'refunded', each
-- item refunds its OWN realized revenue in full, not a weighted share of the order's `total` -- some
-- refunded legacy orders carry a total of 0, or a total below their own line value, so the order
-- total is not a reliable amount to split across items.
--
-- Seats: a bronco item holds a seat only while its ticket is Active, Paid or Used, or when the item
-- has no matching ticket row at all -- any other ticket status cancels it, regardless of how much of
-- the order was refunded. A legacy item has no ticket status to check, so it is cancelled only when
-- its own refunded_amount reaches its own realized_revenue.
--
-- Zero-total orders: an order can be paid by gift card, credit or voucher and carry a total of 0
-- while its line items still carry real value; those items keep their full realized revenue. With no
-- card payment there is no Stripe fee to estimate, so they get fee_source = 'none' -- the same
-- fee_source a genuinely zero-value item gets (realized_revenue distinguishes the two: above zero
-- for a zero-total-but-valuable order, exactly zero for a real comp).
--
-- Legacy line totals: the archive's line_total is always the realized value for a line. list_value
-- is the larger of it and the line's own subtotal, so a line whose subtotal happens to be below its
-- own line_total (an archive data quirk) still produces realized_revenue = line_total and a discount
-- that is never negative.
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
    false as refund_by_status,                        -- bronco refunds always come from CMS refunds, never a status fallback
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
    greatest(coalesce(li.subtotal, li.line_total, 0), coalesce(li.line_total, 0)) as list_value,
    coalesce(li.line_total, 0) as weight_base,
    greatest(coalesce(li.subtotal, li.line_total, 0), coalesce(li.line_total, 0)) - coalesce(li.line_total, 0) as line_discount,
    0.0 as order_discount,
    0.0 as order_service_fee,
    coalesce(s.refunded, 0) as order_refunded,
    coalesce(s.refunded, 0) <= 0 and o.status = 'refunded' as refund_by_status,
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
    line_discount, order_discount, order_service_fee, order_refunded, refund_by_status, card_paid, ticket_refunded
  from bronco
  union all
  select order_item_key, order_key, source_system,
    case item_kind_raw when 'ticket' then 'ticket' when 'gift_card' then 'gift_card' else 'other' end,
    event_key, purchased_at, seats, list_value, weight_base,
    line_discount, order_discount, order_service_fee, order_refunded, refund_by_status, card_paid, ticket_refunded
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
    list_value - coalesce(line_discount, order_discount * w) + order_service_fee * w as realized_revenue
  from weighted
),
refunded as (
  select *,
    -- Legacy's status-refund case refunds each item's own realized revenue in full, not a weighted
    -- share of the order's (unreliable) total; every other case is the usual weighted split.
    case when refund_by_status then realized_revenue else order_refunded * w end as refunded_amount
  from revenue
),
fees as (
  select r.*,
    case
      when coalesce(s.has_charge, false) then s.fee * r.w
      when r.card_paid then (sum(r.realized_revenue) over (partition by r.order_key) * {{ var('legacy_fee_rate') }} + {{ var('legacy_fee_fixed') }}) * r.w
      else 0
    end as processing_fee,
    case when coalesce(s.has_charge, false) then 'actual' when r.card_paid then 'estimated' else 'none' end as fee_source
  from refunded r
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
  -- A bronco item's seat is decided by its own ticket status alone. A legacy item has no ticket
  -- status, so (and only for legacy) a refund reaching its own realized revenue cancels it.
  ticket_refunded or (source_system = 'woocommerce' and realized_revenue > 0 and refunded_amount >= realized_revenue - 0.005) as is_cancelled
from fees
