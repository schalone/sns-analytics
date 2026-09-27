{{ config(tags=['hourly']) }}
select t.ticket_key, t.order_key, t.order_item_key, t.event_key, t.status, t.transferred_from_ticket_key, t.created_at, t.updated_at, o.business_date,
  coalesce(o.platform_era, 'bronco') as platform_era
from {{ ref('stg_cms__tickets') }} t
left join {{ ref('core_orders') }} o using (order_key)
