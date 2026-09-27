-- Regression guard for the raw-writer payload bug found and fixed 2026-09-27 (RawWriter.append() in
-- loaders/common/bq.py used to double-JSON-encode `payload`, storing a JSON *string* instead of a JSON
-- *object* -- every json_value(payload, '$.field') read in every staging model then silently returned
-- NULL). Flags any raw row loaded in the last 3 days whose payload is not a JSON object. Restricted to
-- a 3-day window (the raw tables are partitioned on _loaded_at) to keep the scan cheap; a regression
-- would show up within a few loader runs, not require scanning full history.
{% set raw_tables = [
    ('raw_cms', 'orders'), ('raw_cms', 'order_items'), ('raw_cms', 'tickets'), ('raw_cms', 'refunds'),
    ('raw_cms', 'promo_redemptions'), ('raw_cms', 'gift_cards'), ('raw_cms', 'gift_card_transactions'),
    ('raw_cms', 'checkout_sessions'), ('raw_cms', 'events'), ('raw_cms', 'venues'), ('raw_cms', 'metros'),
    ('raw_cms', 'instructors'),
    ('raw_stripe', 'balance_transactions'), ('raw_stripe', 'refunds'), ('raw_stripe', 'disputes'), ('raw_stripe', 'payouts'),
    ('raw_gsc', 'page_query'), ('raw_gsc', 'page_device_country'),
    ('raw_spend', 'meta'), ('raw_spend', 'pinterest')
] %}
{% for dataset, table in raw_tables %}
select '{{ dataset }}.{{ table }}' as raw_table, key
from {{ source(dataset, table) }}
where json_type(payload) != 'object'
  and _loaded_at >= timestamp_sub(current_timestamp(), interval 3 day)
{{ "union all" if not loop.last }}
{% endfor %}
