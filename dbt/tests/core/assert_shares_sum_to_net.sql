select order_item_key
from {{ ref('core_order_item_economics') }}
where abs(sns_share + instructor_share - net_distributable) > 0.01
