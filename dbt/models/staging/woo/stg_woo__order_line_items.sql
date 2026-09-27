select concat('woo-li-', cast(id as string)) as order_item_key, concat('woo-', cast(order_id as string)) as order_key,
  cast(product_id as string) as woo_product_id, name as item_name, cast(quantity as int64) as quantity,
  cast(total as float64) as line_total, safe_divide(cast(total as float64), nullif(cast(quantity as int64), 0)) as unit_price
from {{ source('woo', 'order_line_items') }}
