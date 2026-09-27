-- Controller ruling 2: order_key will be NULL on every row once Stripe data arrives -- real Stripe
-- charges carry no order GUID in their metadata (only bronco keys / legacy order ids, per Task 10
-- progress notes). That is known and expected; a later plan rewrites Stripe matching. Not fixed or
-- pre-empted here.
select txn_id, type, created_at, date(created_at, 'America/New_York') as business_date, amount, fee, net, currency, source_id, source_object, order_key, payment_intent_id, refund_id
from {{ ref('stg_stripe__balance_transactions') }}
