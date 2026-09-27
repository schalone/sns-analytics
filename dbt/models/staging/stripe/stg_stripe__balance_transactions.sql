-- NOTE: raw_stripe.balance_transactions is empty (no Stripe loader run yet against a real
-- account), so the metadata key spelling on a real charge could not be checked. Keeping all
-- three candidate spellings via coalesce() until a real charge is available; revisit once the
-- Stripe loader has run and drop the spellings that don't exist.
with latest as ({{ latest_raw('raw_stripe', 'balance_transactions') }})
select key as txn_id, json_value(payload, '$.type') as type, timestamp_seconds(cast(json_value(payload, '$.created') as int64)) as created_at,
  cast(json_value(payload, '$.amount') as int64) / 100 as amount, cast(json_value(payload, '$.fee') as int64) / 100 as fee, cast(json_value(payload, '$.net') as int64) / 100 as net,
  json_value(payload, '$.currency') as currency, json_value(payload, '$.source.id') as source_id, json_value(payload, '$.source.object') as source_object,
  lower(coalesce(json_value(payload, '$.source.metadata.OrderGuid'), json_value(payload, '$.source.metadata.orderGuid'), json_value(payload, '$.source.metadata.order_guid'))) as order_key,
  json_value(payload, '$.source.payment_intent') as payment_intent_id, json_value(payload, '$.source.refund') as refund_id
from latest
