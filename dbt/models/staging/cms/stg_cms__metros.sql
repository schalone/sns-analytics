with latest as ({{ latest_raw('raw_cms', 'metros') }})
select key as metro_key, json_value(payload, '$.name') as name, json_value(payload, '$.slug') as slug, json_value(payload, '$.urlPath') as url_path,
  json_value(payload, '$.centerPlace') as center_place, cast(json_value(payload, '$.centerLatitude') as float64) as center_latitude,
  cast(json_value(payload, '$.centerLongitude') as float64) as center_longitude, cast(json_value(payload, '$.radiusMiles') as int64) as radius_miles,
  timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
