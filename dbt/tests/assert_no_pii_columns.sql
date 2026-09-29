-- No dataset the pipeline writes may hold a column whose name looks like personal data.
-- Reads each written dataset's own INFORMATION_SCHEMA.COLUMNS (the region-wide view is access
-- denied to the pipeline's service account). Dataset names go through generate_schema_name, so a
-- prefixed development build inspects its own datasets. Instructor and venue `name` columns are
-- business names shown on the public site and do not match the pattern.
-- Two column names match the pattern (through "card") and are exempt by exact name, not by loosening
-- the pattern: gift_card_applied is a FLOAT64 amount in dollars, and gift_card_key is the CMS gift
-- card record's GUID (the export maps it from the record's Guid; the export carries no redemption
-- code and no holder). Neither identifies a person. Any other matching column fails this test.
-- The depends_on hints make this test run after at least one model or seed in each dataset exists.
-- depends_on: {{ ref('stg_woo__orders') }}
-- depends_on: {{ ref('core_bookings') }}
-- depends_on: {{ ref('mart_event_performance') }}
-- depends_on: {{ ref('ops_unallocated_ad_spend') }}
-- depends_on: {{ ref('date_flags') }}
{% set schemas = [generate_schema_name('staging', none) | trim, generate_schema_name('core', none) | trim, generate_schema_name('mart', none) | trim, generate_schema_name('ops', none) | trim] %}
{% for s in schemas %}
select table_schema, table_name, column_name
from `{{ target.project }}`.`{{ s }}`.INFORMATION_SCHEMA.COLUMNS
where regexp_contains(lower(column_name), r'(e_?mail|phone|first_?name|last_?name|full_?name|street|address|card|last4|purchaser|attendee)')
  and lower(column_name) not in ('gift_card_applied', 'gift_card_key')
{% if not loop.last %}union all
{% endif %}
{% endfor %}
