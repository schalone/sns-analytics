-- ECON-001 worked events, counted by hand on 2026-09-28 from the archive tables (woo orders, order
-- line items and products), bypassing every core model; see docs/econ-001-validation.md.
-- Events are resolved through their WordPress event id (core_events.wordpress_source_id), not their key:
-- today they are keyed woo-ev-<id>, and once the CMS export carries them they are keyed by CMS GUID.
--   WordPress event 269869  no transfers in or out: 15 seats bought in 12 orders at 70.00.
--   WordPress event 259204  14 seats bought at 65.00 plus 3 seats transferred in: two from one root
--                           that paid 140.00 for 2 seats (70.00 each) and one from a root that paid 65.00
--                           for 1 seat, whose earlier transfer to another event was superseded by this one.
-- Pinned here at error severity: seats and money, which do not depend on the event's date or capacity.
-- Pace and sell-out (which move if the CMS dates or sizes the event differently from the archive) are
-- pinned at warn severity in assert_worked_event_pace.sql.
-- Returns a row when an event is missing or any pinned figure differs from the hand count.
with expected as (
  select * from unnest([
    struct('269869' as wordpress_source_id, 15 as seats, 1050.00 as realized, 0 as transfer_seats, 0.00 as transfer_realized),
    struct('259204', 17, 1115.00, 3, 205.00)
  ])
),
events as (
  select wordpress_source_id, event_key from {{ ref('core_events') }} where wordpress_source_id is not null
),
transfers as (
  select event_key, sum(net_seats) as transfer_seats, sum(realized_revenue) as transfer_realized
  from {{ ref('core_bookings') }}
  where booking_kind = 'transfer_in'
  group by 1
)
select x.wordpress_source_id, if(e.event_key is null, 'missing', 'mismatch') as problem
from expected x
left join events ev using (wordpress_source_id)
left join {{ ref('core_event_economics') }} e on e.event_key = ev.event_key
left join transfers t on t.event_key = ev.event_key
where e.event_key is null
   or e.seats_sold != x.seats
   or abs(e.realized_revenue - x.realized) >= 0.005
   or coalesce(t.transfer_seats, 0) != x.transfer_seats
   or abs(coalesce(t.transfer_realized, 0) - x.transfer_realized) >= 0.005
