select property, date, regexp_extract(page, r'^https?://[^/]+(/[^?#]*)') as page_path, page, query, clicks, impressions, position
from {{ ref('stg_gsc__page_query') }}
