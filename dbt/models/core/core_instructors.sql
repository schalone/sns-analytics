{{ config(tags=['hourly']) }}
-- Task 5: legacy-only instructors. An instructor that exists only in the WooCommerce archive (the
-- CMS never imported them) is keyed woo-org-<id>; the archive's own `email` column is deliberately
-- never selected (stg_woo__organizers already omits it). start_date is a DATE on both sides (Task
-- 14b changed the CMS export's startDate to a calendar date, and the archive's is already a DATE),
-- so no cast to TIMESTAMP is applied.
select instructor_key, name, url_path, city, state, start_date, no_longer_teaches, wordpress_source_id, updated_at,
  'cms' as instructor_source
from {{ ref('stg_cms__instructors') }}
union all
select concat('woo-org-', o.woo_organizer_id), o.name, cast(null as string), o.location, cast(null as string),
  o.start_date, cast(null as bool), o.woo_organizer_id, cast(null as timestamp),
  'woo_archive'
from {{ ref('stg_woo__organizers') }} o
where o.woo_organizer_id not in (select wordpress_source_id from {{ ref('stg_cms__instructors') }} where wordpress_source_id is not null)
