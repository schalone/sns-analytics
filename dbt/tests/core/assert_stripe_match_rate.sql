-- Warn when fewer than 98% of a year's paid orders (charged amount above zero, older than two days) have a Stripe charge.
{{ config(severity='warn') }}
with charged as (
  select distinct order_key from {{ ref('core_stripe_transactions') }} where source_object = 'charge' and order_key is not null
)
select extract(year from o.business_date) as yr, o.platform_era, count(*) as orders, countif(c.order_key is not null) as matched
from {{ ref('core_orders') }} o
left join charged c using (order_key)
where o.gross_revenue > 0 and o.business_date < date_sub(current_date('America/New_York'), interval 2 day)
group by 1, 2
having safe_divide(countif(c.order_key is not null), count(*)) < 0.98
