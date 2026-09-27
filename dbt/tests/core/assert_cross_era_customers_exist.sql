{{ config(severity='warn') }}
-- If identity resolution works, thousands of legacy customers have also bought on the new platform.
-- Fewer than 500 means the two eras are not joining. This only means something once the new
-- platform has real order volume, so it only fires once at least 1,000 bronco orders exist.
with bronco_orders as (
  select count(*) as n from {{ ref('core_orders') }} where platform_era = 'bronco'
),
crossers as (
  select countif(bought_in_both_eras) as n from {{ ref('core_customers') }}
)
select crossers.n as customers_in_both_eras
from bronco_orders cross join crossers
where bronco_orders.n >= 1000 and crossers.n < 500
