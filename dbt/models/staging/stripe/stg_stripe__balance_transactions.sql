-- Reads the sanitised payload written by loaders/stripe_sanitize.py. Metadata key names were
-- verified against live charges on 2026-09-27 (addendum spec §4.5): bronco charges carry
-- CheckoutSessionKey and OrderNumber, legacy charges carry order_id, 2016-2018 charges carry the
-- order number only in the description (stored as order_ref). There is no order GUID in Stripe.
with latest as ({{ latest_raw('raw_stripe', 'balance_transactions') }})
select
  key                                                                  as txn_id,
  json_value(payload, '$.type')                                        as type,
  json_value(payload, '$.reporting_category')                          as reporting_category,
  timestamp_seconds(cast(json_value(payload, '$.created') as int64))   as created_at,
  cast(json_value(payload, '$.amount') as int64) / 100                 as amount,
  cast(json_value(payload, '$.fee') as int64) / 100                    as fee,
  cast(json_value(payload, '$.net') as int64) / 100                    as net,
  json_value(payload, '$.currency')                                    as currency,
  coalesce(json_value(payload, '$.source.id'), json_value(payload, '$.source')) as source_id,
  json_value(payload, '$.source.object')                               as source_object,
  case json_value(payload, '$.source.object')
    when 'charge' then json_value(payload, '$.source.id')
    when 'refund' then json_value(payload, '$.source.charge')
    when 'dispute' then json_value(payload, '$.source.charge')
  end                                                                  as charge_id,
  if(json_value(payload, '$.source.object') = 'refund', json_value(payload, '$.source.id'), null) as refund_id,
  json_value(payload, '$.source.payment_intent')                       as payment_intent_id,
  lower(json_value(payload, '$.source.metadata.CheckoutSessionKey'))   as checkout_session_key,
  json_value(payload, '$.source.metadata.OrderNumber')                 as order_number,
  json_value(payload, '$.source.metadata.order_id')                    as woo_order_id,
  json_value(payload, '$.source.order_ref')                            as order_ref,
  lower(json_value(payload, '$.source.metadata.AdHocChargeGuid'))      as adhoc_charge_key,
  json_value(payload, '$.source.customer_hash')                        as customer_hash
from latest
