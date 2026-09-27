-- Legacy ticket lines find their event through wordpress_source_id; a duplicate would double-count them.
{{ config(severity='warn') }}
select wordpress_source_id, count(*) as events
from {{ ref('core_events') }}
where wordpress_source_id is not null
group by 1
having count(*) > 1
