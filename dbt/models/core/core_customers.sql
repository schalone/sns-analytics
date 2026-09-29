-- One row per resolved customer across both eras. Orders that resolved to nobody create no customer.
-- A woo-cust-<id> key is a registered legacy account whose email was never recovered (is_surrogate).
-- A legacy transfer order (is_transfer) is not a purchase: it is left out of order counts and ranking
-- (lifetime_orders, is_repeat, first and second purchase dates, first_era, first order channel). Seats,
-- events, money and home metro come from the bookings that hold seats: a superseded transfer and a root
-- line whose every seat moved to a transfer are left out, so the moved seat counts once, at its new event.
with o as (
  select order_key, customer_hash, identity_source, created_at, business_date, platform_era
  from {{ ref('core_orders') }}
  where customer_hash is not null and identity_source != 'unresolved' and not is_transfer
),
seat_bookings as (
  select *
  from {{ ref('core_bookings') }}
  where booking_kind != 'transfer_superseded' and (seats > 0 or seats_transferred_out = 0)
),
ranked as (
  select *, row_number() over (partition by customer_hash order by created_at, order_key) as n
  from o
),
order_stats as (
  select customer_hash,
    min(business_date) as first_purchase_date,
    max(business_date) as most_recent_purchase_date,
    count(*) as lifetime_orders,
    array_agg(distinct platform_era order by platform_era) as eras_seen,
    count(distinct platform_era) > 1 as bought_in_both_eras,
    max(if(n = 1, platform_era, null)) as first_era,
    max(if(n = 1, order_key, null)) as first_order_key,
    max(if(n = 1, business_date, null)) as first_order_date,
    max(if(n = 2, business_date, null)) as second_order_date,
    logical_and(identity_source = 'woo_surrogate') as is_surrogate
  from ranked
  group by customer_hash
),
booking_stats as (
  select customer_hash,
    count(distinct event_key) as lifetime_events,
    sum(net_seats) as lifetime_seats,
    sum(realized_revenue - refunded_amount) as lifetime_realized_revenue,
    sum(sns_share) as lifetime_sns_share
  from seat_bookings
  where customer_hash is not null and identity_source != 'unresolved'
  group by customer_hash
),
home as (
  select b.customer_hash, e.metro_key
  from seat_bookings b
  join {{ ref('core_events') }} e using (event_key)
  where b.customer_hash is not null and e.metro_key is not null
  group by b.customer_hash, e.metro_key
  qualify row_number() over (partition by b.customer_hash order by count(*) desc, max(b.purchase_date) desc, e.metro_key) = 1
),
first_channel as (
  select os.customer_hash, s.default_channel_group
  from order_stats os
  join {{ ref('core_session_orders') }} so on so.order_key = os.first_order_key
  join {{ ref('core_sessions') }} s on s.session_key = so.session_key
)
select os.customer_hash, os.is_surrogate, os.first_purchase_date, os.most_recent_purchase_date,
  os.first_era, os.eras_seen, os.bought_in_both_eras,
  os.lifetime_orders,
  coalesce(bs.lifetime_events, 0) as lifetime_events,
  coalesce(bs.lifetime_seats, 0) as lifetime_seats,
  round(coalesce(bs.lifetime_realized_revenue, 0), 6) as lifetime_realized_revenue,
  round(coalesce(bs.lifetime_sns_share, 0), 6) as lifetime_sns_share,
  h.metro_key as home_metro_key,
  fc.default_channel_group as first_order_channel,
  os.lifetime_orders > 1 as is_repeat,
  date_diff(os.second_order_date, os.first_order_date, day) as days_first_to_second_purchase
from order_stats os
left join booking_stats bs using (customer_hash)
left join home h using (customer_hash)
left join first_channel fc using (customer_hash)
