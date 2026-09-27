-- Final-review I15b: warn when nothing has been loaded into raw_cms.orders for more than a day. Reads only the
-- last day's partitions; an EMPTY table (today: the CMS export API is not deployed) also warns, because max()
-- over no rows is NULL and HAVING still returns that one row.
{{ config(severity='warn') }}
select max(_loaded_at) as latest_loaded_at
from {{ source('raw_cms', 'orders') }}
where _loaded_at >= timestamp_sub(current_timestamp(), interval 1 day)
having max(_loaded_at) is null
