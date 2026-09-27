-- Fix round 1: catches any fan-out of spend rows through mart_paid_performance's joins (google
-- click_stats dedup, campaign_metro_map dedup, social campaign-name normalisation) by checking
-- total spend is conserved to the cent against core_ad_spend, which mart_paid_performance is
-- built directly from (one row per core_ad_spend row, left-joined to session aggregates).
with mart as (
  select sum(spend) as spend from {{ ref('mart_paid_performance') }}
),
core as (
  select sum(spend) as spend from {{ ref('core_ad_spend') }}
)
select mart.spend as mart_spend, core.spend as core_spend
from mart, core
where abs(coalesce(mart.spend, 0) - coalesce(core.spend, 0)) > 0.01
