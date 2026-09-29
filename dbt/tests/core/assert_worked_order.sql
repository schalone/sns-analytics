-- ECON-001 worked orders. Each expected amount was computed by hand from Stripe's own figures
-- (scripts/econ_check_order.py --legacy <id>) on 2026-09-28; see docs/econ-001-validation.md.
-- Orders are identified by key only; no personal data is recorded.
--   woo-348795  plain purchase: 2 lines, discounted, no refund. Stripe: charged 119.00, fee 3.75.
--   woo-345525  refunded purchase: 1 seat. Stripe: charged 65.00, refunded 65.00, fee 2.19, refund fee 0.00.
--   woo-373065  root that bought 2 seats and gave 1 up to a transfer. Stripe: charged 150.00, fee 4.65.
--               Half of each figure stays on the root's booking; half moves to the transfer booking.
-- Returns a row for every pinned figure that is missing or differs from the hand figure by a cent or more.
with expected as (
  select * from unnest([
    struct('woo-348795 purchase' as label, 'woo-348795' as order_key, cast(null as string) as root_key, 'purchase' as booking_kind,
           2 as seats, 119.00 as realized, 0.00 as refunded, 3.75 as fee, 115.25 as net, 46.10 as sns_share, 69.15 as instructor_share),
    struct('woo-345525 refunded', 'woo-345525', null, 'purchase', 0, 65.00, 65.00, 2.19, -2.19, -0.876, -1.314),
    struct('woo-373065 root after transfer', 'woo-373065', null, 'purchase', 1, 75.00, 0.00, 2.325, 72.675, 29.07, 43.605),
    struct('woo-373065 transfer booking', null, 'woo-373065', 'transfer_in', 1, 75.00, 0.00, 2.325, 72.675, 29.07, 43.605)
  ])
),
got as (
  select e.label,
    count(b.booking_key) as n,
    logical_and(b.booking_kind = e.booking_kind) as kind_ok,
    sum(b.net_seats) as seats,
    sum(b.realized_revenue) as realized, sum(b.refunded_amount) as refunded, sum(b.processing_fee) as fee,
    sum(b.net_distributable) as net, sum(b.sns_share) as sns_share, sum(b.instructor_share) as instructor_share
  from expected e
  left join {{ ref('core_bookings') }} b
    on (e.order_key is not null and b.order_key = e.order_key)
    or (e.root_key is not null and b.transfer_root_order_key = e.root_key and b.order_key != e.root_key)
  group by 1
)
select e.label, g.n, g.kind_ok, g.seats, g.realized, g.refunded, g.fee, g.net, g.sns_share, g.instructor_share
from expected e
join got g using (label)
where g.n = 0
   or not g.kind_ok
   or g.seats != e.seats
   or abs(g.realized - e.realized) >= 0.005
   or abs(g.refunded - e.refunded) >= 0.005
   or abs(g.fee - e.fee) >= 0.005
   or abs(g.net - e.net) >= 0.005
   or abs(g.sns_share - e.sns_share) >= 0.005
   or abs(g.instructor_share - e.instructor_share) >= 0.005
