{{ config(severity='warn') }}
-- Every new-platform (bronco) ticket booking should name its event: a CMS ticket order item always carries an
-- eventKey. A booking with no event_key drops out of every event view (event economics, the booking curve,
-- peer benchmarks, ad spend allocation) while its money stays in the totals.
select booking_key, order_key, purchase_date
from {{ ref('core_bookings') }}
where platform_era = 'bronco' and event_key is null
