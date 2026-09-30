# Handoff — what's left to take this pipeline live

## What is ALREADY live in BigQuery (observed 2026-09-27)

- **Read sources, real data, in use:** `analytics_313669961` (GA4 raw export, full history to the present)
  and `sipandscript_new_ds` (WooCommerce archive, 112,841 orders through 2026-06-19, read-only, nothing new
  arriving).
- **Datasets exist** (all US multi-region): `raw_cms`, `raw_spend` (empty on 2026-09-27); `raw_gsc`
  (Search Console, both properties): `page_query` backfilled for 2025-06-04 to 2026-09-24, and the three
  complete dimension sets `totals`, `page` and `device_country` backfilled for 2025-06-04 to 2026-09-25 (the www property has data from 2026-07-09) (see
  `docs/phase1-acceptance.md`); `raw_gsc.page_device_country` keeps its 2025-06-04 to 2026-09-24 backfill
  but is no longer loaded; `google_ads` (empty, transfer not authorised); `ops`, `staging`, `core`, `mart`.
  On 2026-09-27 `raw_stripe.balance_transactions` was observed to hold rows (about 65,000 to 75,000
  during that day). The Stripe history load is owned and run by the economic truth layer plan, requires the
  owner's approval, and is a full-history load; this pipeline plan did not run it. Confirm with that plan
  whether the load has completed before relying on Stripe-derived tables.
- **The whole dbt project builds green in development** (`dev_*` datasets; production has not been built
  with the economic truth layer, see item 3a) with five expected warnings, each explained in
  `docs/runbook.md` ("Expected warnings"): `assert_webapp_orders_present` and `assert_raw_cms_orders_fresh`
  (no CMS data yet), `assert_reconciliation_variance_recent` (Stripe rows with no CMS orders to compare),
  `assert_stripe_charges_carry_a_join_key` and `assert_identity_coverage` (fixed archive data).
- **`ops.load_state` / `ops.run_log` exist** and hold the history of this plan's development runs,
  including the Search Console backfills.
- **`brief/warehouse.py`** exists and is tested in this repo, but is **not wired into production** — the CMS
  repo's `ga_report.py` still reads GA4 directly (`BRIEF_SOURCE` unset). See `brief/README.md`.

## What is NOT live yet

- `infra/setup.sh` has not been run: no `sns-analytics@` service account, no IAM bindings from it, no
  `sns-analytics-drop` bucket, no Secret Manager placeholders, no Cloud Run jobs, no schedulers.
- The CMS export API (spec §6) is built and reviewed on a branch in the `sipandscript-sns.webapp.cms` repo
  but not deployed anywhere — the CMS loader cannot run at all yet.
- Stripe order matching and the economic truth layer exist on the branch and in development builds only;
  production has not been built with them — see items 3a and 9.
- The Google Ads BigQuery Data Transfer has not been authorised.
- Meta/Pinterest spend CSVs have never been dropped in the bucket (the bucket doesn't exist yet).
- The schedulers, the Looker Studio report, and the brief's `BRIEF_SOURCE=warehouse` switch all wait on the
  above.

## Raw writer payload bug (fixed)

`loaders/common/bq.py`'s `RawWriter.append()` double-JSON-encoded the `payload` column, which made raw rows
unreadable by staging (see `docs/runbook.md`). It was found by the first real load on 2026-09-27, fixed in
commit `1d4d1b4`, with the follow-up `64683cc` (non-finite floats become JSON null), and is guarded by
`dbt/tests/staging/assert_raw_payloads_are_objects.sql`. No raw rows with the bug were kept. Nothing further
to do; noted because it would otherwise have broken the CMS backfill (item 8) and the Stripe load (item 9).

## Ordered checklist

1. **Push the CMS export API branch and open its MR.**
   Who: CMS repo owner/developer. What: `git push origin feat/analytics-export-api` in the
   `sipandscript-sns.webapp.cms` checkout, then open a merge request against that repo's default branch.
   Verify: MR exists and CI runs on it. Unblocks: code review and eventual merge/deploy.

2. **Deploy to dev1; set the export API key; run the smoke checks.**
   Who: CMS repo owner, with deploy access to dev1. What: after merge, deploy to dev1; set
   `Analytics__ExportApiKey` in Doppler to at least 32 random bytes (e.g. `openssl rand -hex 32`); run
   `scripts/analytics-export-smoke.sh` (in the CMS repo) against dev1; then manually check: (a) a keyset
   walk with a small `pageSize` (e.g. 25) returns the same total row count as `SELECT COUNT(*)` on the
   underlying table; (b) a `nextCursor` obtained before an app restart still resumes correctly after it;
   (c) event `startAtUtc`/`endAtUtc` match the public site's displayed times for a sample of events,
   including a non-Eastern venue; (d) `venues.latitude`/`longitude` are present on a sample of venues;
   (e) no/garbage token returns 401, and an unset config key returns 404. Verify: all five pass; smoke
   script exits 0. Unblocks: confidence the export contract (spec §6) matches the real deployment.

3. **Production deploy of the CMS change.**
   Who: CMS repo owner. What: the repo's standard production deploy once dev1 checks pass and the MR is
   merged. Verify: `GET /api/export/events?pageSize=1` against production with a valid token returns 200
   with a well-formed envelope (`entity`, `generatedAt`, `items`, `nextCursor`). Unblocks: the CMS loader.

3a. **First production build of the economic truth layer.**
   Who: the repository owner, or someone with the owner's go-ahead for every step that writes to
   production. What: follow `docs/runbook.md`, "First production build of the economic truth layer", in its
   order. The steps before item 4 run under the identity of whoever runs them (the `prod` dbt profile uses
   oauth, that person's own credentials); the pipeline's service account does not exist until item 4 creates
   it. Merge; verify the prerequisites as yourself (dataset-scoped `INFORMATION_SCHEMA.COLUMNS` readable in
   `staging`, `core`, `mart`, `ops`; Stripe watermarks for all four entities in `ops.load_state`; no `@` in
   any `raw_stripe` payload; whether production `core_sessions` still has the old `pre_launch` column, which
   is expected but not checked, with the read-only `dbt show --target prod --inline` query over
   `core.INFORMATION_SCHEMA.COLUMNS` given in the runbook); if it does, `dbt run --target prod --select
   core_sessions --full-refresh` (expected about 10 GiB: a development full refresh processed 10.3 GiB on
   2026-09-27; bytes billed not measured), since a plain build errors on that column; `dbt build --target
   prod`; refresh the Looker Studio data source fields; then items 4 and 11 (deploy the jobs with the
   schedulers paused; execute the daily job once by hand and confirm `assert_no_pii_columns` and
   `assert_no_pre_launch_column` pass, which re-checks the service account's read access to the
   dataset-scoped `INFORMATION_SCHEMA.COLUMNS`, before unpausing anything; unpause daily first and check a
   run, unpause hourly last after measuring one hourly run's billed bytes). Verify: `dbt build --target
   prod` shows only the runbook's expected warnings. Unblocks: production tables that match this
   repository.

4. **Run `infra/setup.sh` in Cloud Shell.**
   Who: a human with `gcloud`/`bq` access and IAM admin on `sipandscript` (the dev laptop's `gcloud` and
   `bq` are broken). What: `bash infra/setup.sh` (idempotent, safe to re-run). It creates the service
   account and its IAM bindings (Secret Manager access is granted per secret on `stripe-restricted-key`,
   `cms-export-token` and `slack-ads-sync-bot-token`, never project-wide), the bucket, the two secret
   placeholders, the Google Ads transfer, **two Cloud Run jobs** — `sns-analytics-daily` (`MODE=daily`,
   `SOURCES=cms,stripe,gsc,spend`) and `sns-analytics-hourly` (`MODE=hourly`), same image, `--max-retries 0` — and
   two schedulers created PAUSED (daily `0 11 * * *`, hourly `30 0-10,12-23 * * *` UTC, empty request body).
   If an older version of the script ever created a single job named `sns-analytics`, delete it
   (`gcloud run jobs delete sns-analytics --region us-east1`). Verify: the script exits 0 and both jobs are
   listed by `gcloud run jobs list --region us-east1`. Unblocks: items 5-7 and 11.

5. **Give every secret an enabled version.**
   Who: same human, Cloud Shell. What:
   `printf '%s' "$STRIPE_KEY" | gcloud secrets versions add stripe-restricted-key --data-file=-` and the same
   for `cms-export-token` (value = the `Analytics__ExportApiKey` from item 2/3). `slack-ads-sync-bot-token`
   already exists (the ads-sync bot's). **A secret with no enabled version prevents both jobs from
   starting at all**, so all three must have one before item 11, even if the Stripe key is not used yet.
   Verify: `gcloud secrets versions list <name>` shows an `ENABLED` version for all three. Unblocks: item 11.

6. **Authorise the Google Ads transfer and backfill; then flip `google_ads_enabled`.**
   Who: a human with read access to Google Ads customer `1863952460`. What: BigQuery console → Data
   transfers → `sns-google-ads` → authorise → trigger a 90-day backfill. Before flipping the var, compare the
   column names the models use with `google_ads.INFORMATION_SCHEMA.COLUMNS` and check both var states
   compile (`docs/runbook.md`, "dbt vars"). Then set `vars.google_ads_enabled: true` in
   `dbt/dbt_project.yml` and run `dbt build`. Verify: `assert_google_spend_matches_source` passes and
   `mart.mart_paid_performance` shows `platform = 'google'` rows. Unblocks: spec §11 criterion 4.

7. **Add the pipeline service account to both Search Console properties.**
   Who: a Search Console owner on `https://sipandscript.com/` and `https://www.sipandscript.com/`. What:
   Settings → Users and permissions → Add user → `sns-analytics@sipandscript.iam.gserviceaccount.com` →
   Restricted. The historical backfills are done (run with the operator's own credentials on 2026-09-27:
   `page_query` 2025-06-04 to 2026-09-24; `totals`, `page`, `device_country` 2025-06-04 to 2026-09-25); this grant is
   needed for the job's own daily loads. Verify: the SA appears in both properties' user lists.

8. **First CMS backfill.**
   Who: whoever ran items 1-3. What: `python -m loaders run --sources cms --full`, then
   `cd dbt && dbt build`. Verify: `assert_webapp_orders_present` and `assert_raw_cms_orders_fresh` no
   longer warn; check the two pinned-fact tests, which are warn-severity until confirmed: roughly 5,328
   orders (±1%, 5,275-5,381) and **$474.1k gross ticket revenue (amount charged)** (±1%,
   $469,359-$478,841) for `business_date between '2026-06-23' and '2026-09-17'`. Once both match, raise
   them to error by deleting the `config(severity='warn')` line in
   `dbt/tests/core/assert_post_launch_orders_pinned.sql` and
   `dbt/tests/core/assert_post_launch_ticket_revenue_pinned.sql`. The accepted_values tests on CMS order,
   ticket and refund statuses and order source are error-severity: a value the CMS code does not produce
   today stops the build (add it to `dbt/models/staging/schema.yml` and to the literals in
   `core_orders.sql` / `core_events.sql` if it should count). Unblocks: real new-site orders throughout
   `core`/`mart`; the brief's precondition 1.

9. **The Stripe load.**
   Owned by the **economic truth layer plan**, not this one; it requires the repository owner's explicit
   approval. On 2026-09-27 `raw_stripe.balance_transactions` was observed to hold rows (about 65,000 to
   75,000 during that day). The Stripe history load is owned and run by the economic truth layer plan,
   requires the owner's approval, and is a full-history load; this pipeline plan did not run it. Confirm
   with that plan whether the load has completed before relying on Stripe-derived tables. A full Stripe
   load pages the **whole account history**, not only since 2026-06-19. The sanitiser that strips personal
   data from Stripe payloads is merged (commit `4d21fe5`). **Order matching for Stripe rows is delivered by
   that plan** in `core_stripe_transactions`; production tables get it with the first production build
   (item 3a). The Stripe history is now loaded and its
   watermark set, so `infra/setup.sh` and `jobs/entrypoint.sh` default the daily job to
   `SOURCES=cms,stripe,gsc,spend`, which loads Stripe incrementally. If the watermark is ever missing, the
   Stripe steps fail (`no Stripe watermark for <entity>: run once with --full to load history`) instead of
   reloading the history; the history load is a deliberate one-off `python -m loaders run --sources stripe --full`. No daily job is
   deployed yet (`infra/setup.sh` has never been run), so the job item 4 creates starts with
   `SOURCES=cms,stripe,gsc,spend`.
   Verify (once that plan reports done): `mart.mart_orders_reconciliation` has recent rows with
   `variance_pct` populated. Unblocks: spec §11 criteria 1 and 2; the brief's precondition 2.

10. **Drop Meta and Pinterest spend CSVs in the bucket.**
    Who: whoever manages the Ads Manager exports. What: export the standard daily-by-campaign CSV and upload
    to `gs://sns-analytics-drop/spend/meta/*.csv` and `gs://sns-analytics-drop/spend/pinterest/*.csv`.
    Required columns after header normalisation: `date, campaign_name, spend, impressions, clicks` (see
    `HEADER_MAP` in `loaders/spend_csv.py`). Dates may be `YYYY-MM-DD`, `M/D/YYYY`, `MM/DD/YYYY` or
    `YYYY/MM/DD`; numbers must use US format (a decimal comma or an accounting negative such as `(12.00)`
    rejects the whole file); summary rows with no campaign name are skipped. Verify:
    `python -m loaders run --sources spend` shows `spend.list.meta` / `spend.list.pinterest` ok and non-zero
    rows for each file in `ops.run_log`. Unblocks: Meta/Pinterest rows in `core_ad_spend` and
    `mart_paid_performance`.

11. **One manual execution of each job, then resume both schedulers.**
    Who: the human from item 4, Cloud Shell, after item 5 (the other items can be in any state — the jobs
    tolerate a failing source). What: `gcloud run jobs execute sns-analytics-daily --region us-east1 --wait`
    and confirm exit 0 and the Slack line `sns-analytics daily OK — …` followed by `dbt N models, M tests`
    (investigate `PROBLEMS` via `ops.run_log` first); then
    `gcloud run jobs execute sns-analytics-hourly --region us-east1 --wait` (an OK hourly run prints and
    does not post to Slack). Resume the daily scheduler first
    (`gcloud scheduler jobs resume sns-analytics-daily --location us-east1`) and check one scheduled daily
    run. Resume the hourly scheduler last
    (`gcloud scheduler jobs resume sns-analytics-hourly --location us-east1`), only after measuring one
    hourly run's billed bytes (`docs/runbook.md`, "Cost"). Verify: hourly and daily runs land in
    `ops.run_log` (steps `dbt.hourly` / `dbt.daily` with `status = 'ok'`). Unblocks: unattended
    operation.

12. **Create the Looker Studio report.**
    Who: anyone with BigQuery Data Viewer on `mart`/`core`. What: follow `docs/looker-studio.md`. Verify:
    both data sources connect and both pages render (the Paid page stays empty until items 6/10 land).

13. **Switch the brief to the warehouse.**
    Who: whoever deploys the `sns-ads-sync` Cloud Run job (now built from this repo's `brief/`, see
    `brief/deploy.sh`). What: first satisfy `brief/README.md`'s "Before switching `BRIEF_SOURCE` to `warehouse`"
    checklist (new-site orders flowing — item 8; a real day's orders/revenue compared with the Stripe dashboard —
    item 9; the daily job finishing before the brief's schedule); then run `BRIEF_SOURCE=warehouse brief/deploy.sh`.
    Verify: the morning brief's orders/revenue match the Stripe dashboard for a real recent day.
