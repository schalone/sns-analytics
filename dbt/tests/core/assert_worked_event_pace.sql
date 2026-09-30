{{ config(severity='warn') }}
-- ECON-001 worked events: pace and sell-out, counted by hand on 2026-09-28 from the archive (see
-- assert_worked_event.sql for seats and money, pinned at error severity, and docs/econ-001-validation.md).
-- Resolved through the WordPress event id. Warn severity: these figures depend on the event date and
-- capacity, which the CMS export may record differently from the archive for an imported event; a
-- difference then needs a look, not a failed build.
--   WordPress event 269869  sold out; first sale 17 days before the event; sold out 9 days before.
--   WordPress event 259204  sold out; first sale 59 days before the event; sold out 2 days before.
with expected as (
  select * from unnest([
    struct('269869' as wordpress_source_id, 17 as first_sale_days_before, 9 as days_before_at_sellout),
    struct('259204', 59, 2)
  ])
),
-- One event per WordPress id, the rule core_order_item_economics uses: a CMS event wins over an archive one.
events as (
  select wordpress_source_id, event_key from {{ ref('core_events') }} where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(event_source = 'cms', 0, 1), event_key) = 1
)
select x.wordpress_source_id, if(e.event_key is null, 'missing', 'mismatch') as problem
from expected x
left join events ev using (wordpress_source_id)
left join {{ ref('core_event_economics') }} e on e.event_key = ev.event_key
where e.event_key is null
   or e.first_sale_days_before is distinct from x.first_sale_days_before
   or e.days_before_at_sellout is distinct from x.days_before_at_sellout
   or not coalesce(e.sold_out, false)
