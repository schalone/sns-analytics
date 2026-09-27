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

**Fix.** `RawWriter.append()` (`loaders/common/bq.py`) now round-trips the payload through
`json.loads(json.dumps(payload, default=str))` before handing it to BigQuery, so a JSON-typed column
receives a JSON object rather than a pre-serialised string. Landed in commit `1d4d1b4`. A follow-up
fix in commit `64683cc` additionally guards against non-finite floats (`NaN`/`Infinity`/`-Infinity`),
which `json.dumps(..., default=str)` does not route through `default` and would otherwise make
BigQuery reject an entire load batch over one bad numeric field; those now become JSON `null` via
`parse_constant`. Verified with a real BigQuery round trip (`json_type(payload) = 'object'`, fields
readable via `json_value`) and guarded going forward by
`dbt/tests/staging/assert_raw_payloads_are_objects.sql` (checked against the real, full-scale
backfill below: passes).

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

This total was computed two independent ways — from `core.core_search_daily` (built on the
`page_query` dimension set, which carries the `query` dimension) and directly from
`raw_gsc.page_device_country` (the `page_device_country` dimension set, which has no `query`
dimension and so cannot be affected by the API's query-level anonymisation/omission) — and both
methods agree **exactly** (5,097 clicks, 122,456 impressions, at the per-property level and at the
per-day level; zero missing days in the window on either side). This rules out query anonymisation as
the explanation for any gap in this particular measurement, since a page-level (no-query-dimension)
total would have been *higher* than a query-dimensioned total if rows were being omitted, and it
was not.

**This total (5,097) is well below the September investigation's reference figure of ~11,472 clicks
for the same window and properties** — about 44% of it. This session cannot fully explain the gap:
the loaded data has no missing days, both independently-collected dimension sets agree exactly with
each other at every level checked (day, property, and total), and the total across all loaded history
(48,920 clicks, 2,296,750 impressions, 2025-06-04..2026-09-24) is likewise internally consistent
between both dimension sets. The most likely single explanation this session can point to but not
confirm: the loader's API calls do not set a `type` parameter, which defaults to `web`-only per the
Search Console API, whereas a reference figure produced from the Search Console UI (or a script that
requested `type: "all"` or omitted the parameter differently) can include Image/Video/News search
types as well and would report a higher total. Other candidates not ruled out: a different property
definition used by the original investigation (e.g. a domain-level property vs. these two
URL-prefix properties), or a different date-range/timezone boundary. Whoever owns the loader should
treat this as an open question, not a confirmed defect in this backfill — the data loaded here is
internally consistent and complete for the two properties and `web` search type it was configured to
fetch.

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
`assert_webapp_orders_present` warning, plus a new `assert_reconciliation_variance_recent` warning
(30 results) — this is because `raw_stripe.balance_transactions` now holds 65,000 rows as of this
check (the economic truth layer plan's Stripe load, owned by a separate session, appears to be
in progress; this session did not run the Stripe loader). `raw_cms.orders` remains 0. Neither
warning is a defect in this task's work; both are expected/pre-existing conditions per
`docs/runbook.md`.
