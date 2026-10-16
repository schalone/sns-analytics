-- ECON-001 worked orders. Each expected amount was computed by hand from Stripe's own figures
-- (scripts/econ_check_order.py --legacy <id>) on 2026-09-28; see docs/econ-001-validation.md.
-- Orders are identified by key only; no personal data is recorded.
--   woo-348795  plain purchase: 2 lines, discounted, no refund. Stripe: charged 119.00, fee 3.75.
--   woo-345525  refunded purchase: 1 seat. Stripe: charged 65.00, refunded 65.00, fee 2.19, refund fee 0.00.
--   woo-373065  root that bought 2 seats and gave 1 up to a transfer. Stripe: charged 150.00, fee 4.65.
--               Half of each figure stays on the root's booking; half moves to the transfer booking.
-- New-platform (bronco) orders, checked by hand on 2026-10-16 (scripts/econ_check_order.py --bronco <number>):
--   SNS-26-017929  2 seats at 50.00, 70.00 order discount, no refund. Stripe: charged 30.00, fee 1.17.
--   SNS-26-018542  1 seat at 65.00 transferred to another class and attended there. Stripe: charged 65.00,
--                  fee 2.19. The class attended holds the seat and all the money; the original holds neither.
-- event_key, when set, pins a figure to one event's bookings of the order.
-- Returns a row for every pinned figure that is missing or differs from the hand figure by a cent or more.
with expected as (
  select * from unnest([
    struct('woo-348795 purchase' as label, 'woo-348795' as order_key, cast(null as string) as root_key, cast(null as string) as event_key,
           'purchase' as booking_kind, 2 as seats, 119.00 as realized, 0.00 as refunded, 3.75 as fee, 115.25 as net, 46.10 as sns_share, 69.15 as instructor_share),
    struct('woo-345525 refunded', 'woo-345525', null, null, 'purchase', 0, 65.00, 65.00, 2.19, -2.19, -0.876, -1.314),
    struct('woo-373065 root after transfer', 'woo-373065', null, null, 'purchase', 1, 75.00, 0.00, 2.325, 72.675, 29.07, 43.605),
    struct('woo-373065 transfer booking', null, 'woo-373065', null, 'transfer_in', 1, 75.00, 0.00, 2.325, 72.675, 29.07, 43.605),
    struct('SNS-26-017929 discounted purchase', 'ca4fc3a3-decf-4ea9-bd85-a8045c61cab3', null, null, 'purchase',
           2, 30.00, 0.00, 1.17, 28.83, 11.532, 17.298),
    struct('SNS-26-018542 class transferred away from', 'a0902b33-6651-4360-a6f3-7cf87475fdca', null,
           '34063b67-dc7e-4d3b-b64c-8209eb4e8137', 'purchase', 0, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00),
    struct('SNS-26-018542 class attended', 'a0902b33-6651-4360-a6f3-7cf87475fdca', null,
           'eb464e8d-2f11-43ff-9bcf-286f4f153314', 'purchase', 1, 65.00, 0.00, 2.19, 62.81, 25.124, 37.686)
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
    on ((e.order_key is not null and b.order_key = e.order_key)
     or (e.root_key is not null and b.transfer_root_order_key = e.root_key and b.order_key != e.root_key))
   and (e.event_key is null or b.event_key = e.event_key)
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
