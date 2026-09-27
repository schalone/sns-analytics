-- Controller ruling 1: the `google_ads` dataset has no tables until a human authorises the
-- BigQuery Data Transfer (see dbt_project.yml `vars.google_ads_enabled`, default false). With the
-- var false, `google_campaign_stats` and `google_campaign` below are empty selects typed to match
-- the real transfer tables' documented columns (`segments_date`, `campaign_id`,
-- `metrics_cost_micros`, `metrics_impressions`, `metrics_clicks`, `campaign_name`) so the project
-- builds and this model produces zero Google rows. Flip the var to true once the transfer has run;
-- confirm column names/types against `google_ads.INFORMATION_SCHEMA.COLUMNS` at that point.
-- Final-review I8: the stats table can hold several rows per (segments_date, campaign_id) (one per ad network
-- type / device segment), so it is summed to one row per campaign-day BEFORE the name join and the union, and
-- the campaign table is a daily SNAPSHOT (`_DATA_DATE` / `_LATEST_DATE`, no `segments_date`), so the name is the
-- latest snapshot row per campaign_id. tests/core/assert_google_spend_matches_source.sql checks spend per day
-- against the source when the var is true. Before flipping the var, compare these column names with
-- `google_ads.INFORMATION_SCHEMA.COLUMNS`; both var states must compile.
with google_campaign_stats as (
  {% if var('google_ads_enabled') %}
  select segments_date, campaign_id, sum(metrics_cost_micros) as metrics_cost_micros,
    sum(metrics_impressions) as metrics_impressions, sum(metrics_clicks) as metrics_clicks
  from {{ source('google_ads', 'campaign_stats') }}
  group by segments_date, campaign_id
  {% else %}
  select
    cast(null as date) as segments_date,
    cast(null as int64) as campaign_id,
    cast(null as int64) as metrics_cost_micros,
    cast(null as int64) as metrics_impressions,
    cast(null as int64) as metrics_clicks
  limit 0
  {% endif %}
),
google_campaign as (
  {% if var('google_ads_enabled') %}
  select campaign_id, campaign_name
  from {{ source('google_ads', 'campaign') }}
  qualify row_number() over (partition by campaign_id order by _DATA_DATE desc) = 1
  {% else %}
  select
    cast(null as int64) as campaign_id,
    cast(null as string) as campaign_name
  limit 0
  {% endif %}
),
google as (
  select s.segments_date as date, 'google' as platform, cast(s.campaign_id as string) as campaign_id, c.campaign_name,
    lower(trim(c.campaign_name)) as campaign_name_norm,
    s.metrics_cost_micros / 1e6 as spend, s.metrics_impressions as impressions, s.metrics_clicks as clicks
  from google_campaign_stats s
  join google_campaign c using (campaign_id)
),
-- Fix round 2: aggregate the CSV (social) spend at the source, by the NORMALISED
-- (lower/trim) campaign name, not the raw one. mart_paid_performance's social branch joins spend
-- to session aggregates on the normalised name (round 1 fix); if core_ad_spend still carried one
-- row per raw campaign_name, two spend rows differing only by case/whitespace would both join the
-- same social_agg row and each report its full sessions/orders/revenue -- double counting the
-- spend conservation test cannot see (it only checks total spend, not per-row attribution).
-- Normalising and summing here instead makes `(date, platform, campaign_name_norm)` the true
-- uniqueness grain of every core_ad_spend row.
csv as (
  select date, platform, cast(null as string) as campaign_id,
    any_value(trim(campaign_name)) as campaign_name,
    lower(trim(campaign_name)) as campaign_name_norm,
    sum(spend) as spend, sum(impressions) as impressions, sum(clicks) as clicks
  from {{ ref('stg_spend__csv') }}
  group by date, platform, lower(trim(campaign_name))
),
unioned as (
  select * from google
  union all
  select * from csv
)
-- Fix round 1, finding 3: `campaign_name like concat(pattern, '%')` can match more than one
-- pattern when one is a prefix of another (e.g. a metro pattern and a broader catch-all pattern
-- both matching the same campaign_name), fanning a single spend row out into duplicates. Keep at
-- most one match per spend row -- the longest (most specific) matching pattern -- via `qualify`.
-- Rows with no match at all still pass through once (the left join yields exactly one NULL-metro
-- row for them, so `qualify` keeps it regardless of ordering). Partitioning by `campaign_id` too
-- (rather than just date/platform/campaign_name) is harmless for CSV spend rows, whose
-- `campaign_id` is always NULL: BigQuery's window functions treat NULL as an ordinary, consistent
-- partition-key value, so a NULL-campaign_id spend row is still its own single-row partition.
select u.*, m.metro_slug, mk.metro_key
from unioned u
left join {{ ref('campaign_metro_map') }} m on u.campaign_name like concat(m.campaign_name_pattern, '%')
left join {{ ref('core_metros') }} mk on mk.slug = m.metro_slug
qualify row_number() over (partition by u.date, u.platform, u.campaign_id, u.campaign_name_norm order by length(m.campaign_name_pattern) desc) = 1
