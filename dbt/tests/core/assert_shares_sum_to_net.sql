-- Every item: the two shares add up to net_distributable, and net_distributable is realized revenue less
-- refunds, disputed (chargeback) money and processing fees, each within one cent.
select order_item_key
from {{ ref('core_order_item_economics') }}
where abs(sns_share + instructor_share - net_distributable) > 0.01
   or abs(realized_revenue - refunded_amount - disputed_amount - processing_fee - net_distributable) > 0.01
