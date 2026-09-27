-- Controller ruling 1: the `google_ads` dataset has no tables until a human authorises the
-- BigQuery Data Transfer (see dbt_project.yml `vars.google_ads_enabled`, default false). With the
-- var false, `google_campaign_stats` and `google_campaign` below are empty selects typed to match
-- the real transfer tables' documented columns (`segments_date`, `campaign_id`,
-- `metrics_cost_micros`, `metrics_impressions`, `metrics_clicks`, `campaign_name`) so the project
-- builds and this model produces zero Google rows. Flip the var to true once the transfer has run;
-- confirm column names/types against `google_ads.INFORMATION_SCHEMA.COLUMNS` at that point.
with google_campaign_stats as (
  {% if var('google_ads_enabled') %}
  select segments_date, campaign_id, metrics_cost_micros, metrics_impressions, metrics_clicks
  from {{ source('google_ads', 'campaign_stats') }}
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
  select campaign_id, campaign_name, segments_date
  from {{ source('google_ads', 'campaign') }}
  {% else %}
  select
    cast(null as int64) as campaign_id,
    cast(null as string) as campaign_name,
    cast(null as date) as segments_date
  limit 0
  {% endif %}
),
google as (
  select s.segments_date as date, 'google' as platform, cast(s.campaign_id as string) as campaign_id, c.campaign_name,
    s.metrics_cost_micros / 1e6 as spend, s.metrics_impressions as impressions, s.metrics_clicks as clicks
  from google_campaign_stats s
  join (
    select campaign_id, campaign_name
    from google_campaign
    qualify row_number() over (partition by campaign_id order by segments_date desc) = 1
  ) c using (campaign_id)
),
csv as (
  select date, platform, cast(null as string) as campaign_id, campaign_name, spend, impressions, clicks
  from {{ ref('stg_spend__csv') }}
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
qualify row_number() over (partition by u.date, u.platform, u.campaign_id, u.campaign_name order by length(m.campaign_name_pattern) desc) = 1
