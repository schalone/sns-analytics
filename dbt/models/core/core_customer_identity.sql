{{ config(tags=['hourly']) }}
-- One row per order in either system, with the customer it belongs to. The legacy archive holds no
-- email and 36% of its orders are guest checkouts, so legacy identity comes from the hashed billing
-- email on the Stripe charge, then from the CMS's imported copy of the WordPress order.
with orders as (
  select order_key, 'webapp' as source_system, customer_hash as cms_hash, cast(null as string) as woo_customer_id
  from {{ ref('stg_cms__orders') }}
  where source = 'webapp'
  union all
  select order_key, 'woocommerce', cast(null as string), nullif(nullif(woo_customer_id, '0'), '')
  from {{ ref('stg_woo__orders') }}
),
stripe as (
  select order_key, array_agg(customer_hash order by created_at desc limit 1)[offset(0)] as stripe_hash
  from {{ ref('core_stripe_transactions') }}
  where source_object = 'charge' and order_key is not null and customer_hash is not null
  group by order_key
),
cms_import as (
  select concat('woo-', wordpress_order_id) as order_key, min(customer_hash) as import_hash
  from {{ ref('stg_cms__orders') }}
  where source = 'wordpressImport' and wordpress_order_id is not null and customer_hash is not null
  group by 1
),
direct as (
  select o.order_key, o.source_system, o.woo_customer_id,
    case when o.source_system = 'webapp' then o.cms_hash else coalesce(s.stripe_hash, i.import_hash) end as direct_hash,
    case
      when o.source_system = 'webapp' and o.cms_hash is not null then 'cms'
      when o.source_system = 'woocommerce' and s.stripe_hash is not null then 'stripe'
      when o.source_system = 'woocommerce' and i.import_hash is not null then 'cms_import'
    end as direct_source
  from orders o
  left join stripe s using (order_key)
  left join cms_import i using (order_key)
),
propagated as (
  -- a registered WooCommerce customer: reuse the hash most of their other orders resolved to
  select woo_customer_id, direct_hash as propagated_hash
  from direct
  where woo_customer_id is not null and direct_hash is not null
  group by woo_customer_id, direct_hash
  qualify row_number() over (partition by woo_customer_id order by count(*) desc, direct_hash) = 1
)
select d.order_key, d.source_system,
  coalesce(d.direct_hash, p.propagated_hash, concat('woo-cust-', d.woo_customer_id)) as customer_hash,
  case
    when d.direct_hash is not null then d.direct_source
    when p.propagated_hash is not null then 'woo_propagated'
    when d.woo_customer_id is not null then 'woo_surrogate'
    else 'unresolved'
  end as identity_source
from direct d
left join propagated p using (woo_customer_id)
