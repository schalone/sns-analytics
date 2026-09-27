-- latitude / longitude are STRING in sipandscript_new_ds.venues (checked via
-- INFORMATION_SCHEMA.COLUMNS), and ~0.2% of rows store '' rather than a number, which a plain
-- CAST(... AS FLOAT64) rejects at query time ("Bad double value"); safe_cast returns null instead.
select cast(id as string) as woo_venue_id, name, city, state, zip_code as zip,
  safe_cast(latitude as float64) as latitude, safe_cast(longitude as float64) as longitude
from {{ source('woo', 'venues') }}
