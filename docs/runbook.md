# Runbook

Operational reference for the sns-analytics loaders and dbt project. For the design rationale see
`docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md`. For what a human still has to do
before this pipeline is live, see `docs/handoff.md`.

## Raw writer payload fix (2026-09-27)

The first real load into any raw table (this pipeline's Search Console short-validation load) surfaced a
bug in `RawWriter.append()` (`loaders/common/bq.py`): it double-JSON-encoded the `payload` column, so
BigQuery stored it as a JSON scalar **string** rather than a JSON **object**, and every
`json_value(payload, '$.field')` read in every staging model returned `NULL`. It was found by the first
real load on 2026-09-27, fixed in commit `1d4d1b4`, with the follow-up `64683cc` (non-finite floats become
JSON null).

How the payload is written now: every payload goes through `_json_safe()` in `loaders/common/bq.py`, which
serialises it with `json.dumps(payload, default=str)` (so `datetime`, `Decimal` and other non-JSON values
become their `str()` form) and parses it back with `json.loads(..., parse_constant=...)`, so the bare tokens
`NaN`, `Infinity` and `-Infinity` become `null` (a quoted string such as `"NaN"` is left alone). The
resulting plain object is what BigQuery's JSON column receives. Guarded by
`dbt/tests/staging/assert_raw_payloads_are_objects.sql`, which checks the last 3 days of every loaded raw
table. No raw rows were kept from before the fix: the one short-validation load written with the bug was
rolled back. See `docs/phase1-acceptance.md` for the timeline.

## Local development: never build production by accident

Every dbt command below writes to the production datasets (`staging`, `core`, `mart`, `ops`) unless you
set a schema prefix. For local development:

```bash
export DBT_SCHEMA_PREFIX=dev_<your name>     # e.g. dev_stephen
```

With it set, dbt writes `dev_<name>_staging`, `dev_<name>_core`, `dev_<name>_mart` and `dev_<name>_ops`
(seeds) instead (`dbt/macros/generate_schema_name.sql`). Sources are unaffected: a prefixed build still
reads the real raw datasets, the GA4 export and the WooCommerce archive. The first prefixed build creates
those datasets. Without the variable, a local `dbt build` overwrites production tables.

## Running a loader locally

```bash
cd /Users/stephenchaloner/sns-analytics && . .venv/bin/activate
export CMS_BASE_URL=https://www.sipandscript.com CMS_EXPORT_TOKEN=...
python -m loaders run --sources cms,stripe,gsc,spend [--full] [--mode daily|hourly]
```

- `--sources` takes a comma list; the CLI's own default is all four (`cms,stripe,gsc,spend`), so name
  the sources explicitly. `stripe` without `--full` loads incrementally from its watermark. If a Stripe
  entity has **no** watermark, its step fails with `no Stripe watermark for <entity>: run once with --full
  to load history` and Stripe is not called; it never reloads the history by itself. The history load is
  a deliberate one-off: `python -m loaders run --sources stripe --full` (see below for what that pages).
- `--full` ignores the watermark for every selected source and reloads its full history: CMS
  everything; **Stripe pages the whole account history** (every balance transaction, refund, dispute and
  payout since the account opened, not only since the 2026-06-19 launch); Search Console 480 days back;
  spend every object in the bucket (spend tracks object generation, not a time window).
- `--mode {daily,hourly}` only affects the CMS loader: `daily` reloads CMS dimension entities
  (`events`, `venues`, `metros`, `instructors`) in full every time and facts incrementally; `hourly`
  reloads everything incrementally. Stripe, Search Console and spend ignore `--mode`.
- `CMS_BASE_URL` is always required (`Settings.from_env` raises `ValueError` without it). A source whose
  token or key is unset fails its own steps (logged to `ops.run_log`); the other sources still run.
- Local runs use your own Application Default Credentials (`gcloud auth application-default login`)
  against project `sipandscript`.

## Running in the jobs

Two Cloud Run jobs (region `us-east1`) run the same image (root `Dockerfile`, entrypoint
`jobs/entrypoint.sh`), each with its mode fixed in its own environment. Schedulers call them with an empty
body, so nothing can override the mode, and both jobs have `--max-retries 0` so a failed run is never
retried into the next one.

| Job | Schedule (UTC) | Loaders | dbt |
|---|---|---|---|
| `sns-analytics-daily` (`MODE=daily`) | `0 11 * * *` | `python -m loaders run --sources "$SOURCES" --mode daily`; `SOURCES` defaults to `cms,stripe,gsc,spend` and is set explicitly on the job by `infra/setup.sh` | `dbt build --target prod` (the whole project) |
| `sns-analytics-hourly` (`MODE=hourly`) | `30 0-10,12-23 * * *` (skips 11:30, the hour of the daily build, which is a superset) | `python -m loaders run --sources cms --mode hourly` | `dbt build --selector hourly --target prod` |

`stripe` is in the daily job's `SOURCES`: each daily run loads Stripe incrementally from its watermark. If
the watermark is missing (a fresh project, or a reset of `ops.load_state`), the Stripe steps fail loudly
(`no Stripe watermark for <entity>: run once with --full to load history`) rather than reload the whole
account history; load the history once, deliberately, with `python -m loaders run --sources stripe --full`. **The deployed job still has the old value
(`cms,gsc,spend`)** until someone re-runs `infra/setup.sh` or updates the job directly:

```bash
gcloud run jobs update sns-analytics-daily --region us-east1 --update-env-vars '^;^SOURCES=cms,stripe,gsc,spend'
```

Until then the daily job does not load Stripe, and fees, refunds and identity for new orders go stale.

**The hourly selector** (`dbt/selectors.yml`) is every model tagged `hourly` together with all its
ancestors, minus every model tagged `ga4` and the GA4 source. Hourly-tagged models: `core_orders`,
`core_tickets`, `core_order_items`, `core_refunds`, `core_events`, `core_venues`, `core_metros`,
`core_instructors`, `mart_daily_kpis`, `mart_orders_reconciliation`, `mart_event_performance`. Tagging
`mart_event_performance` hourly pulls its whole ancestry in too, confirmed with
`dbt ls --selector hourly --resource-type model` (2026-09-27): `core_customer_identity`,
`core_stripe_transactions`, `core_order_item_economics`, `core_bookings`, `core_event_daily`,
`core_event_economics`, `core_ad_spend`, `core_ad_spend_allocation`, `ops_unallocated_ad_spend`, every CMS
and WooCommerce staging view, `stg_stripe__balance_transactions`, `stg_spend__csv`, and both seeds
(`date_flags`, `campaign_metro_map`) -- the booking-curve and ad-spend-allocation chain that used to build
only in the daily run. Every test on them runs too. `core_sessions` and `core_session_orders` are tagged
`ga4` and build in the daily run only (the GA4 daily table lands once a day); the hourly `mart_daily_kpis`
reads the existing `core_sessions` table. List the exact nodes with `dbt ls --selector hourly`.

**Status message.** Each run ends with one status step: one Slack line to `#analytics`
(`sns-analytics <mode> OK|PROBLEMS — loaders rc=…, dbt rc=…, run <id>`), then `dbt N models, M tests`
(plus warnings, skips and up to 10 failing node names, read from `dbt/target/run_results.json` by
`loaders/common/dbt_results.py`), then the per-source loader summary. Daily runs always post; **hourly
runs post only when a loader or dbt failed** and otherwise just print. The same step writes one
`ops.run_log` row for the dbt invocation: `step = 'dbt.daily'` or `'dbt.hourly'`, `status` ok/error,
`row_count` = number of dbt nodes, `message` = the failing node names.

**Secrets.** The jobs mount `stripe-restricted-key`, `cms-export-token` and `slack-ads-sync-bot-token` as
`:latest`. If any of the three has no ENABLED version, Cloud Run cannot start the job at all (no loader
runs, no Slack line): add a version before the first execution (handoff item 5).

One-off manual execution (Cloud Shell only; `gcloud` is broken on the dev laptop):
`gcloud run jobs execute sns-analytics-daily --region us-east1 --wait` (or `sns-analytics-hourly`).

## Reading failures

```sql
select * from ops.run_log where status = 'error' order by logged_at desc limit 20
```

One row per loader step per run (`run_id, logged_at, step, status, row_count, message`). `step` is
`<source>.<entity>` (e.g. `cms.orders`, `stripe.refunds`), `gsc.<set>.<apex|www>` for Search Console,
`spend.list.<meta|pinterest>` for a spend bucket listing and `spend.<object name>` for one CSV, or
`dbt.daily` / `dbt.hourly` for the dbt invocation. `message` holds the exception type, text and the last
~1500 characters of the traceback; an ok step may also carry a note (e.g. a spend file's skipped summary
rows). A `run_id` is `local-<UTC timestamp>` for a laptop run or the Cloud Run execution id in a job.

A spend CSV is rejected as a whole (step status `error`, nothing written) when a row's date is not
`YYYY-MM-DD`, `M/D/YYYY`, `MM/DD/YYYY` or `YYYY/MM/DD`, or a number uses a decimal comma (`12,5`,
`1.234,56`) or an accounting negative (`(12.00)`); the message names the file, the CSV row and the value.
Re-export the file in US number format and upload it again (a new object generation is loaded).

## Watermarks: inspecting, resetting, and what a reset causes

`ops.load_state` holds one row per `(source, entity)`: `watermark` (a `TIMESTAMP`), an optional
`cursor`, and `updated_at`. A loader step reads its watermark, fetches from `watermark − overlap`, appends,
and advances the watermark only after the append succeeds. Search Console advances it after **every** loaded
day, so an interrupted backfill resumes from its last complete day (minus the 3-day overlap).

| Source | `entity` values |
|---|---|
| `cms` | the CMS entity name: `orders`, `order_items`, `tickets`, `refunds`, `promo_redemptions`, `gift_cards`, `gift_card_transactions`, `checkout_sessions`, `events`, `venues`, `metros`, `instructors` |
| `stripe` | `balance_transactions`, `refunds`, `disputes`, `payouts` |
| `gsc` | the full step name: `gsc.totals.apex`, `gsc.page.apex`, `gsc.device_country.apex`, `gsc.page_query.apex`, and the same four with `.www` |
| `spend` | one row per CSV object name, with its generation in `cursor` |

(`gsc.page_device_country.*` rows remain from the retired dimension set; nothing reads them.)

```sql
select * from ops.load_state where source = 'gsc';                                   -- inspect
delete from ops.load_state where source = 'gsc' and entity = 'gsc.page.www';          -- reset one entity
```

**What a reset causes:** with no watermark row, the next incremental run of that source behaves as a full
backfill for that entity only. Stripe is the exception: with no watermark its incremental step fails
(`no Stripe watermark for <entity>: run once with --full to load history`) and fetches nothing, so after
resetting a Stripe entity run `python -m loaders run --sources stripe --full` deliberately (it pages the
whole account history for every Stripe entity). That re-fetches and re-appends rows
already loaded; staging dedupes to the latest row per `key`, but it costs API quota, load time and raw
storage. Check `ops.run_log` before deleting a watermark: most failures do not need a reset.

## Search Console: which table answers which question

The Search Console API drops anonymised and low-volume rows whenever `page` is combined with another
dimension and whenever `query` is requested. Measured for 2026-06-23..2026-09-13: the property totals are
11,306 clicks, but page × query rows add up to 5,097. So:

| Question | Table |
|---|---|
| Clicks / impressions / position for a property, a day, a trend | `core.core_search_totals_daily` (dimensions `[date]`, complete) |
| Which pages get search traffic | `core.core_search_page_daily` (`[date, page]`, complete per page) |
| Device or country split | `core.core_search_device_country_daily` (`[date, device, country]`, complete) |
| Which search terms bring people in | `core.core_search_daily` (`[date, page, query]`, **partial**: only non-anonymised queries; never sum it to a total) |

`raw_gsc.page_device_country` keeps its 2025-06-04..2026-09-24 backfill but is no longer loaded or
modelled (that combination lost more than half the clicks).

## Transferred seats (legacy)

The legacy site moved a seat to another class by creating a new order with a total of zero, one per seat,
whose parent is the original paid order. The instructor of the class attended earns the money, so the seat
and the money paid for it follow the transfer:

- `core_seat_transfers` lists every ticket line of a transfer order with its root (the original paid order,
  followed up through earlier transfers, at most five steps). Per root, the latest transfers hold seats up to
  the number the root bought; earlier ones whose seat moved on again are superseded.
- In `core_order_item_economics` and `core_bookings`, `booking_kind` says what a row is: `purchase`,
  `transfer_in` (the seat on the new class from the transfer date, carrying the root's per-seat realized
  revenue, refund and Stripe fee), `transfer_superseded` (no seat, no money), or `unpaid_zero_total` (a
  zero-total order with ticket value and no paid ancestor, kept at its line value with no fee). On the root's
  row, `seats_transferred_out` counts the seats that moved away and `seats` what stayed; its money is scaled
  down to match, so nothing is counted twice.
- In `core_orders`, `is_transfer` marks a transfer order with a root (`transfer_root_order_key`). It belongs
  to the root's customer (`identity_source = 'transfer_parent'`), is never a first order, and is left out of
  customer order counts.
- `mart_daily_kpis` order, ticket-order and seat counts, gross and net revenue and new customers exclude
  transfer orders; `net_distributable` and `sns_share` include the moved money on the transfer's own row.
- Tests: `assert_transfers_conserve_money` (per root, money is unchanged by transfers) and
  `assert_transfer_seats_within_purchase` (held plus remaining seats equal seats bought).

## Rebuilding a model and its children

```bash
cd dbt && export DBT_PROFILES_DIR=$(pwd)
../.venv/bin/dbt build --select core_orders+
```

`--select <model>+` rebuilds the model and everything downstream. A plain `dbt build` rebuilds and tests
everything. Set `DBT_SCHEMA_PREFIX` first unless you mean to write production.

## GA4 lateness, the lookback, and recovering from an outage

`core_sessions` (`insert_overwrite` by `session_date`) and `core_session_orders` (`merge` on `order_key`)
are incremental. An incremental run re-reads the last `ga4_lookback_days` days of GA4 daily tables (dbt var,
default 3; `core_sessions` reads one extra day so a session spanning midnight is aggregated whole) and emits
only rows inside that window; a session already stored in an older partition is never re-emitted. This
absorbs the GA4 export's normal lateness. `assert_core_sessions_fresh` warns when the newest session day is
more than 3 days old.

**After an outage longer than the lookback** (the daily job did not run, or the GA4 export stopped), once
the export has caught up, rebuild with a lookback that covers the gap, N = days since the last good day + 1:

```bash
dbt build --select core_sessions core_session_orders --vars '{ga4_lookback_days: N}'
```

This scans only the last N days of GA4 tables, a small fraction of a full refresh.

## `--full-refresh` of `core_sessions` / `core_session_orders`

A `--full-refresh` drops and rebuilds both from `var('ga4_start_date')` (`2025-01-01`): **19.2 GiB** scanned
together on 2026-09-27 (10.3 GiB `core_sessions`, 8.9 GiB `core_session_orders`). Do it only when a logic
change must be re-applied to history (it was done once on 2026-09-27 for the attribution fix):
`dbt build --select core_sessions core_session_orders --full-refresh`.

## dbt vars

- **`google_ads_enabled`** (default `false`): while false, every `google_ads` source reference in
  `core_ad_spend.sql`, `mart_paid_performance.sql` and `tests/core/assert_google_spend_matches_source.sql`
  is replaced by a typed empty select, so the project builds without the transfer tables. **Before flipping
  it**, a human must compare the column names these models use (`segments_date`, `campaign_id`,
  `metrics_cost_micros`, `metrics_impressions`, `metrics_clicks`, `campaign_name`, `_DATA_DATE`,
  `click_view_gclid`) with `select table_name, column_name from google_ads.INFORMATION_SCHEMA.COLUMNS`, and
  check that both states compile: `dbt compile` and `dbt compile --vars '{google_ads_enabled: true}'`. After
  flipping, `assert_google_spend_matches_source` checks Google spend per day against the transfer's own
  `sum(metrics_cost_micros) / 1e6` within one cent.
- **`ga4_lookback_days`** (default `3`): see the previous section.
- **`phantom_referral_sources`** (default `['accounts.google.com', 'checkout.stripe.com']`): sources that
  `core_sessions` treats as phantom referrals (a sign-in or payment round trip GA4 records as a new
  referral session); any source ending in `.stripe.com` is also phantom. A phantom session inherits the
  same user's previous non-phantom session when that started within 30 minutes, else becomes
  `(direct)` / `(none)`. Changing the list needs a `--full-refresh` of the two GA4 models to apply to
  history.
- **`ga4_start_date`** (default `2025-01-01`): the floor of a first build / full refresh of the GA4 models.
- **`launch_date`** (`2026-06-19`): the WooCommerce → webapp cutover; drives `platform_era` on sessions
  (by `session_date`) and on `mart_orders_reconciliation` (by `business_date`, whole history, both
  eras -- `flagged` can only be true on the bronco side of the boundary). Orders (and
  tickets/refunds/order items keyed to them) get `platform_era` from `source_system` instead
  (`woocommerce` -> `legacy_event_tickets`, else `bronco`), not from `launch_date` directly.
- **`ads_customer_id`** (`1863952460`): builds the `google_ads` table identifiers.

## Secret rotation

Secrets live in Secret Manager: `stripe-restricted-key`, `cms-export-token`, and the reused
`slack-ads-sync-bot-token`. The service account can read exactly these three (per-secret IAM bindings in
`infra/setup.sh`, no project-wide access). The jobs read `:latest`, so rotating needs no redeploy:

```bash
printf '%s' "$NEW_VALUE" | gcloud secrets versions add stripe-restricted-key --data-file=-
```

Do not disable the only enabled version of a secret: the jobs then cannot start. Cloud Shell only.

## Expected warnings

A green `dbt build` today shows exactly these warnings; any error, or any other warning, is a real problem.

| Test | Fires while | Clears when |
|---|---|---|
| `assert_webapp_orders_present` | `core_orders` has no `webapp` orders (`raw_cms` empty; CMS export API not deployed) | the first CMS backfill (handoff item 8) |
| `assert_raw_cms_orders_fresh` | nothing was loaded into `raw_cms.orders` in the last day (an empty table warns) | the CMS loader runs at least daily |
| `assert_reconciliation_variance_recent` | recent bronco days of `mart_orders_reconciliation` are flagged: Stripe already carries bronco-era charge activity but there are no bronco CMS orders yet, so `orders_charged_amount` is 0 against a real `stripe_charged_amount` | the first CMS backfill lands bronco orders (handoff item 8) |
| `assert_stripe_charges_carry_a_join_key` | 2016 falls under the 97% join-key threshold: 204 of that year's 242 charges (about 84%) carry no `checkout_session_key`/`order_number`/`woo_order_id`/`order_ref`/`adhoc_charge_key` at all; every year from 2017 on is at or above 99.7% | never on its own -- 2016 is fixed archive data, not a loading gap; would need a manual reconciliation of that year's Stripe export against the archive |
| `assert_identity_coverage` | two (year, era) buckets, both `legacy_event_tickets`, fall under the 98% resolved-identity bar: 2019 (96.55%) and 2020 (97.58%). The unresolved remainder has no Stripe charge to take a customer hash from (see `core_customer_identity`'s `stripe` priority). Transfer orders take their root order's customer, which cleared 2022-2025 | never on its own -- same fixed archive data as above |

Warn-severity tests that pass today but will warn if their condition appears: `assert_core_sessions_fresh`,
`assert_raw_gsc_fresh`, `assert_search_page_totals_match_property_totals`, the `core_tickets.event_key`
relationships test, and the two pinned-fact tests `assert_post_launch_orders_pinned` and
`assert_post_launch_ticket_revenue_pinned` (warn until the pinned figures are confirmed after the first
CMS backfill; then raise them to error by deleting their `config(severity='warn')` line).
`assert_worked_bronco_order_pinned` also passes today and will warn once any new-platform booking is
more than two days old: it asks for one bronco order to be checked by hand against Stripe
(`scripts/econ_check_order.py --bronco <order number>`) and pinned in `assert_worked_order.sql`, after which
the warning test is deleted (see `docs/econ-001-validation.md`).

## Cost

**Stale as of the `mart_event_performance` addition:** the hourly figure below was measured before
`mart_event_performance` was tagged `hourly`. Tagging it pulled `core_ad_spend`,
`core_ad_spend_allocation`, `core_bookings`, `core_event_daily`, `core_event_economics`,
`ops_unallocated_ad_spend` and `stg_spend__csv` into the hourly build (see "Running in the jobs" above) --
models that previously ran only once a day. This has not been re-measured. Do not rely on the
hourly row of the table, or the $4.75/month total, for budgeting until a real hourly run under the new
ancestor set has been measured with the query at the end of this section (summed with `sum(total_bytes_billed)`
over one hourly run's time window, or filtered to the job's service account, rather than listed row by row).

Spec §10 targets a few GB scanned per day and well under $5/month. Measured on 2026-09-27 from dbt's own
`run_results.json` (`adapter_response.bytes_processed` / `bytes_billed`, summed over every model and test):

| Build | Per run: processed / billed | Runs per day | Per day billed |
|---|---|---:|---:|
| Hourly (`--selector hourly`) -- **stale, see note above** | 0.45 GiB / 1.0 GiB | 23 | about 23 GiB |
| Daily (whole project, incremental GA4 models) | 1.9 GiB / 2.7 GiB | 1 | about 2.7 GiB |
| **Total** | | | **about 26 GiB/day, about 780 GiB/month** |

That is about $4.75/month at the on-demand list price of $6.25 per TiB billed, or $0 while the project stays
inside BigQuery's free first 1 TiB per month. Assumptions: billed bytes include BigQuery's 10 MiB minimum per table per query, which is why most of the
hourly run's billed bytes (about 110 small queries) exceed what it processes. `raw_cms` and `raw_spend` are
empty today; the CMS tables will add their own size to every hourly run once loaded (the order tables are
expected in the tens of MB). `core_sessions` (894 MiB, 2.4M rows) is read by the daily build's
`mart_daily_kpis` and `mart_paid_performance` and by the hourly `mart_daily_kpis`. The largest single
hourly node is `assert_raw_payloads_are_objects` (about 220 MiB billed), which scans the last 3 days of
every raw table and so grows with daily load volume. A `--full-refresh` of the two GA4 models (19.2 GiB)
is the only large one-off.

To check what runs actually cost:

```sql
select creation_time, total_bytes_billed, total_bytes_processed, left(query, 120) as query
from `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
where creation_time > timestamp_sub(current_timestamp(), interval 1 day)
order by total_bytes_billed desc limit 20;
```
