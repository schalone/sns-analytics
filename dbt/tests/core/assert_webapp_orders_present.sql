-- Ruling 1: raw_cms is empty today (no CMS loader has run yet), so core_orders holds zero
-- 'webapp' rows. This is expected but should stay visible in every build until the loader runs,
-- so it is a warn-severity singular test rather than a silent gap.
{{ config(severity='warn') }}
select count(*) as webapp_orders
from {{ ref('core_orders') }}
where source_system = 'webapp'
having count(*) = 0
