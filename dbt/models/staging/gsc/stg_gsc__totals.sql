-- Search Console property totals, dimensions [date] (final-review I18): complete, one row per property and day.
with latest as ({{ latest_raw('raw_gsc', 'totals') }})
select key, json_value(payload, '$.property') as property, date(json_value(payload, '$.date')) as date,
  cast(json_value(payload, '$.clicks') as int64) as clicks, cast(json_value(payload, '$.impressions') as int64) as impressions,
  cast(json_value(payload, '$.position') as float64) as position
from latest
