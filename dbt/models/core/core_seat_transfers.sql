{{ config(tags=['hourly']) }}
-- One row per ticket line of a legacy transfer order. The legacy site moved a seat to another event by
-- creating a new order with a total of zero whose parent is the original paid order; the seat, and the
-- money paid for it, follow the transfer.
--
-- A transfer order is a legacy order that counts as paid (status completed, processing or refunded and
-- total >= 0), has a total of exactly zero, has a parent, and carries at least one ticket line with a
-- line total above zero. Its root is the first ancestor that counts as paid with a total above zero,
-- reached by following parents through other transfer orders, at most five steps up (depth = the number
-- of steps). A transfer order with no such ancestor has no root (root_order_key and depth are NULL).
--
-- Seat holding, per root. First, a transfer order that is the direct parent of another transfer order with
-- the same root was itself transferred: it is superseded, holds nothing and is left out of the ranking.
-- The root's other transfer lines, of any depth, are ranked latest first by the transfer order's own
-- paid-or-created time, ties broken by the numeric order id descending (a key that does not parse as
-- woo-<digits> sorts last), then line key ascending (hold_rank). Walking that ranking, each line holds
-- min(its seats, seats still available), where seats available starts at the ticket seats the root
-- bought. A line that holds nothing is superseded: its seat moved on again. A root with no ticket lines
-- at all bought no seat to count against: each of its transfers that was not itself transferred holds
-- all its own seats (and, in core_order_item_economics, no money). A line with no root holds nothing and
-- is not superseded.
--
-- New-platform transfers are recorded on tickets and are not handled here.
with event_by_legacy_id as (
  select wordpress_source_id as woo_event_id, event_key
  from {{ ref('core_events') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(event_source = 'cms', 0, 1), event_key) = 1
),
lines as (
  select li.order_item_key, li.order_key, m.event_key,
    coalesce(li.quantity, 1) as seats,
    coalesce(li.line_total, 0) as line_total,
    coalesce(p.product_kind, 'other') = 'ticket' as is_ticket
  from {{ ref('stg_woo__order_line_items') }} li
  left join {{ ref('stg_woo__products') }} p using (woo_product_id)
  left join event_by_legacy_id m on m.woo_event_id = p.woo_event_id
),
order_lines as (
  select order_key,
    sum(if(is_ticket, seats, 0)) as ticket_seats,
    logical_or(is_ticket) as has_ticket_lines,
    logical_or(is_ticket and line_total > 0) as has_ticket_value
  from lines
  group by order_key
),
nodes as (
  select o.order_key, o.parent_order_key,
    coalesce(o.paid_at, o.created_at) as transferred_at,
    o.status in ('completed', 'processing', 'refunded') and o.total > 0 as is_root,
    o.status in ('completed', 'processing', 'refunded') and o.total = 0 and o.parent_order_key is not null
      and coalesce(l.has_ticket_value, false) as is_transfer,
    coalesce(l.ticket_seats, 0) as ticket_seats,
    coalesce(l.has_ticket_lines, false) as has_ticket_lines
  from {{ ref('stg_woo__orders') }} o
  left join order_lines l using (order_key)
),
-- Five fixed steps up the parent chain. Each step continues only through a transfer order.
walk as (
  select t.order_key, t.parent_order_key, t.transferred_at,
    case
      when p1.is_root then p1.order_key
      when p1.is_transfer and p2.is_root then p2.order_key
      when p1.is_transfer and p2.is_transfer and p3.is_root then p3.order_key
      when p1.is_transfer and p2.is_transfer and p3.is_transfer and p4.is_root then p4.order_key
      when p1.is_transfer and p2.is_transfer and p3.is_transfer and p4.is_transfer and p5.is_root then p5.order_key
    end as root_order_key,
    case
      when p1.is_root then 1
      when p1.is_transfer and p2.is_root then 2
      when p1.is_transfer and p2.is_transfer and p3.is_root then 3
      when p1.is_transfer and p2.is_transfer and p3.is_transfer and p4.is_root then 4
      when p1.is_transfer and p2.is_transfer and p3.is_transfer and p4.is_transfer and p5.is_root then 5
    end as depth
  from nodes t
  left join nodes p1 on p1.order_key = t.parent_order_key
  left join nodes p2 on p2.order_key = p1.parent_order_key
  left join nodes p3 on p3.order_key = p2.parent_order_key
  left join nodes p4 on p4.order_key = p3.parent_order_key
  left join nodes p5 on p5.order_key = p4.parent_order_key
  where t.is_transfer
),
-- Transfer orders that were themselves transferred: the direct parent of another transfer with the same root.
transferred_again as (
  select distinct parent_order_key as order_key, root_order_key
  from walk
  where root_order_key is not null
),
transfer_lines as (
  select l.order_item_key, l.order_key, w.root_order_key, l.event_key, w.transferred_at, l.seats, w.depth,
    r.ticket_seats as root_seats, r.has_ticket_lines as root_has_ticket_lines,
    ta.order_key is not null as was_transferred_again,
    safe_cast(regexp_extract(l.order_key, r'^woo-([0-9]+)$') as int64) as order_id
  from walk w
  join lines l using (order_key)
  left join nodes r on r.order_key = w.root_order_key
  left join transferred_again ta on ta.order_key = w.order_key and ta.root_order_key = w.root_order_key
  where l.is_ticket
),
ranked as (
  select *,
    if(root_order_key is null or was_transferred_again, null,
      row_number() over (partition by root_order_key, was_transferred_again
        order by transferred_at desc, order_id desc nulls last, order_item_key)) as hold_rank
  from transfer_lines
),
held as (
  select *,
    case
      when root_order_key is null or was_transferred_again then 0
      when not root_has_ticket_lines then seats
      else greatest(0, least(seats, root_seats - coalesce(sum(seats) over (
        partition by root_order_key, was_transferred_again order by hold_rank
        rows between unbounded preceding and 1 preceding), 0)))
    end as seats_held
  from ranked
)
select order_item_key, order_key, root_order_key, event_key, transferred_at, seats, seats_held,
  root_order_key is not null and seats_held = 0 as is_superseded,
  depth, hold_rank
from held
