{{ config(tags=['hourly']) }}
with e as (select * from {{ ref('stg_cms__events') }}),
sold as (
  -- Final-review I6: a seat is sold when its ticket is Active, Paid or Used -- the site's own seat count
  -- (EventAvailabilityService.cs:76 and :122 in sns-analytics-export-api). Held/Pending are checkout holds;
  -- Transferred tickets gave their seat to a new Paid ticket; Expired/Failed/Refunded/Cancelled hold none.
  -- One ticket = one seat (the export emits one row per ticket).
  select event_key, countif(status in ('Active', 'Paid', 'Used')) as seats_sold from {{ ref('stg_cms__tickets') }} group by event_key
)
-- Task 14b: prefer the export's own start_at_utc/end_at_utc (the same instants, already in UTC)
-- when present, falling back to the event_date + venue-local start/end_time + time_zone
-- construction otherwise. safe.parse_time (not parse_time) so a malformed time string yields NULL
-- (defaulted to midnight below) in the fallback rather than failing the whole build. Do not assume
-- end_at > start_at: an event ending after local midnight exports an end time earlier than its
-- start time (mirrors the site).
--
-- Fix round 1: the venue-local construction's failure-safe zone handling (a non-NULL but
-- unrecognised time_zone string raises "Invalid time zone" from a plain TIMESTAMP() call) lives in
-- the `event_instant` macro (dbt/macros/event_instant.sql), shared with
-- tests/core/assert_event_time_fallback_is_safe.sql so the test exercises the exact same
-- expression shape as this model.
select e.event_key, e.title, e.url_path, e.event_date,
  coalesce(e.start_at_utc, {{ event_instant('e.event_date', "coalesce(safe.parse_time('%H:%M:%S', e.start_time), time '00:00:00')", 'e.time_zone') }}) as start_at,
  coalesce(e.end_at_utc, {{ event_instant('e.event_date', "coalesce(safe.parse_time('%H:%M:%S', e.end_time), time '00:00:00')", 'e.time_zone') }}) as end_at,
  e.venue_key, coalesce(e.metro_key, v.metro_key) as metro_key, e.instructor_key, e.category, e.event_type, e.theme, e.status, e.capacity, e.ticket_price,
  e.is_virtual, e.no_tickets, e.external_ticket_url, e.wordpress_source_id, e.updated_at,
  coalesce(s.seats_sold, 0) as seats_sold, greatest(e.capacity - coalesce(s.seats_sold, 0), 0) as seats_available
from e
left join {{ ref('core_venues') }} v using (venue_key)
left join sold s using (event_key)
