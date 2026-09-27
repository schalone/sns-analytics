-- Ruling 2: legacy WooCommerce line items map to events through the product's
-- `tribe_wooticket_for_event` postmeta (exposed as `stg_woo__products.woo_event_id`), not through
-- the raw `woo._staging_products` source the brief joined directly. `_staging_products` is not
-- used by this model.
select order_item_key, order_key, item_type, ticket_key, gift_card_key, event_key, quantity, unit_price, line_total, status, created_at, updated_at
from {{ ref('stg_cms__order_items') }}
union all
select li.order_item_key, li.order_key,
  case p.product_kind when 'ticket' then 'ticket' when 'gift_card' then 'giftCard' else 'other' end as item_type,
  cast(null as string) as ticket_key, cast(null as string) as gift_card_key,
  e.event_key, li.quantity, li.unit_price, li.line_total, 'completed' as status, o.created_at, o.updated_at
from {{ ref('stg_woo__order_line_items') }} li
left join {{ ref('stg_woo__products') }} p using (woo_product_id)
left join {{ ref('core_events') }} e on e.wordpress_source_id = p.woo_event_id
join {{ ref('stg_woo__orders') }} o using (order_key)
