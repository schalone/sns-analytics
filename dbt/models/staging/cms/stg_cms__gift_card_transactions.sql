with latest as ({{ latest_raw('raw_cms', 'gift_card_transactions') }})
select key as transaction_key, json_value(payload, '$.giftCardKey') as gift_card_key, json_value(payload, '$.orderKey') as order_key,
  cast(json_value(payload, '$.amountCents') as int64) / 100 as amount, json_value(payload, '$.type') as type,
  timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
