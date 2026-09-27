-- Search Console device x country totals, dimensions [date, device, country] (final-review I18): complete.
with latest as ({{ latest_raw('raw_gsc', 'device_country') }})
select key, json_value(payload, '$.property') as property, date(json_value(payload, '$.date')) as date,
  json_value(payload, '$.device') as device, json_value(payload, '$.country') as country,
  cast(json_value(payload, '$.clicks') as int64) as clicks, cast(json_value(payload, '$.impressions') as int64) as impressions,
  cast(json_value(payload, '$.position') as float64) as position
from latest
