-- Fails when, in any calendar month with at least 50 new-platform (bronco) orders, more than 2% of them have
-- realized revenue (summed over all the order's items) that differs by more than one cent from total +
-- gift_card_applied. The per-order check, assert_bronco_order_realized_matches_total.sql, reports every
-- disagreeing order at warn severity; this test stops the build only when the disagreement is systematic.
-- An order's month is the New York calendar month of its purchase date (paid, or else created).
-- Inert today: the CMS tables are empty, so there are no bronco orders to count.
with items as (
  select order_key, min(purchase_date) as purchase_date, sum(realized_revenue) as realized_revenue
  from {{ ref('core_order_item_economics') }}
  where source_system = 'webapp'
  group by order_key
),
orders as (
  select date_trunc(i.purchase_date, month) as purchase_month,
    abs(i.realized_revenue - (coalesce(o.total, 0) + coalesce(o.gift_card_applied, 0))) > 0.01 as disagrees
  from items i
  join {{ ref('stg_cms__orders') }} o using (order_key)
)
select purchase_month,
  count(*) as bronco_orders,
  countif(disagrees) as disagreeing,
  round(safe_divide(countif(disagrees), count(*)), 4) as disagreeing_share
from orders
group by 1
having count(*) >= 50 and safe_divide(countif(disagrees), count(*)) > 0.02
