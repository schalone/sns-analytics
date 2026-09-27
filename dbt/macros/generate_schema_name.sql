{#- Final-review I14: DBT_SCHEMA_PREFIX, when set, prefixes every schema this project WRITES
    (<prefix>_staging, <prefix>_core, <prefix>_mart, <prefix>_ops for seeds), so a local build can never overwrite
    production tables. Sources are unaffected: they keep reading the real raw and archive datasets.
    Local development: export DBT_SCHEMA_PREFIX=dev_<name>. Without it a build writes production. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set base = custom_schema_name if custom_schema_name is not none else target.schema -%}
    {%- set prefix = env_var('DBT_SCHEMA_PREFIX', '') | trim -%}
    {{ prefix ~ '_' ~ base if prefix else base }}
{%- endmacro %}
