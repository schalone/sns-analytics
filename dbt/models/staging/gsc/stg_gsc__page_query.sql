with latest as ({{ latest_raw('raw_gsc', 'page_query') }})
select key, json_value(payload, '$.property') as property, date(json_value(payload, '$.date')) as date, json_value(payload, '$.page') as page,
  json_value(payload, '$.query') as query, cast(json_value(payload, '$.clicks') as int64) as clicks, cast(json_value(payload, '$.impressions') as int64) as impressions,
  cast(json_value(payload, '$.position') as float64) as position
from latest
