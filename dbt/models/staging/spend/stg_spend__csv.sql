-- Final-review I9: the loader writes ISO YYYY-MM-DD dates and plain numbers; safe parsing keeps one bad raw
-- value from failing the whole build (it reads as NULL instead).
with latest_meta as ({{ latest_raw('raw_spend', 'meta') }}),
     latest_pinterest as ({{ latest_raw('raw_spend', 'pinterest') }})
select key, 'meta' as platform, safe.parse_date('%Y-%m-%d', json_value(payload, '$.date')) as date, json_value(payload, '$.campaign_name') as campaign_name,
  safe_cast(json_value(payload, '$.spend') as float64) as spend, safe_cast(json_value(payload, '$.impressions') as int64) as impressions, safe_cast(json_value(payload, '$.clicks') as int64) as clicks
from latest_meta
union all
select key, 'pinterest' as platform, safe.parse_date('%Y-%m-%d', json_value(payload, '$.date')) as date, json_value(payload, '$.campaign_name') as campaign_name,
  safe_cast(json_value(payload, '$.spend') as float64) as spend, safe_cast(json_value(payload, '$.impressions') as int64) as impressions, safe_cast(json_value(payload, '$.clicks') as int64) as clicks
from latest_pinterest
