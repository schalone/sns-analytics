with latest as ({{ latest_raw('raw_cms', 'order_items') }})
select key as order_item_key, json_value(payload, '$.orderKey') as order_key, lower(json_value(payload, '$.checkoutSessionKey')) as checkout_session_key,
  json_value(payload, '$.itemType') as item_type, json_value(payload, '$.ticketKey') as ticket_key, json_value(payload, '$.giftCardKey') as gift_card_key,
  json_value(payload, '$.eventKey') as event_key, cast(json_value(payload, '$.quantity') as int64) as quantity,
  cast(json_value(payload, '$.unitPriceCents') as int64) / 100 as unit_price, cast(json_value(payload, '$.lineTotalCents') as int64) / 100 as line_total,
  json_value(payload, '$.status') as status, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
