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
--
-- Transferred seats (legacy only; core_seat_transfers finds each transfer line's root and the seats it
-- holds). The legacy site moved a seat to another event by creating a zero-total order whose parent is
-- the original paid order, and the instructor of the class attended earns the money, so the seat and its
-- money follow the transfer. Every row carries booking_kind:
--   purchase            an ordinary line. On a root's ticket lines, seats = seats_purchased less
--                       seats_transferred_out, and every amount is scaled to the seats that stayed.
--   transfer_in         a transfer line that holds seats. seats = seats held; purchased_at is the transfer
--                       order's own paid-or-created time; event_key is the new event. Its money is moved
--                       from the root: for each root line, that line's realized revenue, refund, processing
--                       fee and discount, each divided by the seats the line bought, times the seats this
--                       transfer takes from it. list_value = moved realized revenue + moved discount,
--                       service_fee = 0, fee_source = the root's. net_distributable and both shares are
--                       recomputed from the moved amounts. The transfer order's own line value is not revenue.
--                       When the root has no ticket lines it gives up nothing: the transfer holds its seats
--                       with all money 0 and fee_source 'none'.
--   transfer_superseded a transfer whose seat moved on again: no seat, no money, fee_source 'none', cancelled.
--   unpaid_zero_total   a transfer with no root, or a zero-total order with ticket value and no parent: kept
--                       exactly as any zero-total order (line value as realized revenue, no fee).
-- Which root seat goes to which transfer: the root's ticket lines give up the held seats in ascending order
-- of order_item_key (the first line gives up min(its seats, seats held), the next the remainder, ...), and
-- the transfer lines take them in holding order (latest first, core_seat_transfers.hold_rank). Laying both
-- out as consecutive seat positions from 0, a transfer takes from a root line exactly the positions the two
-- ranges share, so a transfer holding seats from two root lines gets the sum, and several transfers taking
-- seats from one root line each get per-seat x their own seats. Money is conserved per root.
-- A transfer_in line is cancelled when its moved refund reaches its moved realized revenue, or when the
-- transfer order's own status is refunded. A root line whose every seat was given up has seats 0 and is not
-- cancelled.
with event_by_legacy_id as (
  select wordpress_source_id as woo_event_id, event_key
  from {{ ref('core_events') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(event_source = 'cms', 0, 1), event_key) = 1
),
stripe as (
  select order_key,
    sum(fee) as fee,
    0 - sum(if(type in ('refund', 'payment_refund'), amount, 0)) as refunded,  -- 0 - x, not -x: no refund is 0.0, never -0.0
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
    coalesce(t.status not in ('Active', 'Paid', 'Used'), false) as ticket_refunded,
    cast(null as string) as order_status,
    false as zero_total_legacy
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
    false as ticket_refunded,
    o.status as order_status,
    coalesce(o.total, 0) = 0 as zero_total_legacy
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
    line_discount, order_discount, order_service_fee, order_refunded, refund_by_status, card_paid, ticket_refunded,
    order_status, zero_total_legacy
  from bronco
  union all
  select order_item_key, order_key, source_system,
    case item_kind_raw when 'ticket' then 'ticket' when 'gift_card' then 'gift_card' else 'other' end,
    event_key, purchased_at, seats, list_value, weight_base,
    line_discount, order_discount, order_service_fee, order_refunded, refund_by_status, card_paid, ticket_refunded,
    order_status, zero_total_legacy
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
),
transfers as (
  select * from {{ ref('core_seat_transfers') }}
),
rooted_transfer_orders as (
  select distinct order_key from transfers where root_order_key is not null
),
-- Seats each root ticket line gives up, taken from its lines in ascending order_item_key.
root_lines as (
  select f.*, h.seats_held_total,
    coalesce(sum(f.seats) over (partition by f.order_key order by f.order_item_key
      rows between unbounded preceding and 1 preceding), 0) as seats_before
  from fees f
  join (select root_order_key as order_key, sum(seats_held) as seats_held_total
        from transfers where root_order_key is not null group by 1) h using (order_key)
  where f.item_kind = 'ticket'
),
root_give_up as (
  select *, greatest(0, least(seats, seats_held_total - seats_before)) as seats_given_up
  from root_lines
),
-- Held seats of each transfer line, laid out in holding order.
held_lines as (
  select t.*,
    coalesce(sum(t.seats_held) over (partition by t.root_order_key order by t.hold_rank
      rows between unbounded preceding and 1 preceding), 0) as held_before
  from transfers t
  where t.root_order_key is not null
),
-- Seats a transfer line takes from each root line: the overlap of the root line's given-up positions
-- [seats_before, seats_before + seats_given_up) with the transfer's held positions [held_before,
-- held_before + seats_held).
pairs as (
  select h.order_item_key, r.realized_revenue, r.refunded_amount, r.processing_fee, r.discount, r.seats as root_line_seats,
    greatest(0, least(r.seats_before + r.seats_given_up, h.held_before + h.seats_held)
      - greatest(r.seats_before, h.held_before)) as seats_taken
  from held_lines h
  join root_give_up r on r.order_key = h.root_order_key
),
moved as (
  select order_item_key,
    sum(coalesce(safe_divide(realized_revenue, root_line_seats), 0) * seats_taken) as realized_revenue,
    sum(coalesce(safe_divide(refunded_amount, root_line_seats), 0) * seats_taken) as refunded_amount,
    sum(coalesce(safe_divide(processing_fee, root_line_seats), 0) * seats_taken) as processing_fee,
    sum(coalesce(safe_divide(discount, root_line_seats), 0) * seats_taken) as discount
  from pairs
  group by order_item_key
),
root_fee_source as (
  select order_key, any_value(fee_source) as fee_source from fees group by order_key
),
-- Every row that is not a rooted transfer line: ordinary lines, root lines (scaled to the seats that
-- stayed), and unpaid zero-total lines.
kept_lines as (
  select f.*, coalesce(g.seats_given_up, 0) as seats_given_up,
    -- the share of the line's amounts that stays with it; exactly 1 when no seat was given up
    if(coalesce(g.seats_given_up, 0) = 0, 1.0, (f.seats - g.seats_given_up) / f.seats) as keep,
    rt.order_key is not null as in_rooted_transfer_order
  from fees f
  left join transfers t using (order_item_key)
  left join rooted_transfer_orders rt on rt.order_key = f.order_key
  left join root_give_up g using (order_item_key)
  where t.root_order_key is null
),
kept as (
  select f.order_item_key, f.order_key, f.source_system, f.item_kind, f.event_key, f.purchased_at,
    case
      when f.zero_total_legacy and not f.in_rooted_transfer_order
        and logical_or(f.item_kind = 'ticket' and f.weight_base > 0) over (partition by f.order_key)
        then 'unpaid_zero_total'
      else 'purchase'
    end as booking_kind,
    f.seats as seats_purchased,
    f.seats_given_up as seats_transferred_out,
    f.seats - f.seats_given_up as seats,
    f.keep * f.list_value as list_value,
    f.keep * f.discount as discount,
    f.keep * f.service_fee as service_fee,
    f.keep * f.realized_revenue as realized_revenue,
    f.keep * f.refunded_amount as refunded_amount,
    f.keep * f.processing_fee as processing_fee,
    f.fee_source,
    cast(null as string) as transfer_root_order_key,
    -- A bronco item's seat is decided by its own ticket status alone. A legacy item has no ticket
    -- status, so (and only for legacy) a refund reaching its own realized revenue cancels it. A root
    -- line that gave up every seat is not cancelled.
    if(f.seats_given_up > 0 and f.seats_given_up >= f.seats, false,
      f.ticket_refunded or (f.source_system = 'woocommerce' and f.realized_revenue > 0
        and f.refunded_amount >= f.realized_revenue - 0.005)) as is_cancelled
  from kept_lines f
),
transferred as (
  select f.order_item_key, f.order_key, f.source_system, f.item_kind, t.event_key, t.transferred_at as purchased_at,
    if(t.seats_held > 0, 'transfer_in', 'transfer_superseded') as booking_kind,
    0 as seats_purchased,
    0 as seats_transferred_out,
    t.seats_held as seats,
    coalesce(m.realized_revenue, 0) + coalesce(m.discount, 0) as list_value,
    coalesce(m.discount, 0) as discount,
    0.0 as service_fee,
    coalesce(m.realized_revenue, 0) as realized_revenue,
    coalesce(m.refunded_amount, 0) as refunded_amount,
    coalesce(m.processing_fee, 0) as processing_fee,
    -- a root with no ticket lines gives up nothing, so its transfers hold seats with no money and no fee
    if(t.seats_held > 0 and m.order_item_key is not null, rf.fee_source, 'none') as fee_source,
    t.root_order_key as transfer_root_order_key,
    t.seats_held = 0
      or (coalesce(m.realized_revenue, 0) > 0 and coalesce(m.refunded_amount, 0) >= coalesce(m.realized_revenue, 0) - 0.005)
      or f.order_status = 'refunded' as is_cancelled
  from transfers t
  join fees f using (order_item_key)
  left join moved m using (order_item_key)
  left join root_fee_source rf on rf.order_key = t.root_order_key
  where t.root_order_key is not null
),
assembled as (
  select * from kept
  union all
  select * from transferred
)
select order_item_key, order_key, source_system,
  {{ platform_era_of_source('source_system') }} as platform_era,
  item_kind, event_key, purchased_at, date(purchased_at, 'America/New_York') as purchase_date, seats,
  booking_kind, seats_purchased, seats_transferred_out, transfer_root_order_key,
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
  is_cancelled
from assembled
