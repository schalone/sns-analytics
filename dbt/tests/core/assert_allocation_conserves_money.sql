-- What was split across an order's items must add back up to the order-level amount.
-- CMS refunds count only when status = 'Succeeded' (per core_orders.sql's own refund-status ruling).
with items as (
  select order_key, source_system, sum(discount) as discount, sum(service_fee) as service_fee,
    sum(refunded_amount) as refunded, sum(processing_fee) as fee, sum(realized_revenue) as realized_revenue,
    any_value(fee_source) as fee_source
  from {{ ref('core_order_item_economics') }}
  group by 1, 2
),
cms as (
  select o.order_key, o.discount, o.service_fee, coalesce(r.refunded, 0) as refunded
  from {{ ref('stg_cms__orders') }} o
  left join (select order_key, sum(amount) as refunded from {{ ref('stg_cms__refunds') }}
             where status = 'Succeeded' group by 1) r using (order_key)
),
woo as (
  select order_key, status from {{ ref('stg_woo__orders') }}
),
stripe as (
  select order_key, sum(fee) as fee, -sum(if(type in ('refund', 'payment_refund'), amount, 0)) as refunded
  from {{ ref('core_stripe_transactions') }} where order_key is not null group by 1
)
select i.order_key, 'discount' as what, i.discount as allocated, c.discount as expected
from items i join cms c using (order_key) where i.source_system = 'webapp' and abs(i.discount - coalesce(c.discount, 0)) > 0.01
union all
select i.order_key, 'service_fee', i.service_fee, c.service_fee
from items i join cms c using (order_key) where i.source_system = 'webapp' and abs(i.service_fee - coalesce(c.service_fee, 0)) > 0.01
union all
select i.order_key, 'refund', i.refunded, c.refunded
from items i join cms c using (order_key) where i.source_system = 'webapp' and abs(i.refunded - c.refunded) > 0.01
union all
select i.order_key, 'stripe_fee', i.fee, s.fee
from items i join stripe s using (order_key) where i.fee_source = 'actual' and abs(i.fee - s.fee) > 0.01
union all
-- Legacy, matched Stripe refund: the split refund must add back to the Stripe refund total.
select i.order_key, 'legacy_refund_stripe', i.refunded, s.refunded
from items i join stripe s using (order_key)
where i.source_system = 'woocommerce' and s.refunded > 0 and abs(i.refunded - s.refunded) > 0.01
union all
-- Legacy, status-only refund (no matched Stripe refund): each item refunds its own realized revenue,
-- so the order's items should refund exactly what they realized.
select i.order_key, 'legacy_refund_status', i.refunded, i.realized_revenue
from items i
join woo o using (order_key)
left join stripe s using (order_key)
where i.source_system = 'woocommerce' and o.status = 'refunded' and coalesce(s.refunded, 0) <= 0
  and abs(i.refunded - i.realized_revenue) > 0.01
