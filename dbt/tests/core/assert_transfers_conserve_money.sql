-- For every root of a legacy seat transfer, realized revenue, refunds and processing fees summed over the
-- root's own lines and every transfer booking that took seats from it must equal what the root's lines carry
-- when computed directly from the archive and Stripe, within one cent.
with roots as (
  select distinct root_order_key as order_key from {{ ref('core_seat_transfers') }} where root_order_key is not null
),
modelled as (
  select coalesce(transfer_root_order_key, order_key) as order_key,
    sum(realized_revenue) as realized_revenue, sum(refunded_amount) as refunded_amount, sum(processing_fee) as processing_fee
  from {{ ref('core_order_item_economics') }}
  where coalesce(transfer_root_order_key, order_key) in (select order_key from roots)
  group by 1
),
stripe as (
  select order_key, sum(fee) as fee, 0 - sum(if(type in ('refund', 'payment_refund'), amount, 0)) as refunded,
    countif(source_object = 'charge') > 0 as has_charge
  from {{ ref('core_stripe_transactions') }} where order_key is not null group by 1
),
lines as (
  select order_key, sum(coalesce(line_total, 0)) as realized_revenue
  from {{ ref('stg_woo__order_line_items') }} group by 1
),
direct as (
  select r.order_key, l.realized_revenue,
    case when coalesce(s.refunded, 0) > 0 then s.refunded when o.status = 'refunded' then l.realized_revenue else 0 end as refunded_amount,
    case when coalesce(s.has_charge, false) then s.fee
         else l.realized_revenue * {{ var('legacy_fee_rate') }} + {{ var('legacy_fee_fixed') }} end as processing_fee
  from roots r
  join {{ ref('stg_woo__orders') }} o using (order_key)
  join lines l using (order_key)
  left join stripe s using (order_key)
)
select d.order_key, m.realized_revenue, d.realized_revenue as direct_realized_revenue,
  m.refunded_amount, d.refunded_amount as direct_refunded_amount, m.processing_fee, d.processing_fee as direct_processing_fee
from direct d
left join modelled m using (order_key)
where abs(coalesce(m.realized_revenue, 0) - d.realized_revenue) > 0.01
   or abs(coalesce(m.refunded_amount, 0) - d.refunded_amount) > 0.01
   or abs(coalesce(m.processing_fee, 0) - d.processing_fee) > 0.01
