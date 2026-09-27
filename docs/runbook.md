# Runbook

Operational reference for the sns-analytics loaders and dbt project. For the design rationale see
`docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md`. For what a human still has to do
before this pipeline is live, see `docs/handoff.md`.

## Raw writer payload fix (2026-09-27)

The first real load into any raw table (this pipeline's Search Console short-validation load, on
2026-09-27) surfaced a bug in `RawWriter.append()` (`loaders/common/bq.py`): it double-JSON-encoded the
`payload` column, so BigQuery stored it as a JSON scalar **string** rather than a JSON **object**, and
every `json_value(payload, '$.field')` read in every staging model returned `NULL`. It was fixed the
same day in commit `1d4d1b4` (`fix(loaders): store raw payloads as JSON objects, not strings`), which
round-trips the payload through `json.loads(json.dumps(payload, default=str))` before handing it to
BigQuery, verified with a real BigQuery round trip (`json_type(payload) = 'object'`, fields readable via
`json_value`) and a dbt regression guard
(`dbt/tests/staging/assert_raw_payloads_are_objects.sql`, checks the last 3 days of every raw table).
No raw rows were ever loaded with the bug present — `raw_cms`, `raw_stripe`, `raw_gsc` and `raw_spend`
were all confirmed empty immediately before the fix, and the one short-validation load written with the
bug was rolled back before the fix landed. See `docs/phase1-acceptance.md`'s 2026-09-27 section for the
full timeline and the Search Console backfill this fix unblocked.

## Running a loader locally

```bash
cd /Users/stephenchaloner/sns-analytics && . .venv/bin/activate
export CMS_BASE_URL=https://www.sipandscript.com CMS_EXPORT_TOKEN=... STRIPE_RESTRICTED_KEY=...
python -m loaders run --sources cms,stripe,gsc,spend [--full] [--mode daily|hourly]
```

- `--sources` (default `cms,stripe,gsc,spend`) takes a comma list; run one source at a time with e.g.
  `python -m loaders run --sources gsc`.
- `--full` ignores the watermark for every selected source and reloads from each source's full
  history (CMS: everything; Stripe: from 2026-06-19; Search Console: 480 days back; spend: every
  object in the bucket, since spend has no time-window concept — it tracks object generation instead).
- `--mode {daily,hourly}` only affects the CMS loader: `daily` reloads CMS dimension entities
  (`events`, `venues`, `metros`, `instructors`) in full every time and facts incrementally; `hourly`
  reloads everything (dims included) incrementally. Stripe, Search Console and spend ignore `--mode`.
- `CMS_BASE_URL` is always required (`Settings.from_env` raises `ValueError` without it). Only set
  `CMS_EXPORT_TOKEN` / `STRIPE_RESTRICTED_KEY` / `SLACK_BOT_TOKEN` when you actually intend to run that
  source; the loader for a source whose token/key is unset fails that source's steps with `RuntimeError`
  (logged to `ops.run_log`, other sources still run) rather than crashing the whole process.
- Local runs use your own Application Default Credentials (`gcloud auth application-default login`),
  the same project (`sipandscript`) the Cloud Run job uses.

## Running in the job

Cloud Run job `sns-analytics` (region `us-east1`) runs `jobs/entrypoint.sh`, built from the root
`Dockerfile`. `MODE=daily` (default) runs `python -m loaders run --mode daily` (all four sources) then
`dbt build --target prod`; `MODE=hourly` runs `python -m loaders run --sources cms --mode hourly` then
`dbt build --select tag:hourly --target prod` (the `hourly` tag currently covers `core_sessions`,
`core_session_orders`, and anything tagged `hourly` downstream — check `{{ config(tags=[...]) }}` in a
model to see if it's covered). The entrypoint never lets a loader failure abort the run — `dbt build`
still runs on whatever loaded — and always posts one line to Slack `#analytics`
(`sns-analytics <mode> OK — loaders rc=0, dbt rc=0` or `PROBLEMS` with the per-source row-count summary
attached). One-off manual execution: `gcloud run jobs execute sns-analytics --region us-east1 --wait`
(Cloud Shell only; `gcloud` is broken on the dev laptop).

## Reading failures

```sql
select * from ops.run_log where status = 'error' order by logged_at desc limit 20
```

One row per loader entity per run (`run_id, logged_at, step, status, row_count, message`); `step` is
`<source>.<entity>` (e.g. `cms.orders`, `stripe.refunds`, `gsc.page_query.www`, `spend.meta`) or a dbt
invocation. `message` holds the exception type, text, and the last ~1500 characters of the traceback.
A `run_id` is `local-<UTC timestamp>` for a laptop run or the Cloud Run execution id in the job.

## Watermarks: inspecting, resetting, and what a reset causes

`ops.load_state` holds one row per `(source, entity)`: `watermark` (a `TIMESTAMP`), an optional
`cursor`, and `updated_at` (when the row was last written). A loader step reads its watermark, fetches
from `watermark − overlap`, appends, and only advances the watermark after the append succeeds — so an
interrupted run resumes near where it left off on the next incremental (`--full`-less) invocation.

The `entity` value differs by source (this determines the exact `delete` you need):

| Source | `entity` values | Example |
|---|---|---|
| `cms` | the CMS entity name, no prefix | `orders`, `order_items`, `tickets`, `refunds`, `promo_redemptions`, `gift_cards`, `gift_card_transactions`, `checkout_sessions`, `events`, `venues`, `metros`, `instructors` |
| `stripe` | the Stripe entity name, no prefix | `balance_transactions`, `refunds`, `disputes`, `payouts` |
| `gsc` | the full step name (source prefix included) | `gsc.page_query.www`, `gsc.page_query.apex`, `gsc.page_device_country.www`, `gsc.page_device_country.apex` |
| `spend` | not applicable — spend tracks per-object generation, not a watermark; see `loaders/spend_csv.py` | — |

```sql
-- inspect
select * from ops.load_state where source = 'gsc';

-- reset one entity (forces the next incremental run for just that entity back to a full backfill window)
delete from ops.load_state where source = 'gsc' and entity = 'gsc.page_query.www';

-- reset an entire source
delete from ops.load_state where source = 'cms';
```

**What a reset causes:** with no watermark row, the next `python -m loaders run --sources <source>`
(without `--full`) behaves as if it were a full backfill for that entity only — CMS/Stripe fetch from
the beginning of that source's designated history, Search Console backfills the full 480 days for that
one property/dimension-set step. This re-fetches and re-appends rows already loaded; that's safe (the
raw contract is append-only and staging views dedupe to the latest row per `key`), but it costs API
calls/quota and load time, and duplicates raw storage (harmless but not free). Never delete a
`load_state` row to "fix" a bad run without first checking `ops.run_log` for what actually went wrong —
most failures don't need a watermark reset at all.

## Rebuilding a model and its children

```bash
cd dbt && export DBT_PROFILES_DIR=$(pwd)
../.venv/bin/dbt build --select core_orders+
```

`--select <model>+` rebuilds the named model and everything downstream of it (staging → core → mart).
To rebuild only what feeds one raw entity's staging view and its descendants, select the staging model,
e.g. `dbt build --select stg_gsc__page_query+` (rebuilds `core_search_daily`, the only model that reads
`stg_gsc__page_query`). A plain `dbt build` with no `--select` rebuilds and tests everything.

## `--full-refresh` of `core_sessions` / `core_session_orders`

Both are `materialized='incremental'` (`core_sessions`: `insert_overwrite`, partitioned by
`session_date`; `core_session_orders`: `merge` on `order_key`) with a 3-day lookback (see below). A
normal incremental run only scans the last few days of GA4 `_table_suffix` partitions. A
`--full-refresh` drops and rebuilds from `var('ga4_start_date')` (`2025-01-01` today) instead —
**about 10 GiB scanned each**, i.e. roughly 20 GiB together, versus a few hundred MB for a normal
incremental run. Only do this when you've changed the model's logic in a way that must be re-applied
to historical rows (a correction fix, widening `ga4_start_date`, etc.) — not routinely, and not as part
of this task (ruling forbids it here). `dbt build --full-refresh --select core_sessions+` is the
command; expect it to dominate that day's BigQuery bytes-scanned budget.

## dbt vars

- **`google_ads_enabled`** (`dbt/dbt_project.yml`, default `false`): while false, every reference to
  the `google_ads` source in `core_ad_spend.sql` and `mart_paid_performance.sql` is replaced by a typed
  empty `select` (same columns/types, zero rows), so the project builds without the `google_ads`
  dataset having any tables. Flip to `true` only after the BigQuery Data Transfer Service Google Ads
  connector has been authorised and has produced at least one row in `google_ads.campaign_stats` /
  `campaign` / `click_stats` (see `docs/handoff.md` item 6) — flipping it before that just makes the
  `{{ source(...) }}` references fail to compile against an empty dataset with no tables.
- **`ga4_start_date`** (default `2025-01-01`): the floor date for `core_sessions`'s and
  `core_session_orders`'s non-incremental (first build / `--full-refresh`) scan of the GA4 export.
  Widen it (e.g. to the export's actual start) only if you need deeper session history and are prepared
  to pay for the corresponding `--full-refresh` scan.
- **`launch_date`** (`2026-06-19`): the WooCommerce → webapp cutover date used to derive `pre_launch`
  on orders and sessions, and the start date for `mart_orders_reconciliation`. Not expected to change.
- **`ads_customer_id`** (`1863952460`): the Google Ads customer id used to build the `google_ads`
  source table identifiers (`ads_CampaignBasicStats_<id>`, etc.).

## Secret rotation

Secrets live in Secret Manager: `stripe-restricted-key`, `cms-export-token`, and the reused
`slack-ads-sync-bot-token`. To rotate a value, add a new version — the job always reads `:latest` (see
`infra/setup.sh`'s `--set-secrets ...:latest`), so **no redeploy is needed**:

```bash
printf '%s' "$NEW_VALUE" | gcloud secrets versions add stripe-restricted-key --data-file=-
```

(Same command with `cms-export-token`.) The next scheduled or manual job execution picks up the new
version automatically. Do this from Cloud Shell (`gcloud` is broken on the dev laptop).

## GA4 lateness: the 3-day lookback

`core_sessions` and `core_session_orders` are both incremental with a 3-day lookback: each incremental
run re-scans the last `lookback + 1` (`core_sessions`) or `3` (`core_session_orders`) days of GA4
`_table_suffix` partitions, but only emits/merges rows for the last `lookback`/`3` days, and for
`core_sessions` a session already stored in an out-of-window partition is never re-emitted (dedup via a
left join against `{{ this }}`; see the model's own comments for the exact edge case that motivated the
extra day of read). This absorbs GA4's own lateness — daily export tables sometimes land a day or more
after the fact, and a stray very-late hit on an old session (observed in practice, see the model
comment dated 2026-09-27) doesn't get double-counted in a new partition. It does **not** protect against
lateness beyond the lookback window — if the GA4 export is delayed more than 3 days, run
`dbt build --select core_sessions+ --full-refresh` (see above; ~10 GiB) once the export catches up.

## Expected warnings

A `dbt build`/`dbt test` run is expected to show these `WARN`s (not errors) until their preconditions
are met — treat a *new* error-severity failure as a real problem, but these three are known and inert
until real data lands:

| Test | Fires while... | Clears when... |
|---|---|---|
| `assert_webapp_orders_present` (`dbt/tests/core/assert_webapp_orders_present.sql`) | `raw_cms` is empty — zero `source_system = 'webapp'` rows in `core.core_orders` | The first CMS backfill loads real webapp orders |
| `assert_reconciliation_variance_recent` (`dbt/tests/marts/assert_reconciliation_variance_recent.sql`) | `mart.mart_orders_reconciliation` has zero rows in the last 30 days (no CMS orders and/or no Stripe rows to compare) | Both CMS orders and Stripe transactions are flowing for recent days |
| `core_tickets.event_key` relationships test (warn severity, `dbt/models/core/schema.yml`) | Any ticket's `event_key` doesn't resolve to a row in `core.core_events` (e.g. legacy WooCommerce tickets whose event never mapped via `wordpress_source_id`) | Not expected to fully clear — it's a soft integrity check on old-data mapping gaps, kept at warn deliberately |

## Cost expectations and checking bytes scanned

Spec §10 targets "a few GB scanned per day; well under $5/month." Observed while rebuilding the whole
project on 2026-09-27 (all raw tables empty except the pre-existing GA4 export and WooCommerce
archive): `core.core_orders` processed 16.3 MiB, `mart.mart_daily_kpis` processed 133.5 MiB,
`mart.mart_paid_performance` processed 179.5 MiB (`core_sessions`/`session_orders` full scans dominate
this — they're incremental so a normal day only rescans a few days, not their whole history) — call it
a few hundred MB for a routine incremental `dbt build` today, before any of the new raw sources have
real volume. To check what a run actually cost:

```sql
-- BigQuery job history: bytes billed per job in the last day
select creation_time, query, total_bytes_billed, total_bytes_processed
from `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
where creation_time > timestamp_sub(current_timestamp(), interval 1 day)
order by total_bytes_billed desc limit 20;
```

Or watch dbt's own per-model line during a build (`OK created ... (N rows, X MiB processed)`), as shown
above. On-demand BigQuery pricing is per TiB scanned; at a few hundred MB to low GB per day this stays
far under the $5/month target. A `--full-refresh` of `core_sessions`/`core_session_orders` (~10 GiB
each, see above) is the one operation likely to show up as a real cost line — do it deliberately, not
as part of routine operation.
