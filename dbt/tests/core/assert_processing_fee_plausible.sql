-- Controller decision 7: processing_fee can legitimately be negative -- Stripe has returned fees on
-- some old refunds, and those are real (fee_source = 'actual'). Flag only what an actual/estimate
-- rule can't explain: a negative fee that isn't backed by a matched Stripe transaction, or a fee
-- larger than the sale it came from.
{{ config(severity='warn') }}
select order_item_key, processing_fee, realized_revenue, fee_source
from {{ ref('core_order_item_economics') }}
where (processing_fee < -0.01 and fee_source != 'actual')
   or (processing_fee > realized_revenue and realized_revenue > 1)
