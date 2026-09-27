{{ config(tags=['hourly']) }}
-- core_event_economics plus a benchmark against similar events: same metro, category and weekday
-- class (weekend vs weekday), in the peer_window_days before the event. Peers require a non-null
-- metro_key and a non-null event_date on both sides, and a non-null, matching is_weekend; an event
-- missing either carries no peers of its own and is nobody's peer. category is compared null-safely,
-- since a null category should still match other events with no category rather than match nothing.
-- A benchmark is null unless at least peer_min_count peer events were found for that event; the
-- count is of peer events, not of non-null values, and medians ignore nulls.
with e as (
  select * from {{ ref('core_event_economics') }}
),
pairs as (
  select e.event_key, p.utilisation, p.days_before_at_50pct, p.sns_share_per_available_seat, p.contribution_per_available_seat
  from e
  join e as p
    on e.metro_key is not null and p.metro_key is not null and p.metro_key = e.metro_key
   and coalesce(p.category, '') = coalesce(e.category, '')
   and e.is_weekend is not null and p.is_weekend is not null and p.is_weekend = e.is_weekend
   and p.event_key != e.event_key
   and e.event_date is not null and p.event_date is not null
   and p.event_date between date_sub(e.event_date, interval {{ var('peer_window_days') }} day) and date_sub(e.event_date, interval 1 day)
),
stats as (
  select distinct event_key,
    count(*) over (partition by event_key) as peer_count,
    percentile_cont(utilisation, 0.5) over (partition by event_key) as median_utilisation,
    percentile_cont(days_before_at_50pct, 0.5) over (partition by event_key) as median_days_before_at_50pct,
    percentile_cont(sns_share_per_available_seat, 0.5) over (partition by event_key) as median_sns_share_per_available_seat,
    percentile_cont(contribution_per_available_seat, 0.5) over (partition by event_key) as median_contribution_per_available_seat
  from pairs
),
peers as (
  select event_key, peer_count,
    if(peer_count >= {{ var('peer_min_count') }}, round(median_utilisation, 6), null) as peer_median_utilisation,
    if(peer_count >= {{ var('peer_min_count') }}, round(median_days_before_at_50pct, 6), null) as peer_median_days_before_at_50pct,
    if(peer_count >= {{ var('peer_min_count') }}, round(median_sns_share_per_available_seat, 6), null) as peer_median_sns_share_per_available_seat,
    if(peer_count >= {{ var('peer_min_count') }}, round(median_contribution_per_available_seat, 6), null) as peer_median_contribution_per_available_seat
  from stats
)
select e.*,
  coalesce(p.peer_count, 0) as peer_count,
  p.peer_median_utilisation, p.peer_median_days_before_at_50pct,
  p.peer_median_sns_share_per_available_seat, p.peer_median_contribution_per_available_seat,
  round(e.utilisation - p.peer_median_utilisation, 6) as utilisation_vs_peers,
  round(e.sns_share_per_available_seat - p.peer_median_sns_share_per_available_seat, 6) as sns_share_per_seat_vs_peers,
  round(e.contribution_per_available_seat - p.peer_median_contribution_per_available_seat, 6) as contribution_per_seat_vs_peers
from e
left join peers p using (event_key)
