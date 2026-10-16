with latest as ({{ latest_raw('raw_cms', 'gift_cards') }})
select key as gift_card_key, json_value(payload, '$.orderKey') as order_key,
  cast(json_value(payload, '$.initialCents') as int64) / 100 as initial_amount, cast(json_value(payload, '$.balanceCents') as int64) / 100 as balance,
  json_value(payload, '$.currency') as currency, json_value(payload, '$.status') as status,
  {{ cms_timestamp('$.issuedAt') }} as issued_at, {{ cms_timestamp('$.createdAt') }} as created_at, updated_at
from latest
