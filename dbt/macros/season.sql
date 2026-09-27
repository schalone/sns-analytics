{% macro season(date_expr) -%}
case
  when extract(month from {{ date_expr }}) in (12, 1, 2) then 'winter'
  when extract(month from {{ date_expr }}) in (3, 4, 5) then 'spring'
  when extract(month from {{ date_expr }}) in (6, 7, 8) then 'summer'
  when extract(month from {{ date_expr }}) in (9, 10, 11) then 'fall'
end
{%- endmacro %}
