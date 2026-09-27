-- Rolling bookings up to events must not create or lose money or seats.
with e as (
  select sum(seats_sold) as seats, sum(sns_share) as sns_share, sum(realized_revenue) as revenue from {{ ref('core_event_economics') }}
),
b as (
  select sum(net_seats) as seats, sum(sns_share) as sns_share, sum(realized_revenue) as revenue from {{ ref('core_bookings') }} where event_key is not null
)
select e.seats as event_seats, b.seats as booking_seats, e.sns_share as event_sns, b.sns_share as booking_sns
from e cross join b
where e.seats != b.seats or abs(e.sns_share - b.sns_share) > 1 or abs(e.revenue - b.revenue) > 1
