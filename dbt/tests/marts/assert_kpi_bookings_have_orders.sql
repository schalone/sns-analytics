{{ config(severity='warn') }}
-- mart_daily_kpis credits a booking's net_distributable and sns_share to its purchase order,
-- coalesce(transfer_root_order_key, order_key), by joining that key to core_orders. A booking whose purchase
-- order is absent from core_orders would drop out of the mart without an error. Returns one row per such
-- purchase order, with the money that would go missing. Expected to return nothing.
select coalesce(b.transfer_root_order_key, b.order_key) as purchase_order_key,
  count(*) as bookings, sum(b.net_distributable) as net_distributable, sum(b.sns_share) as sns_share
from {{ ref('core_bookings') }} b
left join {{ ref('core_orders') }} o on o.order_key = coalesce(b.transfer_root_order_key, b.order_key)
where o.order_key is null
group by 1
