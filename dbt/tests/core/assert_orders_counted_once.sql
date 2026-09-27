select order_key from {{ ref('core_session_orders') }} group by order_key having count(*) > 1
