-- Stripe loads daily and the CMS hourly, so a fresh bronco order legitimately has no Stripe charge yet.
-- After two days a card-paid bronco order without one is a broken join, not a timing gap.
select booking_key, order_key, purchase_date
from {{ ref('core_bookings') }}
where platform_era = 'bronco' and fee_source = 'estimated'
  and purchase_date < date_sub(current_date('America/New_York'), interval 2 day)
