-- Page totals per day (final-review I18): complete per page; use for landing-page search performance.
select property, date, page, regexp_extract(page, r'^https?://[^/]+(/[^?#]*)') as page_path, clicks, impressions, position
from {{ ref('stg_gsc__page') }}
