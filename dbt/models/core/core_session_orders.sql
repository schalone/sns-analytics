{{ config(materialized='incremental', incremental_strategy='merge', unique_key='order_key', tags=['ga4']) }}
-- Fix round 2, item 1 (controller): this was a plain (always-full-rescan) table, costing
-- ~8.9 GiB x 24 runs/day under the `hourly` tag -- far over the pipeline's "well under $5/month"
-- budget. Incremental now: a first build / full-refresh still scans from `ga4_start_date`, but an
-- incremental run only scans the last `ga4_lookback_days` (default 3) days of `_table_suffix` (intraday tables stay excluded by
-- the `^\d{8}$` filter). Within that scan, the earliest purchase event per order_key wins (same
-- double-fire correction as before, with `session_key` added as a tiebreaker for determinism);
-- then any order_key already present in `{{ this }}` is dropped before the merge, so a stored row
-- is never replaced by a later-arriving duplicate -- the very first time an order_key was ever
-- seen is permanent.
with purchases as (
  select
    concat(user_pseudo_id, '.', cast((select value.int_value from unnest(event_params) where key = 'ga_session_id') as string)) as session_key,
    trim(coalesce(ecommerce.transaction_id, (select value.string_value from unnest(event_params) where key = 'transaction_id'))) as transaction_id,
    timestamp_micros(event_timestamp) as purchase_event_at
  from {{ source('ga4', 'events') }}
  where event_name = 'purchase' and regexp_contains(_table_suffix, r'^\d{8}$')
  {% if is_incremental() %}
    and _table_suffix >= format_date('%Y%m%d', date_sub(current_date(), interval {{ var('ga4_lookback_days') | int }} day))
  {% else %}
    and _table_suffix >= format_date('%Y%m%d', date('{{ var("ga4_start_date") }}'))
  {% endif %}
),
keyed as (
  select session_key, purchase_event_at, transaction_id,
    case when regexp_contains(transaction_id, r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') then lower(transaction_id)
         when regexp_contains(transaction_id, r'^\d+$') then concat('woo-', transaction_id) end as order_key
  from purchases where transaction_id is not null and transaction_id not in ('(not set)', '')
),
deduped as (
  select order_key, session_key, purchase_event_at
  from keyed where order_key is not null
  qualify row_number() over (partition by order_key order by purchase_event_at, session_key) = 1   -- correction: purchase double-fire
)
select deduped.*
from deduped
{% if is_incremental() %}
left join (select order_key from {{ this }}) as existing on existing.order_key = deduped.order_key
where existing.order_key is null
{% endif %}
