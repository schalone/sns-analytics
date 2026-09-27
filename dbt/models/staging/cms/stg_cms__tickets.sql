with latest as ({{ latest_raw('raw_cms', 'tickets') }})
select key as ticket_key, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.orderItemKey') as order_item_key,
  json_value(payload, '$.eventKey') as event_key, json_value(payload, '$.status') as status,
  json_value(payload, '$.transferredFromTicketKey') as transferred_from_ticket_key,
  timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
