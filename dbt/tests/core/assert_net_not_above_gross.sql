select order_key from {{ ref('core_orders') }} where net_revenue > gross_revenue or net_revenue < 0
