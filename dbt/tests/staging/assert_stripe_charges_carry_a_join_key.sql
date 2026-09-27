-- At least 97% of charge transactions per year must carry something an order can be matched on.
{{ config(severity='warn') }}
select extract(year from created_at) as yr, count(*) as charges,
  countif(coalesce(checkout_session_key, order_number, woo_order_id, order_ref, adhoc_charge_key) is null) as without_key
from {{ ref('stg_stripe__balance_transactions') }}
where type = 'charge'
group by 1
having safe_divide(countif(coalesce(checkout_session_key, order_number, woo_order_id, order_ref, adhoc_charge_key) is null), count(*)) > 0.03
