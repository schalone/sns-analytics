-- Fails when, in any calendar month with at least 50 card-paid new-platform (bronco) bookings older than two
-- days, more than 2% of them carry fee_source = 'estimated' (no Stripe charge matched). A handful of
-- unmatched charges is reported by assert_no_estimated_fee_on_settled_bronco (warn) without stopping the
-- build; this test stops it only when the Stripe join is broken for a meaningful share of a month's sales.
-- Card-paid means fee_source 'actual' or 'estimated' ('none' is an order with no card payment).
select date_trunc(purchase_date, month) as purchase_month,
  count(*) as card_paid_bookings,
  countif(fee_source = 'estimated') as estimated,
  round(safe_divide(countif(fee_source = 'estimated'), count(*)), 4) as estimated_share
from {{ ref('core_bookings') }}
where platform_era = 'bronco'
  and fee_source in ('actual', 'estimated')
  and purchase_date < date_sub(current_date('America/New_York'), interval 2 day)
group by 1
having count(*) >= 50 and safe_divide(countif(fee_source = 'estimated'), count(*)) > 0.02
