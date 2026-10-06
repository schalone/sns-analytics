-- Meta spend per campaign per day from the Fivetran Facebook Ads connector (`facebook_ads.basic_campaign`).
-- Filtered to the Sip & Script ad account: the connector also syncs other businesses' accounts. With
-- `meta_ads_enabled` false this is a typed empty select, so the project builds without the dataset.
-- Clicks are link clicks (`inline_link_clicks`), the same measure the CSV drop asks for.
{% if var('meta_ads_enabled') %}
select
  date,
  cast(campaign_id as string) as campaign_id,
  campaign_name,
  spend,
  impressions,
  inline_link_clicks as clicks
from {{ source('facebook_ads', 'basic_campaign') }}
where account_id = {{ var('meta_ad_account_id') }}
{% else %}
select
  cast(null as date) as date,
  cast(null as string) as campaign_id,
  cast(null as string) as campaign_name,
  cast(null as float64) as spend,
  cast(null as int64) as impressions,
  cast(null as int64) as clicks
limit 0
{% endif %}
