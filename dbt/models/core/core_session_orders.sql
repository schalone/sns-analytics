{{ config(tags=['hourly']) }}
with purchases as (
  select
    concat(user_pseudo_id, '.', cast((select value.int_value from unnest(event_params) where key = 'ga_session_id') as string)) as session_key,
    coalesce(ecommerce.transaction_id, (select value.string_value from unnest(event_params) where key = 'transaction_id')) as transaction_id,
    timestamp_micros(event_timestamp) as purchase_event_at
  from {{ source('ga4', 'events') }}
  where event_name = 'purchase' and regexp_contains(_table_suffix, r'^\d{8}$') and _table_suffix >= format_date('%Y%m%d', date('{{ var("ga4_start_date") }}'))
),
keyed as (
  select session_key, purchase_event_at, transaction_id,
    case when regexp_contains(transaction_id, r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') then lower(transaction_id)
         when regexp_contains(transaction_id, r'^\d+$') then concat('woo-', transaction_id) end as order_key
  from purchases where transaction_id is not null and transaction_id not in ('(not set)', '')
)
select order_key, session_key, purchase_event_at
from keyed where order_key is not null
qualify row_number() over (partition by order_key order by purchase_event_at) = 1   -- correction: purchase double-fire
