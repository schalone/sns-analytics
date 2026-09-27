{{ config(tags=['hourly']) }}
-- Pass through `state`, added to the metros export contract.
select metro_key, name, slug, url_path, state, center_latitude, center_longitude, radius_miles, updated_at,
  st_geogpoint(center_longitude, center_latitude) as center_geog
from {{ ref('stg_cms__metros') }}
