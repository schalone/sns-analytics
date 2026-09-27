-- Final-review I7: an order must never be counted in both systems. core_orders keeps every paid WooCommerce
-- archive order (no date filter since I7) and every CMS order with source = 'webapp'; CMS copies of WordPress
-- orders (source = 'wordpressImport') are excluded there. Fails if a webapp CMS order carries the WordPress
-- order id of an archive order that core_orders counts. The export sets source = 'wordpressImport' exactly when
-- WordPressOrderId is present (AnalyticsCommerceExportService.cs:147 in the CMS), so this passes by
-- construction today (and trivially while raw_cms is empty); it guards against that mapping changing.
select w.order_key, c.order_key as cms_order_key, c.wordpress_order_id
from {{ ref('core_orders') }} w
join {{ ref('stg_cms__orders') }} c
  on trim(c.wordpress_order_id) = cast(w.order_number as string)
where w.source_system = 'woocommerce'
  and c.source = 'webapp'
