-- Final-review I15b: warn when the daily Search Console load has not written raw_gsc.page_query for more than
-- 2 days (an empty table warns too). Reads only the last two days' partitions.
{{ config(severity='warn') }}
select max(_loaded_at) as latest_loaded_at
from {{ source('raw_gsc', 'page_query') }}
where _loaded_at >= timestamp_sub(current_timestamp(), interval 2 day)
having max(_loaded_at) is null
