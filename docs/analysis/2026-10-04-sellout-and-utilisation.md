# Sellouts and utilisation, legacy era (ANALYSIS-001)

**Date:** 2026-10-04. **Data:** production `core.core_event_economics` and `core.core_venues` as built on 2026-10-02. **Queries:** every table below comes from a query over the base definitions in `docs/analysis/sql/2026-10-04-sellout-base.sql`; the query text is given with each table. **Status:** figures re-run by an independent reviewer on 2026-10-04 (see the review note at the end).

## What this answers

The venture brief's Analysis A (which events repeatedly sell out early enough to indicate underpricing or insufficient supply) and Analysis B (what predicts underutilisation), for the legacy era. Nothing here covers the new platform: its data is not loaded yet, so every figure ends on 2026-06-18.

## Population

Legacy events with a published status, an event date between 2022-01-01 and 2026-06-18, and a recorded capacity. Two cuts are used:

- **All events with sales**: 10,652 events.
- **Public classes** (the pricing population): modern calligraphy, themed and seasonal, brush lettering and kids classes, priced $55 to $84 a seat, capacity at least 8, with a known venue. 9,423 events. This excludes private and corporate bookings (priced per event, about $480 each, mostly 1 to 6 seats), virtual classes, events with no venue on record, and 714 public-type classes priced outside $55 to $84 or with fewer than 8 seats.

Published events that never sold a seat are counted separately (143 to 250 a year). The archive does not say whether they were cancelled before sales opened.

Legacy ticket prices are the seat-weighted list price of the event's ticket products. Capacity is the final recorded capacity, so an event whose capacity was raised mid-sale reads as having sold out later than it did.

## Headline: public classes by year

| Year | Events | Seats offered | Seats sold | Fill | Sold out | Sold out 7+ days early | Sold out 14+ days early | Under 40% full | Empty seats | S&S share |
|---|---|---|---|---|---|---|---|---|---|---|
| 2022 | 2,084 | 39,823 | 25,390 | 64% | 20% | 12% | 8% | 23% | 14,433 | $641,975 |
| 2023 | 1,853 | 33,600 | 18,009 | 54% | 15% | 7% | 4% | 35% | 15,591 | $475,091 |
| 2024 | 1,709 | 30,944 | 18,427 | 60% | 21% | 12% | 8% | 29% | 12,517 | $476,483 |
| 2025 | 2,452 | 46,519 | 29,079 | 63% | 24% | 16% | 11% | 24% | 17,440 | $741,184 |
| 2026 to 18 Jun | 1,325 | 25,097 | 15,565 | 62% | 24% | 13% | 8% | 26% | 9,532 | $399,991 |

Average seat price stayed between $66 and $69 in every year.

Two things sit side by side. In 2025, 381 public classes sold out at least a week early, and 17,440 seats went unsold, more than a third of all seats offered. Both are large. The empty seats are the larger number.

```sql
-- base.sql, then:
select yr, count(*) events, sum(capacity) seats_offered, sum(seats_sold) seats_sold, round(sum(seats_sold)/sum(capacity),3) fill,
  round(countif(sold_out)/count(*),3) sold_out_share, round(countif(sold_out and days_before_at_sellout >= 7)/count(*),3) sold_out_7d_early,
  round(countif(sold_out and days_before_at_sellout >= 14)/count(*),3) sold_out_14d_early, round(countif(utilisation<.4)/count(*),3) under40,
  sum(capacity - seats_sold) empty_seats, round(sum(sns_share)) sns_share, round(avg(ticket_price),2) avg_price from pub group by 1 order by 1
```

## Finding 1. When sold-out classes sell out

Public classes that sold out, 2024 to June 2026 (1,252 events):

| Sold out | Events | Share |
|---|---|---|
| On the event day | 94 | 8% |
| 1 to 3 days before | 250 | 20% |
| 4 to 7 days before | 203 | 16% |
| 8 to 14 days before | 203 | 16% |
| 15 to 30 days before | 331 | 26% |
| More than 30 days before | 171 | 14% |

Four in ten sold-out classes filled more than two weeks out. For those, every seat that would have sold in the last two weeks was turned away.

```sql
select case when days_before_at_sellout = 0 then 'event day' when days_before_at_sellout <= 3 then '1-3 days' when days_before_at_sellout <= 7 then '4-7'
  when days_before_at_sellout <= 14 then '8-14' when days_before_at_sellout <= 30 then '15-30' else '31+' end bucket, count(*) sold_out_events,
  round(count(*)/sum(count(*)) over (),3) share from pub where yr >= 2024 and sold_out group by 1 order by min(days_before_at_sellout)
```

## Finding 2. Markets split into two groups

Public classes, 2025 to June 2026, markets with at least 20 events. Market is the venue's city, since the legacy archive has no metro field. Ranked by the share of classes that sold out at least a week early.

| Market | Events | Fill | Sold out | Sold out 7+ days early | Under 40% | Empty seats | Avg capacity | S&S share per seat offered |
|---|---|---|---|---|---|---|---|---|
| Orlando, FL | 20 | 91% | 60% | 50% | 5% | 21 | 12.0 | $23.54 |
| San Antonio, TX | 52 | 82% | 58% | 42% | 12% | 87 | 9.4 | $20.39 |
| Anaheim, CA | 23 | 84% | 39% | 35% | 9% | 76 | 20.7 | $22.57 |
| Houston, TX | 63 | 85% | 44% | 35% | 6% | 135 | 14.8 | $21.63 |
| Ann Arbor, MI | 21 | 78% | 38% | 33% | 5% | 61 | 13.3 | $19.45 |
| Gilbert, AZ | 23 | 68% | 48% | 30% | 17% | 127 | 17.4 | $17.16 |
| Dallas, TX | 60 | 84% | 55% | 30% | 12% | 138 | 14.3 | $21.05 |
| New York, NY | 65 | 83% | 45% | 28% | 9% | 199 | 18.3 | $22.08 |
| Hilliard, OH | 25 | 68% | 36% | 28% | 24% | 78 | 9.8 | $17.03 |
| San Clemente, CA | 24 | 84% | 42% | 21% | 4% | 49 | 13.1 | $22.62 |
| Englewood, CO | 24 | 84% | 42% | 21% | 8% | 71 | 18.9 | $21.34 |
| Raleigh, NC | 25 | 58% | 28% | 20% | 28% | 186 | 17.6 | $14.67 |
| Nashville, TN | 39 | 57% | 23% | 18% | 31% | 206 | 12.2 | $15.17 |
| Woodinville, WA | 28 | 65% | 25% | 18% | 29% | 175 | 18.0 | $16.43 |
| Jacksonville, FL | 35 | 64% | 23% | 17% | 23% | 187 | 15.0 | $16.54 |
| Richardson, TX | 25 | 80% | 48% | 16% | 12% | 72 | 14.7 | $20.37 |
| Washington, DC | 42 | 68% | 24% | 12% | 17% | 263 | 19.7 | $17.18 |
| Seattle, WA | 25 | 72% | 24% | 12% | 20% | 117 | 16.5 | $17.92 |
| Tampa, FL | 27 | 65% | 11% | 11% | 19% | 195 | 20.7 | $16.37 |
| Chicago, IL | 35 | 70% | 17% | 11% | 17% | 268 | 25.1 | $19.09 |
| Denver, CO | 70 | 61% | 16% | 11% | 21% | 370 | 13.5 | $15.32 |
| Johns Creek, GA | 22 | 67% | 18% | 9% | 23% | 92 | 12.8 | $16.93 |
| Charlotte, NC | 71 | 46% | 14% | 8% | 38% | 783 | 20.4 | $11.53 |
| Austin, TX | 41 | 58% | 22% | 7% | 22% | 318 | 18.4 | $14.28 |
| Fort Worth, TX | 30 | 58% | 7% | 7% | 20% | 260 | 20.8 | $14.54 |
| Atlanta, GA | 35 | 57% | 11% | 6% | 34% | 341 | 22.4 | $13.95 |
| Durham, NC | 20 | 78% | 30% | 5% | 15% | 88 | 20.3 | $19.30 |
| Brooklyn, NY | 24 | 64% | 13% | 4% | 21% | 204 | 23.7 | $16.65 |
| Boston, MA | 31 | 51% | 19% | 3% | 42% | 352 | 23.1 | $12.44 |
| Columbia, SC | 21 | 48% | 5% | 0% | 43% | 255 | 23.2 | $12.07 |
| Waltham, MA | 20 | 51% | 10% | 0% | 30% | 235 | 23.8 | $12.39 |
| Santa Clara, CA | 33 | 54% | 6% | 0% | 33% | 230 | 15.1 | $14.10 |
| San Diego, CA | 39 | 40% | 0% | 0% | 49% | 445 | 19.1 | $11.02 |
| Baltimore, MD | 41 | 44% | 10% | 0% | 29% | 565 | 24.8 | $11.16 |

The top of the table (Orlando, San Antonio, Houston, Dallas, New York, Anaheim) sells out early and often, with fill above 80 percent. The bottom (Baltimore, San Diego, Santa Clara, Waltham, Columbia, Boston, Charlotte) rarely sells out and leaves half to 60 percent of seats empty. Charlotte alone left 783 seats empty in eighteen months. The top group earns $20 to $24 of S&S share per seat offered; the bottom group $11 to $14.

Note the capacity column: most early-sellout markets run smaller rooms (San Antonio 9, Houston and Dallas 14 to 15) and most under-filled markets larger ones (Baltimore, Boston, Columbia, Waltham 23 to 25). New York and Anaheim sell out early in rooms of 18 to 21, and Santa Clara under-fills rooms of 15, so size is not the whole story. Finding 4 takes this apart.

```sql
select market, count(*) events, round(sum(seats_sold)/sum(capacity),2) fill, round(countif(sold_out)/count(*),2) sold_out,
  round(countif(sold_out and days_before_at_sellout >= 7)/count(*),2) sold_out_7d, round(countif(utilisation < .4)/count(*),2) under40,
  sum(capacity - seats_sold) empty_seats, round(avg(ticket_price)) price, round(avg(capacity),1) cap, round(sum(sns_share)/sum(capacity),2) sns_per_seat
from pub where yr >= 2025 group by 1 having count(*) >= 20 order by sold_out_7d desc
```

## Finding 3. Class type, weekday and time

Public and other classes, 2024 to June 2026:

| Class type | Events | Fill | Sold out | Under 40% | Avg price | Avg capacity |
|---|---|---|---|---|---|---|
| Modern calligraphy | 3,876 | 64% | 26% | 24% | $67 | 18.0 |
| Themed and seasonal | 1,856 | 58% | 20% | 29% | $71 | 18.7 |
| Brush lettering | 180 | 59% | 23% | 31% | $72 | 17.8 |
| Virtual | 96 | 37% | 16% | 51% | $70 | 17.4 |
| Private and corporate | 160 | 61% | 77% | 6% | $482 | 5.6 |

Class type is derived from the event title by keyword; the legacy archive has no category field. Themed classes fill less than plain modern calligraphy despite a higher price. Virtual classes fill worst of all.

Weekday, all events with sales 2024 onward: Sunday fills best (66 percent, 30 percent sold out) and Wednesday and Thursday worst (59 percent). Thursday is the most scheduled day (1,183 events) and Wednesday the second (1,132). Afternoon starts between 13:00 and 16:00 fill 63 to 67 percent and sell out 36 to 41 percent of the time; the 18:00 slot, which holds 3,110 of the 6,184 events, fills 62 percent and sells out 23 percent of the time. The 17:00 slot is the weakest evening start at 55 percent.

```sql
select class_type, count(*) events, round(sum(seats_sold)/sum(capacity),2) fill, round(countif(sold_out)/count(*),2) sold_out_share,
  round(countif(utilisation<.4)/count(*),2) under40_share, round(avg(ticket_price)) avg_price, round(avg(capacity),1) avg_cap from sold where yr >= 2024 group by 1 order by events desc;
select weekday, count(*) events, round(sum(seats_sold)/sum(capacity),2) fill, round(countif(sold_out)/count(*),2) sold_out_share, round(countif(utilisation<.4)/count(*),2) under40_share from sold where yr >= 2024 group by 1;
select start_hour_local, count(*) events, round(sum(seats_sold)/sum(capacity),2) fill, round(countif(sold_out)/count(*),2) sold_out_share, round(countif(utilisation<.4)/count(*),2) under40_share from sold where yr >= 2024 group by 1 having count(*) >= 40 order by 1
```

## Finding 4. Capacity is the strongest single predictor, and it hides demand

Public classes, 2024 to June 2026, by room size:

| Capacity | Events | Fill | Seats sold per event | Sold out | Sold out 7+ days early | Under 40% | S&S share per seat offered | S&S share per event |
|---|---|---|---|---|---|---|---|---|
| 12 or fewer | 1,313 | 74% | 7.9 | 37% | 25% | 16% | $19.10 | $204 |
| 13 to 16 | 1,268 | 69% | 10.4 | 26% | 15% | 20% | $17.93 | $269 |
| 17 to 20 | 1,352 | 58% | 11.3 | 16% | 9% | 34% | $14.83 | $289 |
| 21 to 30 | 1,286 | 60% | 15.2 | 16% | 7% | 31% | $15.28 | $388 |
| 31 or more | 267 | 44% | 17.4 | 6% | 3% | 51% | $11.33 | $444 |

Small rooms sell out because they are small. A sellout in a 10-seat room says less about demand than a sellout in a 20-seat room. The question is whether the small rooms are leaving demand on the table. Within each market, comparing small rooms (14 seats or fewer) with large ones (18 or more), 2024 onward:

| Market | Small rooms | Seats sold, small | Sold out, small | Large rooms | Seats sold, large | Sold out, large |
|---|---|---|---|---|---|---|
| Dallas, TX | 60 | 9.6 | 55% | 26 | 16.6 | 31% |
| Houston, TX | 50 | 9.6 | 52% | 27 | 19.8 | 22% |
| New York, NY | 11 | 9.2 | 45% | 32 | 16.2 | 25% |
| Washington, DC | 11 | 10.1 | 45% | 32 | 15.3 | 16% |
| Denver, CO | 92 | 6.6 | 18% | 14 | 14.5 | 7% |
| Jacksonville, FL | 24 | 8.6 | 29% | 10 | 12.8 | 20% |
| Ferndale, MI | 16 | 10.6 | 63% | 11 | 14.3 | 27% |
| Raleigh, NC | 10 | 9.0 | 40% | 13 | 13.8 | 38% |
| Charlotte, NC | 36 | 9.3 | 42% | 48 | 9.3 | 0% |
| Gilbert, AZ | 13 | 12.3 | 69% | 10 | 10.5 | 10% |
| Nashville, TN | 42 | 6.7 | 26% | 10 | 8.3 | 10% |
| Seattle, WA | 10 | 10.4 | 50% | 12 | 11.5 | 8% |
| Worcester, MA | 10 | 7.7 | 40% | 11 | 10.0 | 18% |

In Dallas, Houston, New York and Washington, a large room sells 51 to 106 percent more seats than a small one in the same market. There, a small-room sellout is unmet demand, and the lever is a bigger room or a higher price. In Charlotte, Gilbert and Seattle, a large room sells no more seats than a small one: demand in those markets is capped at about 9 to 12 seats a class, and large rooms only create empty seats.

```sql
select capacity_band, count(*) events, round(sum(seats_sold)/sum(capacity),2) fill, round(avg(seats_sold),1) avg_seats_sold, round(countif(sold_out)/count(*),2) sold_out,
  round(countif(sold_out and days_before_at_sellout>=7)/count(*),2) sold_out_7d, round(countif(utilisation<.4)/count(*),2) under40,
  round(sum(sns_share)/sum(capacity),2) sns_per_seat_offered, round(sum(sns_share)/count(*),0) sns_per_event from pub where yr >= 2024 group by 1 order by min(capacity);
select market, countif(capacity <= 14) small_n, round(avg(if(capacity<=14, seats_sold, null)),1) small_seats, round(safe_divide(countif(capacity<=14 and sold_out), countif(capacity<=14)),2) small_soldout,
  countif(capacity >= 18) large_n, round(avg(if(capacity>=18, seats_sold, null)),1) large_seats, round(safe_divide(countif(capacity>=18 and sold_out), countif(capacity>=18)),2) large_soldout
from pub where yr >= 2024 group by 1 having countif(capacity<=14) >= 10 and countif(capacity>=18) >= 10
```

## Finding 5. Price: the closest thing to a controlled comparison

Modern calligraphy classes in rooms of 16 to 20 seats, 2024 to June 2026:

| Price | Events | Avg capacity | Fill | Seats sold per event | Sold out | S&S share per event |
|---|---|---|---|---|---|---|
| $65 to $69 | 814 | 18.5 | 65% | 12.0 | 21% | $300 |
| $70 to $74 | 240 | 18.6 | 54% | 10.0 | 13% | $268 |
| $75 to $84 | 93 | 18.5 | 62% | 11.6 | 23% | $337 |

At $75 to $84 these classes sold almost as many seats as at $65 to $69 (11.6 against 12.0 a class) and earned $37 more of S&S share per event. The $70 to $74 band sold fewer. This is observational: the higher-priced classes may sit in stronger markets or with stronger instructors, and 93 events is a small group. It is consistent with low price sensitivity in the $65 to $85 range, and it is exactly what Experiment 1 in the brief should test.

```sql
select price_band, count(*) events, round(avg(capacity),1) cap, round(sum(seats_sold)/sum(capacity),2) fill, round(avg(seats_sold),1) seats,
  round(countif(sold_out)/count(*),2) sold_out, round(sum(sns_share)/count(*)) sns_per_event from pub where yr >= 2024 and class_type = 'Modern calligraphy' and capacity between 16 and 20 group by 1 having count(*) >= 30 order by min(ticket_price)
```

## Finding 6. Season and instructor

Public classes, 2024 and 2025, by event month: fill is highest in April (72 percent, 34 percent sold out) and lowest in October to December (54 percent, 13 to 19 percent sold out, 35 percent of classes under 40 percent full). October is also the most scheduled month, with 446 events against a monthly average of 347. The fourth quarter alone left 6,481 seats empty in 2025. Supply is added in the months where demand per class is weakest.

Instructors, public classes 2025 onward with at least 25 events (70 instructors): the top ten fill 84 to 93 percent of their seats and sell out 27 to 65 percent of their classes; the bottom ten fill 25 to 44 percent and sell out 0 to 15 percent. The bottom ten also teach in larger rooms (about 23 seats against 17), so part of the gap is room size, not the instructor. Instructor keys are legacy ids; names are in `core.core_instructors`. Instructor and market are entangled, since most instructors work in one or two markets, so this is a flag for further work, not a ranking.

```sql
select month, count(*) events, round(sum(seats_sold)/sum(capacity),2) fill, round(countif(sold_out)/count(*),2) sold_out, round(countif(utilisation<.4)/count(*),2) under40 from pub where yr in (2024, 2025) group by 1 order by 1;
select instructor_key, count(*) events, count(distinct market) markets, round(sum(seats_sold)/sum(capacity),2) fill, round(countif(sold_out)/count(*),2) sold_out, round(countif(utilisation<.4)/count(*),2) under40, round(avg(capacity),1) cap from pub where yr >= 2025 group by 1 having count(*) >= 25 order by fill desc
```

## Opportunity register, version 0

Sized on public classes in 2025 (2,452 events, 29,079 seats sold, 17,440 empty, S&S share $741,184, $25.49 of S&S share per seat sold). Each line is a hypothesis for an experiment, not a forecast. The sizing assumes the stated change and no other effect.

| Type | Observation | Candidate action | 2025 base | Illustrative annual S&S share | Confidence |
|---|---|---|---|---|---|
| Pricing | 381 public classes sold out 7+ days early, 5,732 seats, avg $66.58 | Test +$5 on comparable classes (Experiment 1) | 5,732 seats | +$11,500 at no volume loss; +$23,000 at +$10 (S&S 40% share, before the processing fee on the increment) | Medium: Finding 5 suggests low sensitivity; untested |
| Capacity | In Dallas, Houston, New York, Washington, larger rooms sell 51 to 106% more seats | Move early-sellout classes in those markets to rooms 4 to 6 seats larger | 63 early sellouts in those four markets since 2025 (38 in 2025) | +$6,400 to +$9,600 a year at $25.49 a seat if the added seats sell as the large rooms do | Medium: within-market evidence, confounded by venue |
| Underperformance | 595 classes under 40% full left 10,262 seats empty | Fewer, better-placed classes in the bottom markets; see scheduling | 10,262 seats | Each 10% of those seats recovered = +$26,000 | Low until causes are separated |
| Scheduling | Oct to Dec: most classes, lowest fill, 6,481 empty seats | Shift Q4 supply toward Mar to Jul, or toward markets in the top group | 6,481 seats | Each 10% recovered = +$16,500 | Medium: pattern holds in both years |
| Capacity, reverse | Charlotte and Gilbert large rooms sell no more than small ones | Smaller rooms, fewer classes | 783 empty seats in Charlotte | Venue cost saving, not modelled here | Medium |
| Marketing | No Meta spend loaded; Google only since 25 Sep | Load Meta history (CSV drop) before any paid-media opportunity is sized | none | none yet | n/a |

The brief's target is $250,000 of identified annualised opportunity. The pricing and capacity lines above sum to roughly $18,000 to $33,000 on their own. The larger money is in the empty seats, where the cause is not yet separated between market demand, venue, instructor, timing and marketing. That separation is the next analysis.

## Caveats

- Legacy era only. The new platform's classes since 19 June 2026 are not loaded.
- Market is the venue's city, not a metro. Suburbs appear as separate markets (Richardson beside Dallas, Englewood beside Denver, Brooklyn beside New York).
- Class type is inferred from titles.
- Capacity is the final recorded capacity, so raised capacities understate how early a class really filled.
- Zero-sale published events (143 to 250 a year) are excluded from fill figures. If they were cancelled before sales opened they are not failures; if they were on sale, fill is overstated.
- Seats are net of refunds and transfers (a transferred seat counts at the class attended).
- Seats paid for by gift card or store credit carry no Stripe fee; they are included. Their share is not measured in this report.
- Sold-out status and sellout timing use final net seats. A class that filled and then lost a seat to a refund or transfer counts as not sold out, so early sellouts are understated. A few classes are oversold against recorded capacity (the 381 early sellouts of 2025 sold 5,732 seats against 5,707 capacity).
- Private and corporate bookings are excluded from every public-class figure. They were about $28,000 of S&S share in 2025 and sell out by design.

## Next

1. Separate the causes of under-filling: a model of seats sold per class on market, venue, instructor, weekday, hour, month, price and capacity, with the large-room markets as the test of whether demand or supply binds.
2. Customer retention cohorts (ANALYSIS-002), now that identity resolves across the whole legacy era.
3. Booking-curve pace bands per market, so a live class can be read as ahead or behind.
4. Once Meta spend is loaded: contribution after ads by market and month.
