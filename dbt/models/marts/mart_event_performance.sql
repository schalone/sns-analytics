{{ config(tags=['hourly']) }}
-- core_event_economics plus a benchmark against similar events: same metro, category and weekday
-- class (weekend vs weekday), in the peer_window_days before the event. Peers require a non-null
-- metro_key and a non-null event_date on both sides, and a non-null, matching is_weekend; an event
-- missing either carries no peers of its own and is nobody's peer. category is compared null-safely,
-- since a null category should still match other events with no category rather than match nothing.
--
-- A peer must also have taken place: its event_date is before as_of, which is today in New York unless
-- the var as_of_date is set. Its status must not be one of the var peer_excluded_statuses (trash, pending,
-- private, draft, auto-draft, cancelled, canceled), compared case-insensitively; a NULL status is allowed.
-- An event that sold nothing is still a peer: a flop is information.
--
-- peer_count is the number of peer events. Each benchmark is NULL unless at least peer_min_count peers have
-- a non-null value for THAT measure; peer_count_utilisation, peer_count_pace (days_before_at_50pct),
-- peer_count_sns_share (sns_share_per_available_seat) and peer_count_contribution
-- (contribution_per_available_seat) are those counts. Medians ignore nulls.
{%- set as_of_date = var('as_of_date', none) %}
{%- set as_of = "date '" ~ as_of_date ~ "'" if as_of_date else "current_date('America/New_York')" %}
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
   and p.event_date < {{ as_of }}
   and (p.status is null or lower(p.status) not in (
     {%- for s in var('peer_excluded_statuses') %}'{{ s | lower }}'{{ ', ' if not loop.last }}{% endfor -%}
   ))
),
stats as (
  select distinct event_key,
    count(*) over (partition by event_key) as peer_count,
    count(utilisation) over (partition by event_key) as peer_count_utilisation,
    count(days_before_at_50pct) over (partition by event_key) as peer_count_pace,
    count(sns_share_per_available_seat) over (partition by event_key) as peer_count_sns_share,
    count(contribution_per_available_seat) over (partition by event_key) as peer_count_contribution,
    percentile_cont(utilisation, 0.5) over (partition by event_key) as median_utilisation,
    percentile_cont(days_before_at_50pct, 0.5) over (partition by event_key) as median_days_before_at_50pct,
    percentile_cont(sns_share_per_available_seat, 0.5) over (partition by event_key) as median_sns_share_per_available_seat,
    percentile_cont(contribution_per_available_seat, 0.5) over (partition by event_key) as median_contribution_per_available_seat
  from pairs
),
peers as (
  select event_key, peer_count, peer_count_utilisation, peer_count_pace, peer_count_sns_share, peer_count_contribution,
    if(peer_count_utilisation >= {{ var('peer_min_count') }}, round(median_utilisation, 6), null) as peer_median_utilisation,
    if(peer_count_pace >= {{ var('peer_min_count') }}, round(median_days_before_at_50pct, 6), null) as peer_median_days_before_at_50pct,
    if(peer_count_sns_share >= {{ var('peer_min_count') }}, round(median_sns_share_per_available_seat, 6), null) as peer_median_sns_share_per_available_seat,
    if(peer_count_contribution >= {{ var('peer_min_count') }}, round(median_contribution_per_available_seat, 6), null) as peer_median_contribution_per_available_seat
  from stats
)
select e.*,
  coalesce(p.peer_count, 0) as peer_count,
  coalesce(p.peer_count_utilisation, 0) as peer_count_utilisation,
  coalesce(p.peer_count_pace, 0) as peer_count_pace,
  coalesce(p.peer_count_sns_share, 0) as peer_count_sns_share,
  coalesce(p.peer_count_contribution, 0) as peer_count_contribution,
  p.peer_median_utilisation, p.peer_median_days_before_at_50pct,
  p.peer_median_sns_share_per_available_seat, p.peer_median_contribution_per_available_seat,
  round(e.utilisation - p.peer_median_utilisation, 6) as utilisation_vs_peers,
  round(e.sns_share_per_available_seat - p.peer_median_sns_share_per_available_seat, 6) as sns_share_per_seat_vs_peers,
  round(e.contribution_per_available_seat - p.peer_median_contribution_per_available_seat, 6) as contribution_per_seat_vs_peers
from e
left join peers p using (event_key)
