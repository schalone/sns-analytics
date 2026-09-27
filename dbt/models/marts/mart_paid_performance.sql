-- Controller ruling 1: `click_stats` (the Google Ads gclid-level ClickStats transfer table) is
-- gated by the `google_ads_enabled` var the same way as core_ad_spend -- see dbt_project.yml. With
-- the var false, `google_click_stats` below is a typed empty select so this model builds without
-- the `google_ads` dataset existing. Google sessions then fall back to GA4's own linked campaign id
-- (`s.google_ads_campaign_id`), which core_ad_spend never has spend rows for while the var is
-- false, so no Google rows reach the final output either way (driven from core_ad_spend).
with google_click_stats as (
  -- Fix round 1, finding 2: click_view_gclid is not unique in the real ClickStats table (the same
  -- gclid can recur across several days/campaigns); dedup to one row per gclid before joining to
  -- sessions, else the join would fan a single session out into duplicates and inflate
  -- sessions/orders/revenue. `segments_date` is carried through so the dedup can order on it. The
  -- empty (var-false) branch keeps the exact same column list and types as the real branch.
  {% if var('google_ads_enabled') %}
  select click_view_gclid, campaign_id, segments_date
  from {{ source('google_ads', 'click_stats') }}
  qualify row_number() over (partition by click_view_gclid order by segments_date desc, campaign_id) = 1
  {% else %}
  select cast(null as string) as click_view_gclid, cast(null as int64) as campaign_id, cast(null as date) as segments_date
  limit 0
  {% endif %}
),
google_sessions as (
  -- gclid -> campaign via the Ads ClickStats table; fallback to GA4's linked campaign id
  select s.session_key, s.session_date, coalesce(cast(cs.campaign_id as string), s.google_ads_campaign_id) as campaign_id
  from {{ ref('core_sessions') }} s
  left join google_click_stats cs on cs.click_view_gclid = s.gclid
  where s.gclid is not null or s.google_ads_campaign_id is not null
),
social_sessions as (
  -- Fix round 1, finding 5: sessions with no campaign can never match a spend row's campaign_name
  -- and would otherwise sit in social_agg as a NULL-campaign group, silently absorbing organic
  -- Paid-Social sessions into nothing; excluded here rather than left to fall out of the join.
  select session_key, session_date, lower(trim(campaign)) as campaign_name_norm, case when lower(source) like '%pinterest%' then 'pinterest' else 'meta' end as platform
  from {{ ref('core_sessions') }} where default_channel_group = 'Paid Social' and campaign is not null
),
orders_by_session as (
  select so.session_key, o.business_date, count(*) as orders, sum(o.seats) as seats, sum(o.net_revenue) as net_revenue
  from {{ ref('core_session_orders') }} so join {{ ref('core_orders') }} o using (order_key) group by 1, 2
),
google_agg as (
  select gs.session_date as date, 'google' as platform, gs.campaign_id, count(*) as sessions, sum(coalesce(ob.orders, 0)) as orders, sum(coalesce(ob.seats, 0)) as seats, sum(coalesce(ob.net_revenue, 0)) as net_revenue
  from google_sessions gs left join orders_by_session ob using (session_key) group by 1, 2, 3
),
social_agg as (
  -- Fix round 1, finding 5: grouped and joined on the normalised (lower/trim) campaign name so
  -- the grain stays unique and matches spend rows regardless of case/whitespace differences
  -- between GA4's utm campaign param and the CSV drop's campaign_name.
  select ss.session_date as date, ss.platform, ss.campaign_name_norm, count(*) as sessions, sum(coalesce(ob.orders, 0)) as orders, sum(coalesce(ob.seats, 0)) as seats, sum(coalesce(ob.net_revenue, 0)) as net_revenue
  from social_sessions ss left join orders_by_session ob using (session_key) group by 1, 2, 3
)
select sp.date, sp.platform, sp.campaign_id, sp.campaign_name, sp.metro_key, sp.spend, sp.impressions, sp.clicks,
  coalesce(g.sessions, so.sessions, 0) as sessions, coalesce(g.orders, so.orders, 0) as orders, coalesce(g.seats, so.seats, 0) as seats,
  coalesce(g.net_revenue, so.net_revenue, 0) as net_revenue,
  safe_divide(coalesce(g.net_revenue, so.net_revenue, 0), nullif(sp.spend, 0)) as roas,
  safe_divide(sp.spend, nullif(coalesce(g.orders, so.orders, 0), 0)) as cpa
from {{ ref('core_ad_spend') }} sp
left join google_agg g on sp.platform = 'google' and g.date = sp.date and g.campaign_id = sp.campaign_id
left join social_agg so on sp.platform in ('meta', 'pinterest') and so.date = sp.date and so.platform = sp.platform and so.campaign_name_norm = lower(trim(sp.campaign_name))
