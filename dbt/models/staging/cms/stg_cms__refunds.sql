-- Task 14b: the CMS export API never exports refund reasons (it is admin free text) -- `reason`
-- is kept here (column stays for shape/forward-compat) but will always read as NULL.
with latest as ({{ latest_raw('raw_cms', 'refunds') }})
select key as refund_key, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.ticketKey') as ticket_key,
  cast(json_value(payload, '$.amountCents') as int64) / 100 as amount, json_value(payload, '$.currency') as currency,
  json_value(payload, '$.reason') as reason, json_value(payload, '$.status') as status, json_value(payload, '$.stripeRefundId') as stripe_refund_id,
  timestamp(json_value(payload, '$.createdAt')) as created_at, timestamp(json_value(payload, '$.completedAt')) as completed_at, updated_at
from latest
