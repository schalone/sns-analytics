-- Property totals per day (final-review I18): the table for every Search Console click / impression total.
select property, date, clicks, impressions, position
from {{ ref('stg_gsc__totals') }}
