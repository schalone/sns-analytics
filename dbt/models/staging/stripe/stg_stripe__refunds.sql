with latest as ({{ latest_raw('raw_stripe', 'refunds') }})
select key as refund_id, timestamp_seconds(cast(json_value(payload, '$.created') as int64)) as created_at,
  cast(json_value(payload, '$.amount') as int64) / 100 as amount, json_value(payload, '$.currency') as currency, json_value(payload, '$.status') as status,
  json_value(payload, '$.charge') as charge_id, json_value(payload, '$.payment_intent') as payment_intent_id, json_value(payload, '$.reason') as reason
from latest
