-- ECON-001 worked events, counted by hand on 2026-09-28 from the archive tables (woo orders, order
-- line items and products), bypassing every core model; see docs/econ-001-validation.md.
-- Events are identified by key only.
--   woo-ev-269869  sold out, no transfers in or out: 15 seats bought in 12 orders at 70.00.
--   woo-ev-259204  sold out, 14 seats bought at 65.00 plus 3 seats transferred in: two from one root
--                  that paid 140.00 for 2 seats (70.00 each) and one from a root that paid 65.00 for
--                  1 seat, whose earlier transfer to another event was superseded by this one.
-- Returns a row when an event is missing or any pinned figure differs from the hand count.
with expected as (
  select * from unnest([
    struct('woo-ev-269869' as event_key, 15 as seats, 1050.00 as realized, 17 as first_sale_days_before,
           9 as days_before_at_sellout, 0 as transfer_seats, 0.00 as transfer_realized),
    struct('woo-ev-259204', 17, 1115.00, 59, 2, 3, 205.00)
  ])
),
transfers as (
  select event_key, sum(net_seats) as transfer_seats, sum(realized_revenue) as transfer_realized
  from {{ ref('core_bookings') }}
  where booking_kind = 'transfer_in'
  group by 1
)
select x.event_key, if(e.event_key is null, 'missing', 'mismatch') as problem
from expected x
left join {{ ref('core_event_economics') }} e using (event_key)
left join transfers t using (event_key)
where e.event_key is null
   or e.seats_sold != x.seats
   or abs(e.realized_revenue - x.realized) >= 0.005
   or e.first_sale_days_before != x.first_sale_days_before
   or e.days_before_at_sellout != x.days_before_at_sellout
   or not e.sold_out
   or coalesce(t.transfer_seats, 0) != x.transfer_seats
   or abs(coalesce(t.transfer_realized, 0) - x.transfer_realized) >= 0.005
