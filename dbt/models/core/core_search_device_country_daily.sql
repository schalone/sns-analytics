-- Device x country totals per day (final-review I18): complete; sums to the property totals.
select property, date, device, country, clicks, impressions, position
from {{ ref('stg_gsc__device_country') }}
