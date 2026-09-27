-- On the event date the curve must hold exactly the seats the bookings hold.
with last_day as (
  select event_key, cumulative_seats from {{ ref('core_event_daily') }} where days_until_event = 0
),
booked as (
  select event_key, sum(net_seats) as seats from {{ ref('core_bookings') }} where event_key is not null group by 1
)
select l.event_key, l.cumulative_seats, coalesce(b.seats, 0) as booked_seats
from last_day l
left join booked b using (event_key)
where l.cumulative_seats != coalesce(b.seats, 0)
