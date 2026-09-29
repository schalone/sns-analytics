{{ config(tags=['hourly']) }}
-- A ticket's era is its order's era. A ticket on a CMS order imported from WordPress (source 'wordpressImport',
-- which core_orders leaves out) is legacy_event_tickets; only a ticket with no order at all defaults to bronco.
select t.ticket_key, t.order_key, t.order_item_key, t.event_key, t.status, t.transferred_from_ticket_key, t.created_at, t.updated_at, o.business_date,
  case when co.source = 'wordpressImport' then 'legacy_event_tickets' else coalesce(o.platform_era, 'bronco') end as platform_era
from {{ ref('stg_cms__tickets') }} t
left join {{ ref('core_orders') }} o using (order_key)
left join {{ ref('stg_cms__orders') }} co on co.order_key = t.order_key
