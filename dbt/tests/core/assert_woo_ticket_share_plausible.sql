-- Ruling 7: measured against core_orders on 2026-09-27 (order_type breakdown where
-- source_system='woocommerce' and extract(year from business_date)=2025):
--   ticket     25,921 orders  $2,368,117.15
--   materials     733 orders    $171,654.32
--   gift_card     80 orders      $7,185.00
--   other         19 orders      $2,879.00
--   total gross                $2,549,835.47
-- Ticket share = 2,368,117.15 / 2,549,835.47 = 92.87%, comfortably inside the brief's 60-95%
-- window, so the bounds are kept unchanged (no modelling error found; materials came in at ~6.7%
-- of 2025 revenue rather than the brief's ballpark ~17-20%, but that does not affect this test).
select share from (
  select safe_divide(sum(if(order_type = 'ticket', gross_revenue, 0)), sum(gross_revenue)) as share
  from {{ ref('core_orders') }}
  where source_system = 'woocommerce' and extract(year from business_date) = 2025
) where share not between 0.6 and 0.95
