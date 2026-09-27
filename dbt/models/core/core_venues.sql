select v.venue_key, v.name, v.city, v.state, v.zip, v.latitude, v.longitude, v.metro_key as assigned_metro_key, v.capacity, v.time_zone, v.wordpress_source_id, v.updated_at,
  coalesce(v.metro_key, nearest.metro_key) as metro_key
from {{ ref('stg_cms__venues') }} v
left join (
  select v2.venue_key, m.metro_key
  from {{ ref('stg_cms__venues') }} v2
  join {{ ref('core_metros') }} m on st_dwithin(st_geogpoint(v2.longitude, v2.latitude), m.center_geog, m.radius_miles * 1609.344)
  qualify row_number() over (partition by v2.venue_key order by st_distance(st_geogpoint(v2.longitude, v2.latitude), m.center_geog)) = 1
) nearest using (venue_key)
