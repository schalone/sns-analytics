with latest as ({{ latest_raw('raw_cms', 'venues') }})
select key as venue_key, json_value(payload, '$.name') as name, json_value(payload, '$.city') as city, json_value(payload, '$.state') as state,
  json_value(payload, '$.zip') as zip, cast(json_value(payload, '$.latitude') as float64) as latitude, cast(json_value(payload, '$.longitude') as float64) as longitude,
  json_value(payload, '$.metroKey') as metro_key, cast(json_value(payload, '$.capacity') as int64) as capacity, json_value(payload, '$.timeZone') as time_zone,
  json_value(payload, '$.wordpressSourceId') as wordpress_source_id, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
