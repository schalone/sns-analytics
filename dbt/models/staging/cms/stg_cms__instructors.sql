-- `startDate` is exported as a `yyyy-MM-dd` string (a calendar date, not an instant);
-- `start_date` is now a DATE, not a TIMESTAMP.
with latest as ({{ latest_raw('raw_cms', 'instructors') }})
select key as instructor_key, json_value(payload, '$.name') as name, json_value(payload, '$.urlPath') as url_path, json_value(payload, '$.city') as city,
  json_value(payload, '$.state') as state, safe.parse_date('%Y-%m-%d', json_value(payload, '$.startDate')) as start_date, cast(json_value(payload, '$.noLongerTeaches') as bool) as no_longer_teaches,
  json_value(payload, '$.wordpressSourceId') as wordpress_source_id, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
