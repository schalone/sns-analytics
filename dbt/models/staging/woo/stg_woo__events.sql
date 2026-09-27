-- event_utc_start_date is already TIMESTAMP in sipandscript_new_ds.events (checked via
-- INFORMATION_SCHEMA.COLUMNS), not epoch seconds, so no timestamp_seconds() wrap is needed.
-- event_cost is already FLOAT64.
select cast(id as string) as woo_event_id, title, status, url,
  event_utc_start_date as start_at,
  event_cost as event_cost, cast(venue_id as string) as woo_venue_id, cast(organizer_id as string) as woo_organizer_id,
  date(event_start_date) as event_date,        -- event_start_date holds local wall-clock time; verified: it differs from event_utc_start_date by 4-8 hours
  nullif(event_timezone, '') as event_timezone
from {{ source('woo', 'events') }}
