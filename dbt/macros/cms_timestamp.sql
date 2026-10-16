{#
  Parses a CMS export timestamp at `path` in `payload`. The CMS writes .NET datetime2(7) values with up to
  seven fractional digits ('2026-09-15T00:30:55.8066667Z'); BigQuery's TIMESTAMP() takes at most six, so the
  digits past the microsecond are dropped first (truncated, not rounded). `safe=true` yields NULL instead of
  an error for an unparseable value.
#}
{% macro cms_timestamp(path, safe=false) %}
{{ 'safe.' if safe }}timestamp(regexp_replace(json_value(payload, '{{ path }}'), r'(\.\d{6})\d+', r'\1'))
{%- endmacro %}
