-- Warn when fewer than 98% of a year's orders resolve to a real customer hash, from 2019 onward.
-- A legacy transfer order takes its root order's customer (transfer_parent); it counts as resolved
-- when that customer is a real hash, not a woo-cust- surrogate.
{{ config(severity='warn') }}
select extract(year from business_date) as yr, platform_era, count(*) as orders,
  countif(identity_source in ('cms', 'stripe', 'cms_import', 'woo_propagated')
    or (identity_source = 'transfer_parent' and customer_hash not like 'woo-cust-%')) as resolved
from {{ ref('core_orders') }}
where business_date >= '2019-01-01'
group by 1, 2
having safe_divide(countif(identity_source in ('cms', 'stripe', 'cms_import', 'woo_propagated')
    or (identity_source = 'transfer_parent' and customer_hash not like 'woo-cust-%')), count(*)) < 0.98
