-- Controller ruling 5: same grain as the dbt_utils.unique_combination_of_columns schema test, but
-- with metro_key explicitly null-normalised so a NULL-vs-NULL duplicate (which the schema test's
-- generated SQL also treats as equal via GROUP BY, but is easy to get wrong) is checked by name and
-- independently.
select business_date, pre_launch, channel_group, coalesce(metro_key, '') as metro_key_norm, count(*) as n
from {{ ref('mart_daily_kpis') }}
group by 1, 2, 3, 4
having count(*) > 1
