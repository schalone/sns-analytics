{{ config(tags=['hourly']) }}
-- One row per event in either era. CMS events come first; an event that exists only in the legacy
-- archive is built from its ticket products and keyed woo-ev-<id>. seats_sold here is a plain count
-- for convenience; core_event_economics (built from bookings) is the authoritative outcome table.
--
-- Task 5: legacy-only events, capacity/price fallback. A CMS event keeps its own capacity, falling
-- back to the archive's ticket-product capacity (matched on wordpress_source_id) when the CMS value
-- is null or zero. Its ticket_price falls back the same way when null, or when zero and the archive
-- has a price for that event; a CMS price of exactly 0 with no archive price stays 0 (a genuinely
-- free event, not an unset one). Its seats_sold adds the archive's own ticket-line seats on top of
-- its CMS ticket count. An event the CMS never imported is built entirely from the archive and keyed
-- woo-ev-<id>; its venue/instructor are resolved through the legacy id on
-- core_venues/core_instructors, which already carry the equivalent woo-venue-<id> / woo-org-<id>
-- rows for anything the CMS didn't import either.
with woo_products as (
  select woo_event_id, nullif(sum(ticket_capacity), 0) as capacity, max(regular_price) as regular_price, min(name) as product_name
  from {{ ref('stg_woo__products') }}
  where product_kind = 'ticket' and woo_event_id is not null
  group by woo_event_id
),
woo_sales as (
  -- Paid statuses match core_orders' own WooCommerce paid-order list (completed, refunded,
  -- processing -- see core_orders.sql's ruling comment on the 13 processing orders lost to cutover).
  select p.woo_event_id, sum(li.quantity) as seats, safe_divide(sum(li.subtotal), sum(li.quantity)) as avg_list_price
  from {{ ref('stg_woo__order_line_items') }} li
  join {{ ref('stg_woo__products') }} p using (woo_product_id)
  join {{ ref('stg_woo__orders') }} o using (order_key)
  where p.product_kind = 'ticket' and p.woo_event_id is not null and o.status in ('completed', 'refunded', 'processing')
  group by p.woo_event_id
),
woo_event as (
  select wp.woo_event_id, we.title, we.status, we.url, we.event_date, we.start_at, we.event_timezone, we.woo_venue_id, we.woo_organizer_id,
    wp.capacity, coalesce(ws.avg_list_price, wp.regular_price, we.event_cost) as ticket_price,
    wp.product_name, coalesce(ws.seats, 0) as seats
  from woo_products wp
  left join {{ ref('stg_woo__events') }} we using (woo_event_id)
  left join woo_sales ws using (woo_event_id)
),
venue_by_legacy_id as (
  select wordpress_source_id, venue_key, metro_key from {{ ref('core_venues') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(venue_key like 'woo-venue-%', 1, 0), venue_key) = 1
),
instructor_by_legacy_id as (
  select wordpress_source_id, instructor_key from {{ ref('core_instructors') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(instructor_key like 'woo-org-%', 1, 0), instructor_key) = 1
),
e as (select * from {{ ref('stg_cms__events') }}),
sold as (
  -- Final-review I6: a seat is sold when its ticket is Active, Paid or Used -- the site's own seat count
  -- (EventAvailabilityService.cs:76 and :122 in sns-analytics-export-api). Held/Pending are checkout holds;
  -- Transferred tickets gave their seat to a new Paid ticket; Expired/Failed/Refunded/Cancelled hold none.
  -- One ticket = one seat (the export emits one row per ticket).
  select event_key, countif(status in ('Active', 'Paid', 'Used')) as seats_sold from {{ ref('stg_cms__tickets') }} group by event_key
),
-- Task 14b: prefer the export's own start_at_utc/end_at_utc (the same instants, already in UTC)
-- when present, falling back to the event_date + venue-local start/end_time + time_zone
-- construction otherwise. safe.parse_time (not parse_time) so a malformed time string yields NULL
-- (defaulted to midnight below) in the fallback rather than failing the whole build. Do not assume
-- end_at > start_at: an event ending after local midnight exports an end time earlier than its
-- start time (mirrors the site).
--
-- Fix round 1: the venue-local construction's failure-safe zone handling (a non-NULL but
-- unrecognised time_zone string raises "Invalid time zone" from a plain TIMESTAMP() call) lives in
-- the `event_instant` macro (dbt/macros/event_instant.sql), shared with
-- tests/core/assert_event_time_fallback_is_safe.sql so the test exercises the exact same
-- expression shape as this model.
cms_rows as (
  select e.event_key, e.title, e.url_path, e.event_date,
    coalesce(e.start_at_utc, {{ event_instant('e.event_date', "coalesce(safe.parse_time('%H:%M:%S', e.start_time), time '00:00:00')", 'e.time_zone') }}) as start_at,
    coalesce(e.end_at_utc, {{ event_instant('e.event_date', "coalesce(safe.parse_time('%H:%M:%S', e.end_time), time '00:00:00')", 'e.time_zone') }}) as end_at,
    coalesce(e.time_zone, 'America/New_York') as time_zone,
    e.venue_key, coalesce(e.metro_key, v.metro_key) as metro_key, e.instructor_key, e.category, e.event_type, e.theme, e.status,
    coalesce(nullif(e.capacity, 0), w.capacity) as capacity,
    coalesce(nullif(e.ticket_price, 0), w.ticket_price, e.ticket_price) as ticket_price,
    e.is_virtual, e.no_tickets, e.external_ticket_url, e.wordpress_source_id, e.updated_at,
    coalesce(s.seats_sold, 0) + coalesce(w.seats, 0) as seats_sold,
    'cms' as event_source,
    case when nullif(e.capacity, 0) is not null then 'cms' when w.capacity is not null then 'woo_products' else 'none' end as capacity_source
  from e
  left join {{ ref('core_venues') }} v using (venue_key)
  left join sold s using (event_key)
  left join woo_event w on w.woo_event_id = e.wordpress_source_id
),
legacy_rows as (
  select concat('woo-ev-', w.woo_event_id) as event_key, coalesce(w.title, w.product_name) as title, w.url as url_path, w.event_date,
    w.start_at, cast(null as timestamp) as end_at,
    coalesce(w.event_timezone, 'America/New_York') as time_zone,
    v.venue_key, v.metro_key, i.instructor_key,
    cast(null as string) as category, cast(null as string) as event_type, cast(null as string) as theme, w.status,
    w.capacity, w.ticket_price,
    cast(null as bool) as is_virtual, cast(null as bool) as no_tickets, cast(null as string) as external_ticket_url,
    w.woo_event_id as wordpress_source_id, cast(null as timestamp) as updated_at,
    w.seats as seats_sold,
    'woo_archive' as event_source,
    case when w.capacity is not null then 'woo_products' else 'none' end as capacity_source
  from woo_event w
  left join venue_by_legacy_id v on v.wordpress_source_id = w.woo_venue_id
  left join instructor_by_legacy_id i on i.wordpress_source_id = w.woo_organizer_id
  where w.woo_event_id not in (select wordpress_source_id from {{ ref('stg_cms__events') }} where wordpress_source_id is not null)
),
unioned as (
  select * from cms_rows union all select * from legacy_rows
)
select u.*,
  greatest(u.capacity - u.seats_sold, 0) as seats_available,
  u.event_date is not null as has_event_date,
  -- Task 5: an undated legacy-only event (~1,968 of them, checked 2026-09-27 -- 1,966 ticket
  -- products whose tribe_wooticket_for_event id has no matching row in stg_woo__events at all,
  -- plus 2 ticket products whose archive event row has no date) is legacy_event_tickets regardless
  -- of date; every other row -- CMS or archive, dated -- goes by its event_date against the launch
  -- boundary. A CMS row with a null event_date falls to bronco through the macro's else branch.
  case when u.event_date is null and u.event_source = 'woo_archive' then 'legacy_event_tickets'
       else {{ platform_era_of_date('u.event_date') }} end as platform_era
from unioned u
