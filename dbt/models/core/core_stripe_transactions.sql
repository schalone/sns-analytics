{{ config(tags=['hourly']) }}
-- Every Stripe balance transaction with the order it belongs to. Stripe holds no order GUID
-- (verified 2026-09-27), so bronco charges match on the checkout session key, then the order number;
-- legacy charges match on the WooCommerce order id from metadata, then from the description.
-- Refunds and disputes inherit the order of their charge.
with t as (
  select * from {{ ref('stg_stripe__balance_transactions') }}
),
cms_by_session as (
  select checkout_session_key, order_key
  from {{ ref('stg_cms__orders') }}
  where source = 'webapp' and checkout_session_key is not null
  qualify row_number() over (partition by checkout_session_key
                             order by if(status in ('Paid', 'Partial Refund', 'Refunded'), 0, 1), updated_at desc) = 1
),
cms_by_number as (
  select order_number, order_key
  from {{ ref('stg_cms__orders') }}
  where source = 'webapp' and order_number is not null
  qualify row_number() over (partition by order_number order by updated_at desc) = 1
),
charge_match as (
  select t.charge_id,
    coalesce(s.order_key, n.order_key, concat('woo-', t.woo_order_id), concat('woo-', t.order_ref)) as order_key,
    case
      when s.order_key is not null then 'checkout_session'
      when n.order_key is not null then 'order_number'
      when t.woo_order_id is not null then 'woo_metadata'
      when t.order_ref is not null then 'woo_description'
      when t.adhoc_charge_key is not null then 'adhoc'
      else 'none'
    end as match_method,
    t.customer_hash
  from t
  left join cms_by_session s on s.checkout_session_key = t.checkout_session_key
  left join cms_by_number n on n.order_number = t.order_number
  where t.source_object = 'charge' and t.charge_id is not null
  qualify row_number() over (partition by t.charge_id order by t.created_at, t.txn_id) = 1
)
select t.txn_id, t.type, t.reporting_category, t.created_at, date(t.created_at, 'America/New_York') as business_date,
  t.amount, t.fee, t.net, t.currency, t.source_id, t.source_object, t.charge_id, t.refund_id, t.payment_intent_id,
  m.order_key, coalesce(m.match_method, 'none') as match_method, m.customer_hash,
  {{ platform_era_of_date("date(t.created_at, 'America/New_York')") }} as platform_era
from t
left join charge_match m on m.charge_id = t.charge_id
