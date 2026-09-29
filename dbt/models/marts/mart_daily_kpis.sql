{{ config(tags=['hourly']) }}
-- Controller ruling 5: BigQuery's `using (...)` / `on a.x = b.x` equality is not null-safe
-- (`NULL = NULL` is unknown, so rows never match), and every session row plus any order with no
-- event/billing metro carries `metro_key = NULL`. The brief's plain `using (business_date,
-- platform_era, channel_group, metro_key)` joins would therefore silently drop all session volume
-- (and unmetro'd order volume) instead of lining it up with `grid`. Fixed below with an explicit
-- null-safe `coalesce(metro_key, '') = coalesce(metro_key, '')` predicate on both the grid->sessions
-- and grid->orders joins. `grid`'s own `union distinct` needs no change: DISTINCT/UNION DISTINCT
-- already treats NULL as equal to NULL for row deduplication (unlike a join/where predicate), so a
-- NULL metro_key is already collapsed to one grid row per (date, platform_era, channel_group).
--
-- Controller ruling 6: `cvr` is NULL (never 0, never an error) whenever sessions are absent/zero
-- (`safe_divide` against a NULL or 0 denominator returns NULL), on every metro row (metro attribution
-- doesn't apply to sessions, which carry no metro), and on any date flagged `unreliable_ga4` in the
-- `date_flags` seed (the Jun 19-22 GA4 cutover blackout). The numerator is coalesced to 0 so a
-- channel/day cell with real sessions and zero matching orders reports `cvr = 0`, not NULL.
--
-- Final-review I1: orders sit on exactly one row per (date, platform_era, channel, metro) and sessions only on
-- the metro_key-null row, so the CVR numerator must count the channel's ticket orders over ALL metro values,
-- not just the no-metro ones. `channel_ticket_orders` is that per-date-and-channel total, carried on the
-- null-metro row only (NULL on metro rows); dashboards compute CVR as SUM(channel_ticket_orders) / SUM(sessions)
-- over null-metro rows. The grid guarantees a null-metro row for every (date, platform_era, channel) that has
-- orders, so the total is never lost when every order of a channel-day carries a metro.
--
-- Legacy seat transfers: a transfer order (core_orders.is_transfer) moved a seat of an earlier paid order
-- to another event. It is not a purchase, so it adds nothing to orders, ticket_orders (and hence the CVR
-- numerator channel_ticket_orders), seats, gross_revenue, net_revenue, ticket_net_revenue or new_customers.
-- net_distributable and sns_share still sum core_bookings by order, so the money its booking took from the
-- root order is reported on the transfer's own business date and channel/metro row.
with s as (
  select session_date as business_date, platform_era, default_channel_group as channel_group, cast(null as string) as metro_key,
    count(*) as sessions, countif(engaged) as engaged_sessions
  from {{ ref('core_sessions') }} group by 1, 2, 3, 4
),
o as (
  select o.business_date, o.platform_era, coalesce(cs.default_channel_group, 'Unattributed') as channel_group,
    coalesce(e.metro_key, o.billing_metro_key) as metro_key,
    countif(not o.is_transfer) as orders, countif(o.order_type = 'ticket' and not o.is_transfer) as ticket_orders,
    sum(if(o.is_transfer, 0, o.seats)) as seats,
    sum(if(o.is_transfer, 0, o.gross_revenue)) as gross_revenue, sum(if(o.is_transfer, 0, o.net_revenue)) as net_revenue,
    sum(if(o.order_type = 'ticket' and not o.is_transfer, o.net_revenue, 0)) as ticket_net_revenue,
    countif(o.is_first_order and not o.is_transfer) as new_customers,
    sum(coalesce(bk.net_distributable, 0)) as net_distributable, sum(coalesce(bk.sns_share, 0)) as sns_share
  from {{ ref('core_orders') }} o
  left join {{ ref('core_session_orders') }} so using (order_key)
  left join {{ ref('core_sessions') }} cs using (session_key)
  left join (select order_key, any_value(event_key) as event_key from {{ ref('core_order_items') }} where item_type = 'ticket' group by order_key) oi using (order_key)
  left join {{ ref('core_events') }} e using (event_key)
  -- Bookings carry no business_date of their own; aggregated to one row per order_key first so this
  -- join can never fan the order out and change any existing measure above.
  left join (select order_key, sum(net_distributable) as net_distributable, sum(sns_share) as sns_share
             from {{ ref('core_bookings') }} group by order_key) bk using (order_key)
  group by 1, 2, 3, 4
),
oc as (
  select business_date, platform_era, channel_group, sum(ticket_orders) as channel_ticket_orders
  from o group by 1, 2, 3
),
grid as (
  select business_date, platform_era, channel_group, metro_key from s
  union distinct
  select business_date, platform_era, channel_group, metro_key from o
  union distinct
  select business_date, platform_era, channel_group, cast(null as string) from oc
)
select g.business_date, g.platform_era, g.channel_group, g.metro_key,
  coalesce(s.sessions, 0) as sessions, coalesce(s.engaged_sessions, 0) as engaged_sessions,
  coalesce(o.orders, 0) as orders, coalesce(o.ticket_orders, 0) as ticket_orders, coalesce(o.seats, 0) as seats,
  coalesce(o.gross_revenue, 0) as gross_revenue, coalesce(o.net_revenue, 0) as net_revenue,
  coalesce(o.net_distributable, 0) as net_distributable, coalesce(o.sns_share, 0) as sns_share,
  coalesce(o.ticket_net_revenue, 0) as ticket_net_revenue,
  case when g.metro_key is null then coalesce(oc.channel_ticket_orders, 0) end as channel_ticket_orders,
  case when g.metro_key is null and f.flag is null then safe_divide(coalesce(oc.channel_ticket_orders, 0), s.sessions) end as cvr,
  safe_divide(o.net_revenue, o.orders) as aov, coalesce(o.new_customers, 0) as new_customers,
  f.flag is not null as unreliable_ga4
from grid g
left join s on g.business_date = s.business_date and g.platform_era = s.platform_era and g.channel_group = s.channel_group
  and coalesce(g.metro_key, '') = coalesce(s.metro_key, '')
left join o on g.business_date = o.business_date and g.platform_era = o.platform_era and g.channel_group = o.channel_group
  and coalesce(g.metro_key, '') = coalesce(o.metro_key, '')
left join oc on g.metro_key is null and g.business_date = oc.business_date and g.platform_era = oc.platform_era
  and g.channel_group = oc.channel_group
left join {{ ref('date_flags') }} f on f.date = g.business_date and f.flag = 'unreliable_ga4'
