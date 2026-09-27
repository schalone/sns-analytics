{{ config(tags=['hourly']) }}
with cms as (
  select business_date, count(*) as cms_orders, sum(net_revenue) as cms_net_revenue
  from {{ ref('core_orders') }} where source_system = 'webapp' group by 1
),
stripe as (
  select business_date, countif(type = 'charge') as stripe_charges, sum(net) as stripe_net, sum(fee) as stripe_fees,
    sum(case when type = 'charge' then amount else 0 end) + sum(case when type in ('refund', 'payment_refund') then amount else 0 end) as stripe_gross_less_refunds
  from {{ ref('core_stripe_transactions') }} group by 1
)
select coalesce(c.business_date, s.business_date) as business_date,
  coalesce(c.cms_orders, 0) as cms_orders, coalesce(c.cms_net_revenue, 0) as cms_net_revenue,
  coalesce(s.stripe_charges, 0) as stripe_charges, coalesce(s.stripe_net, 0) as stripe_net, coalesce(s.stripe_fees, 0) as stripe_fees,
  coalesce(s.stripe_gross_less_refunds, 0) as stripe_gross_less_refunds,
  coalesce(c.cms_net_revenue, 0) - coalesce(s.stripe_gross_less_refunds, 0) as variance_amount,
  safe_divide(coalesce(c.cms_net_revenue, 0) - coalesce(s.stripe_gross_less_refunds, 0), nullif(s.stripe_gross_less_refunds, 0)) as variance_pct,
  abs(safe_divide(coalesce(c.cms_net_revenue, 0) - coalesce(s.stripe_gross_less_refunds, 0), nullif(s.stripe_gross_less_refunds, 0))) > 0.01 as flagged
from cms c full outer join stripe s using (business_date)
where coalesce(c.business_date, s.business_date) >= date('{{ var("launch_date") }}')
