{{ config(severity='warn') }}
select platform_era, extract(year from purchase_date) as yr,
  countif(fee_source != 'none') as card_paid, countif(fee_source = 'actual') as actual
from {{ ref('core_bookings') }}
where purchase_date < date_sub(current_date('America/New_York'), interval 2 day)
group by 1, 2
having safe_divide(countif(fee_source = 'actual'), nullif(countif(fee_source != 'none'), 0)) < 0.98
