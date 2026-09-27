-- Fix round 2: for the social platforms, core_ad_spend is unique on (date, platform,
-- campaign_name_norm) and mart_paid_performance's social branch joins session aggregates on that
-- same normalised key. If two mart_paid_performance rows ever shared a (date, platform,
-- campaign_name_norm), the same social_agg aggregate (sessions/orders/seats/net_revenue) would
-- have been attributed to both -- double counting. Fails on any such duplicate.
select date, platform, campaign_name_norm, count(*) as n
from {{ ref('mart_paid_performance') }}
where platform in ('meta', 'pinterest')
group by 1, 2, 3
having count(*) > 1
