-- date_created_gmt / date_paid_gmt / date_updated_gmt are already TIMESTAMP in sipandscript_new_ds.orders
-- (checked via INFORMATION_SCHEMA.COLUMNS), not epoch seconds, so no timestamp_seconds() wrap is needed.
-- total / discount_total are already FLOAT64.
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
  billing_city, billing_state, billing_postcode as billing_zip
from {{ source('woo', 'orders') }}
