{{ config(tags=['hourly']) }}
-- A refund's era is its order's era. A refund on a CMS order imported from WordPress (source 'wordpressImport',
-- which core_orders leaves out) is legacy_event_tickets; only a refund with no order at all defaults to bronco.
select r.refund_key, r.order_key, r.ticket_key, r.amount, r.currency, r.reason, r.status, r.stripe_refund_id, r.created_at, r.completed_at, r.updated_at,
  date(coalesce(r.completed_at, r.created_at), 'America/New_York') as business_date,
  case when co.source = 'wordpressImport' then 'legacy_event_tickets' else coalesce(o.platform_era, 'bronco') end as platform_era
from {{ ref('stg_cms__refunds') }} r
left join {{ ref('core_orders') }} o using (order_key)
left join {{ ref('stg_cms__orders') }} co on co.order_key = r.order_key
