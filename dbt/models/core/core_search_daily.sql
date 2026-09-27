-- Page x query per day. PARTIAL (final-review I18): Search Console drops anonymised and low-volume queries
-- whenever `query` is requested, so this holds well under half of all clicks. Use it for search-term analysis
-- only; never sum it to a total (use core_search_totals_daily / core_search_page_daily).
select property, date, regexp_extract(page, r'^https?://[^/]+(/[^?#]*)') as page_path, page, query, clicks, impressions, position
from {{ ref('stg_gsc__page_query') }}
