-- processing_fee can legitimately be negative: Stripe returns fees on some refunds (none exist in
-- today's data, but a matched, actual fee could go negative in principle). Flag only what an
-- actual/estimate rule can't explain: a negative fee that isn't backed by a matched Stripe
-- transaction, or a fee larger than the sale it came from.
{{ config(severity='warn') }}
select order_item_key, processing_fee, realized_revenue, fee_source
from {{ ref('core_order_item_economics') }}
where (processing_fee < -0.01 and fee_source != 'actual')
   or (processing_fee > realized_revenue and realized_revenue > 1)
