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

Query (corrected 2026-09-27, final-review I1: orders and revenue are summed over ALL rows, because an order
sits on its metro's row; sessions exist only on `metro_key is null` rows; CVR uses `channel_ticket_orders`,
the channel's ticket orders over all metros, which is carried on the null-metro row):
`select channel_group, sum(sessions) sessions, sum(orders) orders, sum(ticket_orders) ticket_orders,
safe_divide(sum(channel_ticket_orders), sum(sessions)) cvr, sum(net_revenue) net_revenue from
mart.mart_daily_kpis where business_date between '2025-06-23' and '2025-09-17' group by 1 order by
sessions desc`.

Re-measured 2026-09-27 after the final-review fixes (I7 order boundary, I11 attribution: `(not set)` is
no longer a source, so those sessions fall through to event parameters or Direct):

| channel_group | sessions | orders | ticket_orders | cvr | net_revenue ($) |
|---|---:|---:|---:|---:|---:|
| Paid Social | 149,222 | 1,431 | 1,431 | 0.96% | 130,258 |
| Direct | 60,394 | 1,513 | 1,456 | 2.41% | 145,709 |
| Organic Search | 35,098 | 1,055 | 1,003 | 2.86% | 114,943 |
| Organic Social | 25,160 | 377 | 370 | 1.47% | 36,923 |
| Email | 20,989 | 210 | 195 | 0.93% | 22,379 |
| Referral | 15,343 | 274 | 248 | 1.62% | 28,890 |
| Other | 229 | 1 | 1 | 0.44% | 65 |
| Paid Search | 7 | 0 | 0 | 0.00% | 0 |
| Unattributed | 0 | 1,796 | 1,776 | NULL (0 sessions) | 147,136 |

(Before the fixes, `Other` held 62,228 sessions, almost all GA4 `(not set)`, and `Direct` 18.)

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
   (`raw_spend` was empty on 2026-09-27). (`raw_gsc` was empty when this section was written; the Search
   Console backfills of 2026-09-27 are recorded below.)

## 2026-09-27 — Search Console backfill attempt (Task 16)

**Access validation: succeeded.** Called `searchanalytics.query` directly (no loader, no BigQuery)
for one day, property `https://www.sipandscript.com/`, dimension `["date"]`, using credentials built
exactly as `loaders/gsc.py`'s `_service()` builds them
(`google.auth.default(scopes=["https://www.googleapis.com/auth/webmasters.readonly"])`). It succeeded
on the first attempt with the user's plain Application Default Credentials — no quota-project retry
was needed (ADC's embedded quota project is a personal project, `vacation-innovations`, not
`sipandscript`, but the Search Console API call did not require it to match). No loader code change is
indicated by this finding.

**Short validation load (~5-8 days, both properties, both dimension sets): succeeded, then rolled
back.** Watermarks for the four `gsc.*` step names were seeded to 5 days before the run and
`load_gsc(..., full=False)` was called with the injected service. All four steps returned `status=ok`:
`gsc.page_query.apex` 132 rows, `gsc.page_device_country.apex` 115 rows, `gsc.page_query.www` 3,975
rows, `gsc.page_device_country.www` 2,553 rows (6,775 rows total, window governed by the loader's
3-day overlap plus 2-day final lag, so roughly 2026-09-16..2026-09-25). No duplicate `key` values were
found within the load.

**Blocking discovery: `RawWriter.append()` (`loaders/common/bq.py`) double-encoded the `payload`
column, making it unusable.** Rebuilding `dbt build --select stg_gsc__page_query+` on the short-loaded
data produced `core.core_search_daily` with `property`, `date`, `page`, `query`, `clicks`,
`impressions` and `position` all `NULL` on all 4,107 rows, which failed
`dbt_utils_unique_combination_of_columns` on `core_search_daily` (all rows collapsed onto one all-NULL
key). Root cause, confirmed by an isolated probe against a throwaway table: `append()` called
`json.dumps(r.payload, default=str)` before assigning the result to the row's `payload` field, and
BigQuery's `load_table_from_json` against a JSON-typed column stored a pre-stringified value as a JSON
**string** scalar, not a JSON **object** — every `json_value(payload, '$.field')` call in every staging
model then returned `NULL`. This affected every loader (`cms`, `stripe`, `gsc`, `spend`), not only
Search Console, and was invisible before this task because no loader had ever written a real row into
any raw table.

**Decision at the time: the 480-day full backfill was not run in this first pass.** Under this task's
original controller rulings, `loaders/` was off-limits, and running the full backfill anyway would have
written a few million further broken rows for no analytic benefit. The short-load rows
(`_run_id = 'local-20260927T150725Z'`) were deleted from `raw_gsc.page_query` and
`raw_gsc.page_device_country`, the four seeded `ops.load_state` rows for `source = 'gsc'` were deleted,
and `core.core_search_daily` was rebuilt back to its prior empty (0-row) state so the repository was
left exactly as it was before Search Console was touched. The whole-project `dbt build` afterward was
green (`PASS=157 WARN=1 ERROR=0`, the one expected `assert_webapp_orders_present` warning).

The bug was fixed the same day — see the next section for the fix and the completed backfill.

## 2026-09-27 — Raw writer fix and completed Search Console backfill (Task 16b)

**Fix.** The bug was found by the first real load on 2026-09-27, fixed in commit `1d4d1b4`, with the
follow-up `64683cc` (non-finite floats become JSON null). `RawWriter.append()` (`loaders/common/bq.py`) now
passes every payload through `_json_safe()`: `json.dumps(payload, default=str)` then `json.loads(...,
parse_constant=...)`, so a JSON-typed column receives a JSON object rather than a pre-serialised string, and
the bare tokens `NaN`/`Infinity`/`-Infinity` (which `json.dumps` does not route through `default`, and which
would make BigQuery reject a whole batch) become `null`. Verified with a real BigQuery round trip
(`json_type(payload) = 'object'`, fields readable via `json_value`) and guarded by
`dbt/tests/staging/assert_raw_payloads_are_objects.sql` (checked against the full backfill below: passes).

**Short validation reload (with the fixed writer): clean.** Same ~5-8 day window as the earlier
attempt (4,107 + 2,668 rows), no duplicate keys within the load, and this time
`core.core_search_daily` came back with real, non-NULL values (`property`, `date`, `clicks`, etc. all
populated; `sum(clicks)` non-NULL).

**Full 480-day backfill: completed.** Both properties, both dimension sets, `full=True`. Took
4,603.2s (~76.7 minutes). All four steps `status=ok`:

| Step | Rows |
|---|---:|
| `gsc.page_query.apex` | 774,837 |
| `gsc.page_device_country.apex` | 555,761 |
| `gsc.page_query.www` | 46,110 |
| `gsc.page_device_country.www` | 26,871 |

No API rate-limiting was encountered; the run completed in one pass.

**Raw table state after the backfill** (includes the short-reload rows, which overlap the tail of
the full-backfill window — expected and harmless, resolved by staging's latest-row dedup):

| Table | Rows | Date range |
|---|---:|---|
| `raw_gsc.page_query` | 825,054 | 2025-06-04 .. 2026-09-24 |
| `raw_gsc.page_device_country` | 585,300 | 2025-06-04 .. 2026-09-24 |

Zero duplicate `key` values were found *within* either the short-reload run or the full-backfill run
individually (checked by `_run_id`). A small number of cross-run duplicate keys exist (10 keys in
each table) between the short reload and the full backfill for days in their overlapping ~8-day
tail — expected, since Search Console can still revise very recent days' query/page rows between two
calls even with `dataState: final`; staging's `latest_raw` macro resolves these to the most recently
loaded row per key, which is correct.

**`core.core_search_daily`: 820,947 rows** (one per distinct `(property, date, page, query)` key from
`stg_gsc__page_query`; the `page_device_country` dimension set has no staging/core model in this
project, per the original design — see `dbt/models/sources.yml` and
`dbt/models/staging/gsc/stg_gsc__page_query.sql`).

**Clicks/impressions for 2026-06-23..2026-09-13 (the September investigation's window), and the
~11,472-click sanity check:**

| Property | Clicks | Impressions |
|---|---:|---:|
| `https://sipandscript.com/` (apex) | 318 | 47,905 |
| `https://www.sipandscript.com/` | 4,779 | 74,551 |
| **Total, both properties** | **5,097** | **122,456** |

**Explanation (2026-09-27, found by the controller after this backfill; final-review I18).** The 5,097 is not
the properties' click total. The Search Console API drops anonymised and low-volume rows whenever `page` is
combined with another dimension, and whenever `query` is requested. For 2026-09-10 (www): dimensions
`[date]` gave 150 clicks, `[date, page]` 153, `[date, device, country]` 150, but `[date, page, query]` and
`[date, page, device, country]` only 61. Both originally loaded sets combine `page` with something else, so
they agree with each other and both lose more than half the clicks. The API's own property totals for this
window, requested on 2026-09-27, are 1,259 (apex) + 10,047 (www) = 11,306 clicks, matching the September
investigation's ~11,472. The loader now fetches the complete sets `totals` (`[date]`), `page`
(`[date, page]`) and `device_country` (`[date, device, country]`), keeps `page_query` for search terms only,
and no longer loads `page_device_country`; the new sets were backfilled the same day (below).

**Acceptance, measured 2026-09-27 from `core.core_search_totals_daily`, 2026-06-23..2026-09-13:**

| Property | Clicks | Impressions | Expected (API, ±1%) |
|---|---:|---:|---:|
| `https://sipandscript.com/` (apex) | 1,259 | 96,700 | 1,259 |
| `https://www.sipandscript.com/` | 10,047 | 100,873 | 10,047 |
| **Total** | **11,306** | **197,573** | **11,306** |

Both match exactly. The www property has data from 2026-07-09 (67 days in the window); apex has all 83.
The same window from the other tables: `core_search_device_country_daily` 1,259 / 10,047 (complete, equal to
the totals); `core_search_page_daily` 1,299 / 10,384 (complete per page; aggregated by page, so slightly
above the property totals); `core_search_daily` (page × query, partial) 318 / 4,779.

**Top 10 queries by clicks, `https://www.sipandscript.com/`, last 28 days of loaded data
(2026-08-28..2026-09-24):**

| # | Query | Clicks | Impressions |
|---|---|---:|---:|
| 1 | sip and script | 750 | 6,373 |
| 2 | calligraphy classes near me | 315 | 3,324 |
| 3 | sip & script | 79 | 814 |
| 4 | sipandscript | 60 | 530 |
| 5 | calligraphy class | 56 | 501 |
| 6 | sip and script near me | 47 | 904 |
| 7 | sip and script nyc | 43 | 395 |
| 8 | calligraphy classes | 37 | 453 |
| 9 | sip & script calligraphy class | 34 | 427 |
| 10 | calligraphy class near me | 30 | 267 |

**Whole-project `dbt build` after the backfill: `PASS=157 WARN=2 ERROR=0`.** The usual
`assert_webapp_orders_present` warning, plus `assert_reconciliation_variance_recent` (30 results). On
2026-09-27 `raw_stripe.balance_transactions` was observed to hold rows (about 65,000 to 75,000 during that
day). The Stripe history load is owned and run by the economic truth layer plan, requires the owner's
approval, and is a full-history load; this pipeline plan did not run it. Confirm with that plan whether the
load has completed before relying on Stripe-derived tables. `raw_cms.orders` held 0 rows.

## 2026-09-27 — Final-review fix wave

**Search Console backfill of the three complete dimension sets** (`totals`, `page`, `device_country`, both
properties, 480 days, one process per set and property, resumable through the per-day watermark):

| Step | Rows loaded | Step | Rows loaded |
|---|---:|---|---:|
| `gsc.totals.apex` | 382 | `gsc.totals.www` | 79 |
| `gsc.page.apex` | 515,553 | `gsc.page.www` | 50,876 |
| `gsc.device_country.apex` | 52,281 | `gsc.device_country.www` | 6,112 |

(Rows of the final resumed run; earlier interrupted runs of the same backfill appended the rest.) Raw tables
afterwards: `raw_gsc.totals` 572 rows, `raw_gsc.page` 836,465, `raw_gsc.device_country` 73,936, all covering
2025-06-04..2026-09-25 (www from 2026-07-09); staging dedupes repeated days to the latest row per key.
`page_query` was not reloaded.

**Orders at the launch boundary (I7).** `core.core_orders` before → after: 110,029 → 110,055 rows; 2026 gross
revenue $1,354,347.63 → $1,358,427.00, net $1,344,139.21 → $1,348,218.58. The +26 orders are 13 WooCommerce
`processing` orders dated 2026-06-16..18 ($3,120.37) and 13 completed orders dated 2026-06-19 ($959.00)
that the archive-side date filter used to drop.

**Channel attribution (I11), 2026-07-01..2026-09-20, after the one full refresh (19.2 GiB):**

| channel | sessions before | sessions after | bridged orders before | bridged orders after |
|---|---:|---:|---:|---:|
| Paid Social | 111,136 | 111,704 | 1,262 | 1,286 |
| Direct | 20,313 | 83,762 | 9 | 1,462 |
| Organic Search | 21,957 | 22,082 | 905 | 918 |
| Referral | 23,125 | 21,748 | 562 | 409 |
| Organic Social | 17,653 | 17,915 | 373 | 375 |
| Email | 11,511 | 11,642 | 145 | 148 |
| Other | 63,406 | 248 | 1,343 | 1 |
| Paid Search | 1 | 1 | 0 | 0 |

1,444 of the 4,599 bridged orders sit on phantom sessions (almost all Stripe Checkout returns) that fall back
to Direct: a phantom session inherits the previous session's source only if that session started within 30
minutes, and only 10 of the window's 24,738 phantom sessions qualify (most start more than 30 minutes after the
user's previous session).

**Whole-project `dbt build`: `PASS=185 WARN=3 ERROR=0`** (warnings: `assert_webapp_orders_present`,
`assert_raw_cms_orders_fresh`, `assert_reconciliation_variance_recent`; see `docs/runbook.md`).
