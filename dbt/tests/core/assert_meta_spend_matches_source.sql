-- Meta spend in core_ad_spend must equal the connector's own spend for the Sip & Script account per day,
-- within one cent (catches a lost or duplicated campaign-day). Selects nothing while `meta_ads_enabled`
-- is false.
{% if var('meta_ads_enabled') %}
with src as (
  select date, sum(spend) as spend from {{ source('facebook_ads', 'basic_campaign') }}
  where account_id = {{ var('meta_ad_account_id') }} group by 1
),
core as (
  select date, sum(spend) as spend from {{ ref('core_ad_spend') }} where platform = 'meta' group by 1
)
select coalesce(src.date, core.date) as date, src.spend as source_spend, core.spend as core_spend
from src full outer join core on src.date = core.date
where abs(coalesce(src.spend, 0) - coalesce(core.spend, 0)) > 0.01
{% else %}
select cast(null as date) as date limit 0
{% endif %}
