-- The column pre_launch was replaced by platform_era. It must not exist in any dataset dbt writes.
-- The `region-us` project-level INFORMATION_SCHEMA (brief's original form) needs
-- bigquery.tables.list/get at the dataset level across the whole region; this service account
-- doesn't have it (Access Denied, verified 2026-09-27). Dataset-scoped INFORMATION_SCHEMA.COLUMNS,
-- unioned over the three datasets this project writes, needs only the per-dataset access dbt
-- already has to build into them, and checks the identical thing.
{% set schemas = [generate_schema_name('core', none) | trim, generate_schema_name('mart', none) | trim, generate_schema_name('ops', none) | trim] %}
{% for s in schemas %}
select table_schema, table_name, column_name
from `{{ target.project }}`.`{{ s }}`.INFORMATION_SCHEMA.COLUMNS
where column_name = 'pre_launch'
{% if not loop.last %}union all
{% endif %}
{% endfor %}
