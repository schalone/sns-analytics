with latest as ({{ latest_raw('raw_cms', 'events') }})
select key as event_key, json_value(payload, '$.title') as title, json_value(payload, '$.urlPath') as url_path,
  date(timestamp(json_value(payload, '$.eventDate'))) as event_date,
  json_value(payload, '$.startTime') as start_time, json_value(payload, '$.endTime') as end_time, json_value(payload, '$.timeZone') as time_zone,
  json_value(payload, '$.venueKey') as venue_key, json_value(payload, '$.metroKey') as metro_key, json_value(payload, '$.instructorKey') as instructor_key,
  json_value(payload, '$.category') as category, json_value(payload, '$.eventType') as event_type, json_value(payload, '$.theme') as theme,
  json_value(payload, '$.status') as status, cast(json_value(payload, '$.capacity') as int64) as capacity,
  cast(json_value(payload, '$.ticketPriceCents') as int64) / 100 as ticket_price, cast(json_value(payload, '$.isVirtual') as bool) as is_virtual,
  cast(json_value(payload, '$.noTickets') as bool) as no_tickets, json_value(payload, '$.externalTicketUrl') as external_ticket_url,
  json_value(payload, '$.wordpressSourceId') as wordpress_source_id, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
