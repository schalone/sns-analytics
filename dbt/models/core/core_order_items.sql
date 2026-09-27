{{ config(tags=['hourly']) }}
-- Ruling 2: legacy WooCommerce line items map to events through the product's
-- `tribe_wooticket_for_event` postmeta (exposed as `stg_woo__products.woo_event_id`), not through
-- the raw `woo._staging_products` source the brief joined directly. `_staging_products` is not
-- used by this model.
--
-- Task 5: two core_events rows can in principle share a wordpress_source_id (two CMS events
-- imported from the same WordPress event), which would double a legacy line item if joined to
-- core_events directly. event_by_legacy_id keeps one event per wordpress_source_id -- preferring a
-- CMS event over an archive one, then the lowest event_key -- so the legacy branch below resolves
-- to exactly one row per line item.
with event_by_legacy_id as (
  select wordpress_source_id, event_key
  from {{ ref('core_events') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(event_source = 'cms', 0, 1), event_key) = 1
)
select order_item_key, order_key, item_type, ticket_key, gift_card_key, event_key, quantity, unit_price, line_total, status, created_at, updated_at,
  'bronco' as platform_era
from {{ ref('stg_cms__order_items') }}
union all
select li.order_item_key, li.order_key,
  case p.product_kind when 'ticket' then 'ticket' when 'gift_card' then 'giftCard' else 'other' end as item_type,
  cast(null as string) as ticket_key, cast(null as string) as gift_card_key,
  e.event_key, li.quantity, li.unit_price, li.line_total, 'completed' as status, o.created_at, o.updated_at,
  'legacy_event_tickets' as platform_era
from {{ ref('stg_woo__order_line_items') }} li
left join {{ ref('stg_woo__products') }} p using (woo_product_id)
left join event_by_legacy_id e on e.wordpress_source_id = p.woo_event_id
join {{ ref('stg_woo__orders') }} o using (order_key)
