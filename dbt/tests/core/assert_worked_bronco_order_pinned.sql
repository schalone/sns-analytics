{{ config(severity='warn') }}
-- The worked orders in assert_worked_order.sql are legacy orders, because no new-platform (bronco)
-- order had been loaded when they were checked by hand. Once bronco bookings exist and are more than
-- two days old (settled in Stripe), one of them should be checked by hand against Stripe
-- (scripts/econ_check_order.py --bronco <order number>) and pinned in assert_worked_order.sql,
-- after which this test is deleted.
select 'no bronco order has been validated by hand yet' as message
from (
  select count(*) as n
  from {{ ref('core_bookings') }}
  where platform_era = 'bronco'
    and purchase_date < date_sub(current_date('America/New_York'), interval 2 day)
)
where n > 0
