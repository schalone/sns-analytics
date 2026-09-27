with e as (select * from {{ ref('stg_cms__events') }}),
sold as (
  select event_key, countif(status in ('Paid','Used')) as seats_sold from {{ ref('stg_cms__tickets') }} group by event_key
)
-- Task 14b: prefer the export's own start_at_utc/end_at_utc (the same instants, already in UTC)
-- when present, falling back to the event_date + venue-local start/end_time + time_zone
-- construction otherwise. safe.parse_time (not parse_time) so a malformed time string yields NULL
-- in the fallback rather than failing the whole build. Do not assume end_at > start_at: an event
-- ending after local midnight exports an end time earlier than its start time (mirrors the site).
select e.event_key, e.title, e.url_path, e.event_date,
  coalesce(e.start_at_utc, timestamp(datetime(e.event_date, coalesce(safe.parse_time('%H:%M:%S', e.start_time), time '00:00:00')), coalesce(e.time_zone, 'America/New_York'))) as start_at,
  coalesce(e.end_at_utc, timestamp(datetime(e.event_date, coalesce(safe.parse_time('%H:%M:%S', e.end_time), time '00:00:00')), coalesce(e.time_zone, 'America/New_York'))) as end_at,
  e.venue_key, coalesce(e.metro_key, v.metro_key) as metro_key, e.instructor_key, e.category, e.event_type, e.theme, e.status, e.capacity, e.ticket_price,
  e.is_virtual, e.no_tickets, e.external_ticket_url, e.wordpress_source_id, e.updated_at,
  coalesce(s.seats_sold, 0) as seats_sold, greatest(e.capacity - coalesce(s.seats_sold, 0), 0) as seats_available
from e
left join {{ ref('core_venues') }} v using (venue_key)
left join sold s using (event_key)
