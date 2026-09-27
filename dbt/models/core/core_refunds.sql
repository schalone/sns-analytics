{{ config(tags=['hourly']) }}
select refund_key, order_key, ticket_key, amount, currency, reason, status, stripe_refund_id, created_at, completed_at, updated_at,
  date(coalesce(completed_at, created_at), 'America/New_York') as business_date
from {{ ref('stg_cms__refunds') }}
