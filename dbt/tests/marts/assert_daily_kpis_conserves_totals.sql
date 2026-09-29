-- Controller ruling 5: mart_daily_kpis must not lose or double-count session/order volume across
-- the grid join. Fails if sum(sessions) != count(*) in core_sessions, sum(orders) != count(*) in
-- core_orders, or sum(net_revenue) differs from core_orders' sum(net_revenue) by more than 1 cent.
-- Final-review I1 / minors: also ticket_net_revenue (ticket orders' net revenue, within 1 cent) and
-- channel_ticket_orders summed over null-metro rows (must equal the number of ticket orders).
-- net_distributable and sns_share must equal the same sums over core_bookings, restricted to
-- bookings whose order exists in core_orders (a booking with no matching order -- e.g. the one
-- known negative-total WooCommerce order core_orders drops -- has nothing on the mart side to
-- conserve against). Legacy transfer orders (is_transfer) are not purchases and the mart counts none of their
-- orders, seats or revenue, so the order-side truths exclude them; their bookings' moved money stays in the
-- bookings truth, since the mart reports it on the transfer's row. The tolerance scales with the number of distinct business_dates in the mart:
-- many independently-rounded per-order and per-event sums are being added back together here.
with mart as (
  select sum(sessions) as sessions, sum(orders) as orders, sum(net_revenue) as net_revenue,
    sum(ticket_net_revenue) as ticket_net_revenue,
    sum(if(metro_key is null, channel_ticket_orders, 0)) as channel_ticket_orders,
    sum(net_distributable) as net_distributable, sum(sns_share) as sns_share,
    count(distinct business_date) as days
  from {{ ref('mart_daily_kpis') }}
),
sessions_truth as (
  select count(*) as sessions from {{ ref('core_sessions') }}
),
orders_truth as (
  select count(*) as orders, sum(net_revenue) as net_revenue,
    sum(if(order_type = 'ticket', net_revenue, 0)) as ticket_net_revenue, countif(order_type = 'ticket') as ticket_orders
  from {{ ref('core_orders') }}
  where not is_transfer
),
bookings_truth as (
  select sum(b.net_distributable) as net_distributable, sum(b.sns_share) as sns_share
  from {{ ref('core_bookings') }} b
  where b.order_key in (select order_key from {{ ref('core_orders') }})
)
select mart.sessions as mart_sessions, sessions_truth.sessions as core_sessions,
  mart.orders as mart_orders, orders_truth.orders as core_orders,
  mart.net_revenue as mart_net_revenue, orders_truth.net_revenue as core_net_revenue,
  mart.ticket_net_revenue as mart_ticket_net_revenue, orders_truth.ticket_net_revenue as core_ticket_net_revenue,
  mart.channel_ticket_orders as mart_channel_ticket_orders, orders_truth.ticket_orders as core_ticket_orders,
  mart.net_distributable as mart_net_distributable, bookings_truth.net_distributable as core_net_distributable,
  mart.sns_share as mart_sns_share, bookings_truth.sns_share as core_sns_share
from mart, sessions_truth, orders_truth, bookings_truth
where mart.sessions != sessions_truth.sessions
   or mart.orders != orders_truth.orders
   or abs(mart.net_revenue - orders_truth.net_revenue) > 0.01
   or abs(mart.ticket_net_revenue - orders_truth.ticket_net_revenue) > 0.01
   or mart.channel_ticket_orders != orders_truth.ticket_orders
   or abs(coalesce(mart.net_distributable, 0) - coalesce(bookings_truth.net_distributable, 0)) > 0.01 * greatest(mart.days, 1)
   or abs(coalesce(mart.sns_share, 0) - coalesce(bookings_truth.sns_share, 0)) > 0.01 * greatest(mart.days, 1)
