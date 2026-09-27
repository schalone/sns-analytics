-- Final-review I8: Google spend in core_ad_spend must equal the transfer's own sum(metrics_cost_micros) / 1e6
-- per day, within one cent (catches a fan-out from the name join and stats rows lost to a missing campaign
-- name). Selects nothing while `google_ads_enabled` is false (the google_ads dataset has no tables yet).
{% if var('google_ads_enabled') %}
with src as (
  select segments_date as date, sum(metrics_cost_micros) / 1e6 as spend
  from {{ source('google_ads', 'campaign_stats') }} group by 1
),
core as (
  select date, sum(spend) as spend from {{ ref('core_ad_spend') }} where platform = 'google' group by 1
)
select coalesce(src.date, core.date) as date, src.spend as source_spend, core.spend as core_spend
from src full outer join core on src.date = core.date
where abs(coalesce(src.spend, 0) - coalesce(core.spend, 0)) > 0.01
{% else %}
select cast(null as date) as date limit 0
{% endif %}
