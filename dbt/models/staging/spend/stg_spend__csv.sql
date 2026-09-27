with latest_meta as ({{ latest_raw('raw_spend', 'meta') }}),
     latest_pinterest as ({{ latest_raw('raw_spend', 'pinterest') }})
select key, 'meta' as platform, date(json_value(payload, '$.date')) as date, json_value(payload, '$.campaign_name') as campaign_name,
  cast(json_value(payload, '$.spend') as float64) as spend, cast(json_value(payload, '$.impressions') as int64) as impressions, cast(json_value(payload, '$.clicks') as int64) as clicks
from latest_meta
union all
select key, 'pinterest' as platform, date(json_value(payload, '$.date')) as date, json_value(payload, '$.campaign_name') as campaign_name,
  cast(json_value(payload, '$.spend') as float64) as spend, cast(json_value(payload, '$.impressions') as int64) as impressions, cast(json_value(payload, '$.clicks') as int64) as clicks
from latest_pinterest
