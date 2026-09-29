-- An allocation convention, not attribution and not a measure of incrementality.
-- Each (date, platform, metro) amount of spend is divided among the events that sold seats that day,
-- in that metro, in proportion to seats. Spend with no metro is divided among every event that sold
-- seats that day. What no event can absorb is kept with event_key null so that money is conserved.
with spend as (
  select date, platform, metro_key, sum(spend) as spend
  from {{ ref('core_ad_spend') }}
  where spend is not null and spend != 0
  group by 1, 2, 3
),
sales as (
  select b.sale_date as date, e.metro_key, b.event_key, sum(b.net_seats) as seats
  from {{ ref('core_bookings') }} b
  join {{ ref('core_events') }} e using (event_key)
  where e.has_event_date
  group by 1, 2, 3
  -- An event absorbs spend only on a day its net seats sold are above zero; a day of only
  -- cancelled bookings absorbs none.
  having sum(b.net_seats) > 0
),
metro_split as (
  select sp.date, sp.platform, sp.metro_key, s.event_key,
    sp.spend * s.seats / sum(s.seats) over (partition by sp.date, sp.platform, sp.metro_key) as spend
  from spend sp
  join sales s on s.date = sp.date and s.metro_key = sp.metro_key
  where sp.metro_key is not null
),
national_split as (
  select sp.date, sp.platform, sp.metro_key, s.event_key,
    sp.spend * s.seats / sum(s.seats) over (partition by sp.date, sp.platform) as spend
  from spend sp
  join (select date, event_key, sum(seats) as seats from sales group by 1, 2) s on s.date = sp.date
  where sp.metro_key is null
),
allocated as (
  select * from metro_split union all select * from national_split
),
remainder as (
  select sp.date, sp.platform, sp.metro_key, cast(null as string) as event_key, sp.spend
  from spend sp
  where not exists (
    select 1 from allocated a
    where a.date = sp.date and a.platform = sp.platform
      and (a.metro_key = sp.metro_key or (a.metro_key is null and sp.metro_key is null))
  )
)
select date, platform, metro_key, event_key, round(spend, 6) as spend from allocated
union all
select date, platform, metro_key, event_key, round(spend, 6) as spend from remainder
