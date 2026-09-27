{% macro latest_raw(source_name, table_name) %}
select key, updated_at, payload, _loaded_at
from {{ source(source_name, table_name) }}
qualify row_number() over (partition by key order by updated_at desc, _loaded_at desc) = 1
{% endmacro %}
