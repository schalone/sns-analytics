-- The column pre_launch was replaced by platform_era. It must not exist in any dataset dbt writes.
-- The `region-us` project-level INFORMATION_SCHEMA (brief's original form) needs
-- bigquery.tables.list/get at the dataset level across the whole region; this service account
-- doesn't have it (Access Denied, verified 2026-09-27). Dataset-scoped INFORMATION_SCHEMA.COLUMNS,
-- unioned over the three datasets this project writes, needs only the per-dataset access dbt
-- already has to build into them, and checks the identical thing.
-- Code review fix round 1: this query has no ref()/source() of its own, so without an explicit
-- dependency the DAG scheduler has no edge forcing it to run after the core/mart/ops datasets
-- exist (a thread could pick it up first in a fresh, never-seeded DBT_SCHEMA_PREFIX, and
-- INFORMATION_SCHEMA.COLUMNS against a not-yet-created dataset is a hard BigQuery error, not an
-- empty result). The depends_on hints below force it after one model per dataset it inspects
-- (core_orders -> core, mart_daily_kpis -> mart) and the seed that creates the ops dataset
-- (date_flags -> ops), plus core_sessions, the other model that used to carry pre_launch.
-- depends_on: {{ ref('core_orders') }}
-- depends_on: {{ ref('core_sessions') }}
-- depends_on: {{ ref('mart_daily_kpis') }}
-- depends_on: {{ ref('date_flags') }}
{% set schemas = [generate_schema_name('core', none) | trim, generate_schema_name('mart', none) | trim, generate_schema_name('ops', none) | trim] %}
{% for s in schemas %}
select table_schema, table_name, column_name
from `{{ target.project }}`.`{{ s }}`.INFORMATION_SCHEMA.COLUMNS
where column_name = 'pre_launch'
{% if not loop.last %}union all
{% endif %}
{% endfor %}
