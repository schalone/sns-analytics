-- The archive has 2 exact-duplicate line items (ids 36875, 128582, checked 2026-09-27; 128582
-- belongs to the duplicated order 514177 above, 36875 to order 140648 with no other duplicate
-- rows on that order). Dedupe losslessly so order_item_key is unique for downstream joins.
with source as (
    select *
    from {{ source('woo', 'order_line_items') }}
    qualify row_number() over (partition by id order by id) = 1
)
select concat('woo-li-', cast(id as string)) as order_item_key, concat('woo-', cast(order_id as string)) as order_key,
  cast(product_id as string) as woo_product_id, name as item_name, cast(quantity as int64) as quantity,
  cast(total as float64) as line_total, safe_divide(cast(total as float64), nullif(cast(quantity as int64), 0)) as unit_price
from source
