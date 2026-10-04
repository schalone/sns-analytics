with ev as (
  select e.event_key, e.event_date, extract(year from e.event_date) yr, e.weekday, e.is_weekend, e.start_hour_local, e.month, e.season,
    e.capacity, e.ticket_price, e.seats_sold, e.utilisation, e.utilisation_band, e.sold_out, e.realized_revenue, e.sns_share,
    e.sns_share_per_available_seat, e.first_sale_days_before, e.days_before_at_50pct, e.days_before_at_sellout, e.instructor_key,
    v.city, v.state, concat(coalesce(v.city,'?'), ', ', coalesce(v.state,'?')) market,
    case when regexp_contains(lower(e.title), r'virtual|online|zoom') then 'Virtual'
         when regexp_contains(lower(e.title), r'brush') then 'Brush lettering'
         when regexp_contains(lower(e.title), r'holiday|christmas|ornament|gift tag|valentine|galentine|halloween|spooky|pumpkin|easter|patrick|mother|father|thanksgiving|hanukkah|new year|wedding|place card|envelope') then 'Themed / seasonal'
         when regexp_contains(lower(e.title), r'private|corporate|team') then 'Private / corporate'
         when regexp_contains(lower(e.title), r'kid|child|teen|family') then 'Kids / family'
         when regexp_contains(lower(e.title), r'calligraphy|letter|script') then 'Modern calligraphy'
         else 'Other' end class_type,
    case when e.ticket_price < 60 then '<$60' when e.ticket_price < 65 then '$60-64' when e.ticket_price < 70 then '$65-69' when e.ticket_price < 75 then '$70-74' when e.ticket_price < 85 then '$75-84' else '$85+' end price_band,
    case when e.capacity <= 12 then '<=12' when e.capacity <= 16 then '13-16' when e.capacity <= 20 then '17-20' when e.capacity <= 30 then '21-30' else '31+' end capacity_band
  from sipandscript.core.core_event_economics e
  left join sipandscript.core.core_venues v using (venue_key)
  where e.platform_era = 'legacy_event_tickets' and e.has_event_date and e.status = 'publish' and e.capacity > 0
    and e.event_date between '2022-01-01' and '2026-06-18'
),
sold as (select * from ev where seats_sold > 0)
, pub as (select * from sold where class_type in ('Modern calligraphy','Themed / seasonal','Brush lettering','Kids / family') and ticket_price between 55 and 84 and capacity >= 8 and city is not null)
