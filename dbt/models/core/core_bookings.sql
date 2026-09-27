{{ config(tags=['hourly']) }}
-- The economics fact: one row per ticket order item (order x event), both eras.
select
  i.order_item_key as booking_key, i.order_key, i.event_key,
  ci.customer_hash, coalesce(ci.identity_source, 'unresolved') as identity_source,
  i.source_system, i.platform_era,
  i.purchased_at, i.purchase_date,
  least(i.purchase_date, coalesce(e.event_date, i.purchase_date)) as sale_date,
  date_diff(e.event_date, i.purchase_date, day) as days_before_event,
  i.seats, if(i.is_cancelled, 0, i.seats) as net_seats,
  i.list_value, i.discount, i.service_fee, i.realized_revenue, i.refunded_amount, i.processing_fee, i.fee_source,
  i.net_distributable, i.sns_share, i.instructor_share, i.is_cancelled
from {{ ref('core_order_item_economics') }} i
left join {{ ref('core_events') }} e using (event_key)
left join {{ ref('core_customer_identity') }} ci on ci.order_key = i.order_key
where i.item_kind = 'ticket'
