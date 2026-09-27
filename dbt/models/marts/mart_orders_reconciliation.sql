{{ config(tags=['hourly']) }}
-- Orders and Stripe, compared like with like: each side is grouped by the date the thing itself
-- happened on -- an order by its own business_date, a Stripe transaction by its own business_date,
-- a refund by the refund's own business_date -- never one row's date borrowed to bucket another.
-- Covers the whole history, both eras. The 1% variance flag applies only in the bronco era, where
-- Stripe is the payment processor of record; the legacy era's useful number is stripe_match_rate,
-- the share of paid archive orders that found a Stripe charge.
with orders as (
  select business_date,
    count(*) as cms_orders,
    countif(gross_revenue > 0) as paid_orders,
    sum(gross_revenue) as orders_charged_amount,
    sum(net_revenue) as cms_net_revenue
  from {{ ref('core_orders') }}
  group by 1
),
charged as (
  select distinct order_key
  from {{ ref('core_stripe_transactions') }}
  where source_object = 'charge' and order_key is not null
),
matched as (
  select o.business_date, countif(c.order_key is not null) as orders_matched_to_stripe
  from {{ ref('core_orders') }} o
  left join charged c using (order_key)
  where o.gross_revenue > 0
  group by 1
),
stripe as (
  select business_date,
    countif(type in ('charge', 'payment')) as stripe_charges,
    sum(if(type in ('charge', 'payment') and match_method != 'adhoc', amount, 0)) as stripe_charged_amount,
    sum(if(type in ('charge', 'payment') and match_method = 'adhoc', amount, 0)) as stripe_adhoc_amount,
    sum(if(type in ('refund', 'payment_refund'), -amount, 0)) as stripe_refunded_amount,
    sum(fee) as stripe_fees,
    sum(if(type in ('charge', 'payment', 'refund', 'payment_refund'), net, 0)) as stripe_net,
    sum(if(type in ('charge', 'payment'), amount, 0)) + sum(if(type in ('refund', 'payment_refund'), amount, 0)) as stripe_gross_less_refunds
  from {{ ref('core_stripe_transactions') }}
  group by 1
),
refunds as (
  -- Bronco only: the legacy archive carries no refund dates at all, so there is nothing to bucket
  -- by refund date for a legacy-era business_date (handled by the era check in `final` below, not by
  -- filtering core_refunds here -- it already holds only CMS/bronco refunds).
  select business_date, sum(amount) as refunded_amount
  from {{ ref('core_refunds') }}
  where status = 'Succeeded'
  group by 1
),
joined as (
  select coalesce(o.business_date, s.business_date, r.business_date) as business_date,
    coalesce(o.cms_orders, 0) as cms_orders,
    coalesce(o.paid_orders, 0) as paid_orders,
    coalesce(o.orders_charged_amount, 0) as orders_charged_amount,
    coalesce(o.cms_net_revenue, 0) as cms_net_revenue,
    coalesce(m.orders_matched_to_stripe, 0) as orders_matched_to_stripe,
    safe_divide(m.orders_matched_to_stripe, nullif(o.paid_orders, 0)) as stripe_match_rate,
    coalesce(s.stripe_charges, 0) as stripe_charges,
    coalesce(s.stripe_charged_amount, 0) as stripe_charged_amount,
    coalesce(s.stripe_adhoc_amount, 0) as stripe_adhoc_amount,
    coalesce(s.stripe_refunded_amount, 0) as stripe_refunded_amount,
    coalesce(s.stripe_fees, 0) as stripe_fees,
    coalesce(s.stripe_net, 0) as stripe_net,
    coalesce(s.stripe_gross_less_refunds, 0) as stripe_gross_less_refunds,
    r.refunded_amount
  from orders o
  full outer join stripe s using (business_date)
  full outer join refunds r using (business_date)
  left join matched m using (business_date)
),
final as (
  select j.*,
    {{ platform_era_of_date('j.business_date') }} as platform_era,
    case when {{ platform_era_of_date('j.business_date') }} = 'bronco' then coalesce(j.refunded_amount, 0) end as orders_refunded_amount
  from joined j
),
variance as (
  select *,
    orders_charged_amount - stripe_charged_amount as variance_amount,
    round(safe_divide(orders_charged_amount - stripe_charged_amount, nullif(stripe_charged_amount, 0)), 6) as variance_pct,
    orders_refunded_amount - stripe_refunded_amount as refund_variance_amount
  from final
)
select business_date, platform_era,
  cms_orders, paid_orders, orders_charged_amount, cms_net_revenue,
  orders_matched_to_stripe, stripe_match_rate,
  stripe_charges, stripe_charged_amount, stripe_adhoc_amount, stripe_refunded_amount,
  stripe_fees, stripe_net, stripe_gross_less_refunds,
  orders_refunded_amount,
  variance_amount, variance_pct, refund_variance_amount,
  coalesce(platform_era = 'bronco' and abs(variance_pct) > 0.01, false) as flagged
from variance
