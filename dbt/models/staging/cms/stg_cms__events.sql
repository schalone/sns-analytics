-- Task 14b: the CMS export API's final review changed event time semantics. `eventDate` is now a
-- `yyyy-MM-dd` venue-local calendar date string (not a timestamp); `startTime`/`endTime` are
-- `HH:mm:ss` venue-local strings (unchanged shape, but now explicitly venue-local rather than
-- ambiguous); and two new nullable fields, `startAtUtc`/`endAtUtc` (ISO-8601 UTC), give the same
-- instants directly in UTC when the export has them. `safe.parse_date` yields NULL rather than
-- failing the build on a malformed date string.
with latest as ({{ latest_raw('raw_cms', 'events') }})
select key as event_key, json_value(payload, '$.title') as title, json_value(payload, '$.urlPath') as url_path,
  safe.parse_date('%Y-%m-%d', json_value(payload, '$.eventDate')) as event_date,
  json_value(payload, '$.startTime') as start_time, json_value(payload, '$.endTime') as end_time, json_value(payload, '$.timeZone') as time_zone,
  safe.timestamp(json_value(payload, '$.startAtUtc')) as start_at_utc, safe.timestamp(json_value(payload, '$.endAtUtc')) as end_at_utc,
  json_value(payload, '$.venueKey') as venue_key, json_value(payload, '$.metroKey') as metro_key, json_value(payload, '$.instructorKey') as instructor_key,
  json_value(payload, '$.category') as category, json_value(payload, '$.eventType') as event_type, json_value(payload, '$.theme') as theme,
  json_value(payload, '$.status') as status, cast(json_value(payload, '$.capacity') as int64) as capacity,
  cast(json_value(payload, '$.ticketPriceCents') as int64) / 100 as ticket_price, cast(json_value(payload, '$.isVirtual') as bool) as is_virtual,
  cast(json_value(payload, '$.noTickets') as bool) as no_tickets, json_value(payload, '$.externalTicketUrl') as external_ticket_url,
  json_value(payload, '$.wordpressSourceId') as wordpress_source_id, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
