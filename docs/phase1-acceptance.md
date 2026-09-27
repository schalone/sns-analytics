# Phase-one acceptance (Task 14, step 5)

Date: 2026-09-27.

This records what could be measured today against spec §11 ("Success criteria for phase one"),
given that `raw_cms`, `raw_stripe`, `raw_gsc` and `raw_spend` are all empty and the Google Ads
Data Transfer has not been authorised. Task 14's own acceptance query (spec §11 criterion 3) only
has legacy (WooCommerce) data to draw on today; the new-site half of every criterion cannot be
produced until the blockers below clear.

## What was measured

### Legacy-era order totals by `order_type`, 2025-06-23..2025-09-17 and 2026-06-23..2026-09-17

Query: `select source_system, order_type, count(*) orders, round(sum(gross_revenue)) gross from
core.core_orders where business_date between '2025-06-23' and '2025-09-17' or business_date
between '2026-06-23' and '2026-09-17' group by 1,2 order by 1,2`.

| source_system | order_type | orders | gross ($) |
|---|---|---:|---:|
| woocommerce | gift_card | 8 | 715 |
| woocommerce | materials | 169 | 43,225 |
| woocommerce | ticket | 6,480 | 585,698 |

No rows for the 2026-06-23..2026-09-17 window or for `source_system = 'webapp'`: `raw_cms` is
empty (no CMS loader has run against the export API yet), so there are no new-site orders in
`core.core_orders` at all today.

### Sessions / orders / CVR by channel, same legacy window, from `mart.daily_kpis`

Query: `select channel_group, sum(sessions) sessions, sum(orders) orders, sum(ticket_orders)
ticket_orders, safe_divide(sum(ticket_orders), sum(sessions)) cvr, sum(net_revenue) net_revenue
from mart.mart_daily_kpis where business_date between '2025-06-23' and '2025-09-17' and metro_key
is null group by 1 order by sessions desc`.

| channel_group | sessions | orders | ticket_orders | cvr | net_revenue ($) |
|---|---:|---:|---:|---:|---:|
| Paid Social | 148,370 | 1,404 | 1,404 | 0.95% | 128,161 |
| Other | 62,228 | 1,600 | 1,541 | 2.48% | 153,078 |
| Organic Search | 34,932 | 1,038 | 987 | 2.83% | 113,521 |
| Organic Social | 24,864 | 365 | 358 | 1.44% | 35,918 |
| Email | 20,832 | 198 | 183 | 0.88% | 21,179 |
| Referral | 15,191 | 256 | 231 | 1.52% | 27,310 |
| Direct | 18 | 0 | 0 | 0.00% | 0 |
| Paid Search | 7 | 0 | 0 | 0.00% | 0 |
| Unattributed | 0 | 1,796 | 1,776 | NULL (0 sessions) | 147,136 |

`Unattributed` covers legacy orders with no matching GA4 purchase event -- 6,226 of 26,753 2025
orders (23.27%) and 3,687 of 14,755 2026 orders (24.99%) core-wide have no `core_session_orders`
match at all (see the Task 13/14 report for the full measurement); its `cvr` is correctly NULL
(zero sessions), not 0.

## Not yet measurable (spec §11 success criteria)

1. **`mart.orders_reconciliation` variance under 1% on every day of the last 30.** Blocked on both
   the CMS export deployment (no `webapp` orders to compare) and the Stripe load (`raw_stripe` is
   empty, and even once it loads, `core_stripe_transactions.order_key` will be NULL on every row
   until a later plan rewrites Stripe order matching -- see the Task 13/14 report, ruling 2).
   `mart.orders_reconciliation` has zero rows today.
2. **The Slack brief's orders, revenue, sessions and CVR from `mart.daily_kpis` match the Stripe
   dashboard for yesterday.** Blocked on the CMS export deployment (no new-site orders) and the
   Stripe load (no Stripe dashboard figures to compare against).
3. **Tickets-only YoY for Jun 23-Sep 17 is computable exactly from `core.orders` across both
   source systems.** Only the legacy (WooCommerce, 2025) half is computable today, shown above;
   the 2026 (webapp/new-site) half is blocked on the CMS export deployment.
4. **`mart.paid_performance` shows spend, orders and ROAS per Google Ads campaign for every day
   since the 2026-09-25 launch.** Blocked on the Google Ads Data Transfer authorisation
   (`google_ads` dataset has no tables; the `google_ads_enabled` dbt var stays false and every
   Google-sourced branch of `core_ad_spend`/`mart_paid_performance` builds as an empty, typed
   select until then) and, for the social side, the Meta/Pinterest CSV drop having real spend rows
   (`raw_spend` is empty) and the Search Console backfill for any search-adjacent context
   (`raw_gsc` is empty, so `core.search_daily` is also empty today).
