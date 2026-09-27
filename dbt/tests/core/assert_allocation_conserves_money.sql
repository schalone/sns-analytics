-- What was split across an order's items must add back up to the order-level amount.
-- Controller decision 3: CMS refunds count only when status = 'Succeeded'.
with items as (
  select order_key, source_system, sum(discount) as discount, sum(service_fee) as service_fee,
    sum(refunded_amount) as refunded, sum(processing_fee) as fee, any_value(fee_source) as fee_source
  from {{ ref('core_order_item_economics') }}
  group by 1, 2
),
cms as (
  select o.order_key, o.discount, o.service_fee, coalesce(r.refunded, 0) as refunded
  from {{ ref('stg_cms__orders') }} o
  left join (select order_key, sum(amount) as refunded from {{ ref('stg_cms__refunds') }}
             where status = 'Succeeded' group by 1) r using (order_key)
),
stripe as (
  select order_key, sum(fee) as fee from {{ ref('core_stripe_transactions') }} where order_key is not null group by 1
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
