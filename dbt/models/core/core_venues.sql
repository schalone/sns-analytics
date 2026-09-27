{{ config(tags=['hourly']) }}
-- Legacy-only venues. A venue that exists only in the WooCommerce archive (the CMS never
-- imported it) is keyed woo-venue-<id>; one the CMS did import is excluded here to avoid a duplicate.
with cms as (
  select venue_key, name, city, state, zip, latitude, longitude, metro_key as assigned_metro_key, capacity, time_zone,
    wordpress_source_id, updated_at, 'cms' as venue_source
  from {{ ref('stg_cms__venues') }}
),
legacy_only as (
  select concat('woo-venue-', w.woo_venue_id) as venue_key, w.name, w.city, w.state, w.zip, w.latitude, w.longitude,
    cast(null as string) as assigned_metro_key, cast(null as int64) as capacity, cast(null as string) as time_zone,
    w.woo_venue_id as wordpress_source_id, cast(null as timestamp) as updated_at, 'woo_archive' as venue_source
  from {{ ref('stg_woo__venues') }} w
  where w.woo_venue_id not in (select wordpress_source_id from {{ ref('stg_cms__venues') }} where wordpress_source_id is not null)
),
v as (
  select * from cms union all select * from legacy_only
),
nearest as (
  select v.venue_key, m.metro_key
  from v
  join {{ ref('core_metros') }} m
    on st_dwithin(safe.st_geogpoint(v.longitude, v.latitude), m.center_geog, m.radius_miles * 1609.344)
  where v.latitude is not null and v.longitude is not null
  qualify row_number() over (partition by v.venue_key
                             order by st_distance(safe.st_geogpoint(v.longitude, v.latitude), m.center_geog)) = 1
)
select v.venue_key, v.name, v.city, v.state, v.zip, v.latitude, v.longitude, v.assigned_metro_key, v.capacity, v.time_zone,
  v.wordpress_source_id, v.updated_at, v.venue_source,
  coalesce(v.assigned_metro_key, nearest.metro_key) as metro_key
from v
left join nearest using (venue_key)
