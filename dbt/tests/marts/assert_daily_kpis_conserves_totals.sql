-- Controller ruling 5: mart_daily_kpis must not lose or double-count session/order volume across
-- the grid join. Fails if sum(sessions) != count(*) in core_sessions, sum(orders) != count(*) in
-- core_orders, or sum(net_revenue) differs from core_orders' sum(net_revenue) by more than 1 cent.
-- Final-review I1 / minors: also ticket_net_revenue (ticket orders' net revenue, within 1 cent) and
-- channel_ticket_orders summed over null-metro rows (must equal the number of ticket orders).
with mart as (
  select sum(sessions) as sessions, sum(orders) as orders, sum(net_revenue) as net_revenue,
    sum(ticket_net_revenue) as ticket_net_revenue,
    sum(if(metro_key is null, channel_ticket_orders, 0)) as channel_ticket_orders
  from {{ ref('mart_daily_kpis') }}
),
sessions_truth as (
  select count(*) as sessions from {{ ref('core_sessions') }}
),
orders_truth as (
  select count(*) as orders, sum(net_revenue) as net_revenue,
    sum(if(order_type = 'ticket', net_revenue, 0)) as ticket_net_revenue, countif(order_type = 'ticket') as ticket_orders
  from {{ ref('core_orders') }}
)
select mart.sessions as mart_sessions, sessions_truth.sessions as core_sessions,
  mart.orders as mart_orders, orders_truth.orders as core_orders,
  mart.net_revenue as mart_net_revenue, orders_truth.net_revenue as core_net_revenue,
  mart.ticket_net_revenue as mart_ticket_net_revenue, orders_truth.ticket_net_revenue as core_ticket_net_revenue,
  mart.channel_ticket_orders as mart_channel_ticket_orders, orders_truth.ticket_orders as core_ticket_orders
from mart, sessions_truth, orders_truth
where mart.sessions != sessions_truth.sessions
   or mart.orders != orders_truth.orders
   or abs(mart.net_revenue - orders_truth.net_revenue) > 0.01
   or abs(mart.ticket_net_revenue - orders_truth.ticket_net_revenue) > 0.01
   or mart.channel_ticket_orders != orders_truth.ticket_orders
