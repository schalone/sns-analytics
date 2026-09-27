{{ config(tags=['hourly'], partition_by={'field': 'snapshot_date', 'data_type': 'date', 'granularity': 'month'}, cluster_by=['event_key']) }}
-- The booking curve: one row per event per calendar day, from the earlier of the first sale and
-- curve_days before the event, up to the event date. Capacity is the final recorded capacity.
with sales as (
  select event_key, sale_date,
    sum(net_seats) as seats,
    sum(realized_revenue - refunded_amount) as revenue,
    sum(sns_share) as sns_share
  from {{ ref('core_bookings') }}
  where event_key is not null
  group by 1, 2
),
events as (
  select e.event_key, e.event_date, e.capacity, e.platform_era,
    least(date_sub(e.event_date, interval {{ var('curve_days') }} day), coalesce(min(s.sale_date), e.event_date)) as curve_start
  from {{ ref('core_events') }} e
  left join sales s using (event_key)
  where e.has_event_date
  group by 1, 2, 3, 4
),
spine as (
  select e.event_key, e.event_date, e.capacity, e.platform_era, snapshot_date
  from events e, unnest(generate_date_array(e.curve_start, e.event_date)) as snapshot_date
),
spend as (
  select event_key, date, sum(spend) as spend
  from {{ ref('core_ad_spend_allocation') }}
  where event_key is not null
  group by 1, 2
),
spend_days as (
  select distinct date from {{ ref('core_ad_spend_allocation') }}
),
daily as (
  select sp.event_key, sp.snapshot_date, sp.event_date, sp.capacity, sp.platform_era,
    coalesce(s.seats, 0) as seats_sold_that_day,
    coalesce(s.revenue, 0) as revenue_that_day,
    coalesce(s.sns_share, 0) as sns_share_that_day,
    coalesce(a.spend, 0) as ad_spend_that_day,
    d.date is not null as has_spend_data_that_day
  from spine sp
  left join sales s on s.event_key = sp.event_key and s.sale_date = sp.snapshot_date
  left join spend a on a.event_key = sp.event_key and a.date = sp.snapshot_date
  left join spend_days d on d.date = sp.snapshot_date
),
running as (
  select *,
    sum(seats_sold_that_day) over w as cumulative_seats,
    sum(revenue_that_day) over w as cumulative_revenue,
    sum(sns_share_that_day) over w as cumulative_sns_share,
    sum(ad_spend_that_day) over w as cumulative_ad_spend
  from daily
  window w as (partition by event_key order by snapshot_date rows between unbounded preceding and current row)
)
select event_key, snapshot_date, date_diff(event_date, snapshot_date, day) as days_until_event, platform_era, capacity,
  seats_sold_that_day, cumulative_seats,
  if(capacity > 0, greatest(capacity - cumulative_seats, 0), null) as remaining_capacity,
  if(capacity > 0, least(round(cumulative_seats / capacity, 6), 1.0), null) as pct_sold,
  round(cumulative_revenue, 6) as cumulative_realized_revenue,
  round(cumulative_sns_share, 6) as cumulative_sns_share,
  round(ad_spend_that_day, 6) as ad_spend_that_day,
  round(cumulative_ad_spend, 6) as cumulative_ad_spend,
  has_spend_data_that_day
from running
