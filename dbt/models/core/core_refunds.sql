{{ config(tags=['hourly']) }}
select refund_key, r.order_key, ticket_key, amount, currency, reason, r.status, stripe_refund_id, r.created_at, completed_at, r.updated_at,
  date(coalesce(completed_at, r.created_at), 'America/New_York') as business_date,
  coalesce(o.platform_era, 'bronco') as platform_era
from {{ ref('stg_cms__refunds') }} r
left join {{ ref('core_orders') }} o using (order_key)
