-- date_created_gmt / date_paid_gmt / date_updated_gmt are already TIMESTAMP in sipandscript_new_ds.orders
-- (checked via INFORMATION_SCHEMA.COLUMNS), not epoch seconds, so no timestamp_seconds() wrap is needed.
-- total / discount_total are already FLOAT64.
-- The archive has one exact-duplicate order (id 514177, 2 column-for-column identical rows,
-- checked 2026-09-27); dedupe losslessly here so order_key is unique for downstream joins.
-- parent_order_key: the archive's parent_id as an order key, NULL when parent_id is 0 or NULL. The legacy
-- site moved a seat to another event by creating a zero-total order whose parent is the original order.
with source as (
    select *
    from {{ source('woo', 'orders') }}
    qualify row_number() over (partition by id order by date_updated_gmt desc) = 1
)
select
  concat('woo-', cast(id as string))                     as order_key,
  cast(id as string)                                     as woo_order_id,
  status,
  date_created_gmt                                       as created_at,
  date_paid_gmt                                          as paid_at,
  date_updated_gmt                                       as updated_at,
  currency,
  total                                                  as total,
  discount_total                                         as discount,
  cast(customer_id as string)                            as woo_customer_id,
  if(coalesce(parent_id, 0) = 0, null, concat('woo-', cast(parent_id as string))) as parent_order_key,
  billing_city, billing_state, billing_postcode as billing_zip
from source
