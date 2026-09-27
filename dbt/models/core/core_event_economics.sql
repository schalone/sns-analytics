{{ config(tags=['hourly']) }}
-- One row per event in either era: what it was, how it sold, what it earned, how fast it filled.
-- Instructor materials appear only as an estimate on the instructor's side and are never subtracted
-- from any S&S figure. When there is no ad spend data for the selling window, contribution is null
-- rather than overstated.
with b as (
  select event_key,
    sum(net_seats) as seats_sold,
    count(*) as bookings,
    count(distinct customer_hash) as customers,
    sum(realized_revenue) as realized_revenue,
    sum(refunded_amount) as refunded_amount,
    sum(processing_fee) as processing_fee,
    safe_divide(sum(if(fee_source = 'actual', processing_fee, 0)), sum(processing_fee)) as fee_actual_share,
    sum(net_distributable) as net_distributable,
    sum(sns_share) as sns_share,
    sum(instructor_share) as instructor_share
  from {{ ref('core_bookings') }}
  where event_key is not null
  group by event_key
),
d as (
  select event_key,
    max(if(cumulative_seats > 0, days_until_event, null)) as first_sale_days_before,
    max(if(pct_sold >= 0.25, days_until_event, null)) as days_before_at_25pct,
    max(if(pct_sold >= 0.50, days_until_event, null)) as days_before_at_50pct,
    max(if(pct_sold >= 0.75, days_until_event, null)) as days_before_at_75pct,
    max(if(pct_sold >= 1.0, days_until_event, null)) as days_before_at_sellout,
    sum(ad_spend_that_day) as allocated_ad_spend,
    logical_or(has_spend_data_that_day) as has_ad_spend_data
  from {{ ref('core_event_daily') }}
  group by event_key
),
joined as (
  select e.event_key, e.title, e.event_date, e.start_at,
    extract(hour from datetime(e.start_at, e.time_zone)) as start_hour_local,
    format_date('%A', e.event_date) as weekday,
    extract(dayofweek from e.event_date) in (1, 7) as is_weekend,
    extract(month from e.event_date) as month,
    {{ season('e.event_date') }} as season,
    e.venue_key, e.metro_key, e.instructor_key, e.category, e.event_type, e.theme, e.status,
    e.platform_era, e.has_event_date, e.capacity, e.capacity_source, e.ticket_price,
    coalesce(b.seats_sold, 0) as seats_sold,
    coalesce(b.bookings, 0) as bookings,
    coalesce(b.customers, 0) as customers,
    coalesce(b.realized_revenue, 0) as realized_revenue,
    coalesce(b.refunded_amount, 0) as refunded_amount,
    coalesce(b.processing_fee, 0) as processing_fee,
    b.fee_actual_share,
    coalesce(b.net_distributable, 0) as net_distributable,
    coalesce(b.sns_share, 0) as sns_share,
    coalesce(b.instructor_share, 0) as instructor_share,
    coalesce(d.has_ad_spend_data, false) as has_ad_spend_data,
    if(coalesce(d.has_ad_spend_data, false), d.allocated_ad_spend, null) as allocated_ad_spend,
    d.first_sale_days_before, d.days_before_at_25pct, d.days_before_at_50pct, d.days_before_at_75pct, d.days_before_at_sellout
  from {{ ref('core_events') }} e
  left join b using (event_key)
  left join d using (event_key)
)
select event_key, title, event_date, start_at, start_hour_local, weekday, is_weekend, month, season,
  venue_key, metro_key, instructor_key, category, event_type, theme, status, platform_era, has_event_date,
  capacity, capacity_source, ticket_price,
  seats_sold, bookings, customers,
  if(capacity > 0, round(seats_sold / capacity, 6), null) as utilisation,
  case
    when capacity is null or capacity <= 0 then null
    when seats_sold / capacity < 0.40 then '<40'
    when seats_sold / capacity < 0.60 then '40-60'
    when seats_sold / capacity < 0.80 then '60-80'
    when seats_sold / capacity < 0.95 then '80-95'
    else '95-100'
  end as utilisation_band,
  coalesce(capacity > 0 and seats_sold >= capacity, false) as sold_out,
  round(realized_revenue, 6) as realized_revenue,
  round(refunded_amount, 6) as refunded_amount,
  round(processing_fee, 6) as processing_fee,
  round(fee_actual_share, 6) as fee_actual_share,
  round(net_distributable, 6) as net_distributable,
  round(sns_share, 6) as sns_share,
  round(instructor_share, 6) as instructor_share,
  round(seats_sold * {{ var('materials_per_seat') }}, 6) as instructor_materials_estimate,
  round(allocated_ad_spend, 6) as allocated_ad_spend,
  has_ad_spend_data,
  round(sns_share, 6) as sns_contribution_before_ads,
  round(sns_share - allocated_ad_spend, 6) as sns_contribution,
  round(safe_divide(sns_share, if(capacity > 0, capacity, null)), 6) as sns_share_per_available_seat,
  round(safe_divide(sns_share, nullif(seats_sold, 0)), 6) as sns_share_per_sold_seat,
  round(safe_divide(sns_share - allocated_ad_spend, if(capacity > 0, capacity, null)), 6) as contribution_per_available_seat,
  round(safe_divide(sns_share - allocated_ad_spend, nullif(seats_sold, 0)), 6) as contribution_per_sold_seat,
  first_sale_days_before, days_before_at_25pct, days_before_at_50pct, days_before_at_75pct, days_before_at_sellout
from joined
