{# Era in which something happened, from its date. The boundary is the last day the legacy archive received data. #}
{% macro platform_era_of_date(date_expr) -%}
case when {{ date_expr }} < date('{{ var("launch_date") }}') then 'legacy_event_tickets' else 'bronco' end
{%- endmacro %}

{# Era of a sale, from the system that recorded it. #}
{% macro platform_era_of_source(source_system_expr) -%}
case {{ source_system_expr }} when 'woocommerce' then 'legacy_event_tickets' else 'bronco' end
{%- endmacro %}
