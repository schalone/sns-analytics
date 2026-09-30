{{ config(severity='warn') }}
-- For every new-platform (bronco) order, realized revenue summed over ALL its items (tickets, gift cards and
-- anything else) must equal what the customer was charged plus the gift card balance applied: total +
-- gift_card_applied, within one cent. realized revenue is line value less allocated discount plus allocated
-- service fee, and a gift card is a payment method, not a discount, so the two agree unless the lines, the
-- discount, the service fee or the total disagree in the CMS export.
-- Warn severity, per order: one disagreeing order is worth a look but must not fail core_order_item_economics'
-- tests, which would make dbt build skip core_bookings and every economics mart. A disagreement across a
-- meaningful share of a month's orders stops the build in assert_bronco_order_realized_match_rate.sql.
-- Inert today: the CMS tables are empty, so there are no bronco orders to compare.
with items as (
  select order_key, sum(realized_revenue) as realized_revenue
  from {{ ref('core_order_item_economics') }}
  where source_system = 'webapp'
  group by order_key
)
select o.order_key, i.realized_revenue, o.total, o.gift_card_applied
from items i
join {{ ref('stg_cms__orders') }} o using (order_key)
where abs(i.realized_revenue - (coalesce(o.total, 0) + coalesce(o.gift_card_applied, 0))) > 0.01
