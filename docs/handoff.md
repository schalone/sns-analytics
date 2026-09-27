# Handoff — what's left to take this pipeline live

## What is ALREADY live in BigQuery today (2026-09-27)

- **Read sources, real data, in use today:** `analytics_313669961` (GA4 raw export, full history to
  the present) and `sipandscript_new_ds` (WooCommerce archive, 112,841 orders through 2026-06-19,
  read-only, nothing new arriving).
- **Datasets exist** (all US multi-region): `raw_cms`, `raw_spend` (empty, verified 2026-09-27);
  `raw_gsc` now holds a completed 480-day backfill (both properties, both dimension sets — see
  `docs/phase1-acceptance.md`); `raw_stripe.balance_transactions` holds real rows as of this writing
  (the economic truth layer plan's Stripe load, a separate session — not run by this task); `google_ads`
  (empty, transfer not authorised); `ops`, `staging`, `core`, `mart`.
- **The whole dbt project builds green**: every staging view, core table and mart exists.
  `core.core_search_daily` is now populated from the real Search Console backfill (820,947 rows). One
  expected `warn`-severity test, `assert_webapp_orders_present` (see `docs/runbook.md`), because no
  new-site orders exist yet. A second, `assert_reconciliation_variance_recent`, is currently also
  firing because Stripe rows are landing without CMS orders to reconcile against yet (see item 9) —
  expected while that plan's load is in progress, not a defect. A third,
  the `core_tickets.event_key` relationships test, is also documented in the runbook as a permanent
  soft check.
- **`ops.load_state` / `ops.run_log` exist** and hold a history of loader/dbt invocations from this
  plan's development, including this task's completed Search Console backfill (see
  `docs/phase1-acceptance.md`).
- **`brief/warehouse.py`** exists and is tested in this repo, but is **not wired into production** —
  the CMS repo's `ga_report.py` still reads GA4 directly (`BRIEF_SOURCE` unset). See `brief/README.md`.

## What is NOT live yet

- `infra/setup.sh` has not been run: no `sns-analytics@` service account, no IAM bindings from it, no
  `sns-analytics-drop` bucket, no Secret Manager secret placeholders, no Cloud Run job, no schedulers.
- The CMS export API (spec §6) is built and reviewed on a branch in the `sipandscript-sns.webapp.cms`
  repo but not deployed anywhere — the CMS loader cannot run at all yet.
- The Stripe load's order-matching is not delivered yet — see item 9.
- The Google Ads BigQuery Data Transfer has not been authorised.
- Meta/Pinterest spend CSVs have never been dropped in the bucket (the bucket doesn't exist yet).
- Both schedulers, the Looker Studio report, and the brief's `BRIEF_SOURCE=warehouse` switch are all
  pending on the above.

## Raw writer payload bug — found and fixed 2026-09-27

`loaders/common/bq.py`'s `RawWriter.append()` double-JSON-encoded the `payload` column, which would
have made every future loader's raw rows unusable (see `docs/runbook.md`). It was found during this
Search Console backfill and fixed the same day in commit `1d4d1b4`, verified with a real BigQuery round
trip and guarded going forward by `dbt/tests/staging/assert_raw_payloads_are_objects.sql`. No raw rows
were ever loaded with the bug present. Nothing further to do here — noted for the record since it would
otherwise have silently broken the CMS backfill (item 8) and the Stripe load (item 9).

## Ordered checklist

1. **Push the CMS export API branch and open its MR.**
   Who: CMS repo owner/developer. What: `git push origin feat/analytics-export-api` in the
   `sipandscript-sns.webapp.cms` checkout, then open a merge request against that repo's default
   branch. Verify: MR exists and CI runs on it. Unblocks: code review and eventual merge/deploy.

2. **Deploy to dev1; set the export API key; run the smoke checks.**
   Who: CMS repo owner, with deploy access to dev1. What: after merge, deploy to the dev1 environment;
   set `Analytics__ExportApiKey` in Doppler to at least 32 random bytes
   (e.g. `openssl rand -hex 32`); run `scripts/analytics-export-smoke.sh` (in the CMS repo) against
   dev1; then, against the dev server, manually check: (a) a keyset walk with a small `pageSize`
   (e.g. 25) returns the same total row count as `SELECT COUNT(*)` on the underlying table; (b) a
   `nextCursor` obtained before an app restart is still valid and resumes correctly after the app
   restarts; (c) event `startAtUtc`/`endAtUtc` match the public site's displayed times for a sample of
   events, including at least one non-Eastern-timezone venue; (d) `venues.latitude`/`longitude` are
   present (non-null) on a sample of venues; (e) a request with no/garbage token returns 401, and a
   request when the config key is unset returns 404. Verify: all five checks pass; smoke script exits
   0. Unblocks: confidence the export contract (spec §6) matches the real deployment before touching
   production.

3. **Production deploy of the CMS change.**
   Who: CMS repo owner. What: standard production deploy process for that repo, once dev1 checks pass
   and the MR is approved/merged. Verify: `GET /api/export/events?pageSize=1` against production with a
   valid token returns a 200 with a well-formed envelope (`entity`, `generatedAt`, `items`,
   `nextCursor`). Unblocks: the CMS loader can now run against a real, production export.

4. **Run `infra/setup.sh` in Cloud Shell.**
   Who: a human with `gcloud`/`bq` access and IAM admin on `sipandscript` (the dev laptop's `gcloud`
   and `bq` are broken; this must run from Cloud Shell). What: `bash infra/setup.sh`. It is idempotent
   — safe to re-run. Verify: script exits 0; it prints manual follow-ups (secrets, Ads transfer
   authorisation, Search Console SA grant, first-run scheduler resume) — those are items 5-7 and 11
   below, not automatic. Unblocks: the `sns-analytics@sipandscript.iam.gserviceaccount.com` service
   account, its IAM bindings, the `sns-analytics-drop` bucket, the Cloud Run job `sns-analytics`, and
   both schedulers (created paused) all now exist.

5. **Set the two secrets.**
   Who: same human as item 4, Cloud Shell. What:
   `printf '%s' "$STRIPE_KEY" | gcloud secrets versions add stripe-restricted-key --data-file=-` and
   the same for `cms-export-token` (value = the `Analytics__ExportApiKey` set in item 2/3's Doppler
   config). Verify: `gcloud secrets versions list stripe-restricted-key` (and `cms-export-token`) shows
   an `ENABLED` version. Unblocks: the Cloud Run job (and any local run exporting these as env vars) can
   authenticate to Stripe and the CMS export API.

6. **Authorise the Google Ads transfer and backfill; then flip `google_ads_enabled`.**
   Who: a human with read access to Google Ads customer `1863952460`. What: BigQuery console → Data
   transfers → `sns-google-ads` (created by `infra/setup.sh`) → authorise with that user's credentials
   → trigger a 90-day backfill. Once `google_ads.campaign_stats`/`campaign`/`click_stats` have rows,
   edit `dbt/dbt_project.yml`'s `vars.google_ads_enabled` to `true` and run `dbt build`. Verify:
   `select count(*) from google_ads.campaign_stats` (or whatever the transfer names it) is non-zero
   before flipping the var; after flipping, `dbt build` compiles (no "table not found" errors) and
   `mart.mart_paid_performance` shows `platform = 'google'` rows. Unblocks: Google Ads spend/ROAS in
   `mart_paid_performance`; success criterion 4 (spec §11).

7. **Add the pipeline service account to both Search Console properties.**
   Who: a Search Console owner on `https://sipandscript.com/` and `https://www.sipandscript.com/`.
   What: Search Console → Settings → Users and permissions → Add user →
   `sns-analytics@sipandscript.iam.gserviceaccount.com` → Restricted (read-only is sufficient for the
   `webmasters.readonly` scope the loader uses). Verify: the SA appears in both properties' user lists.
   **Status: the 480-day Search Console backfill is done** (this task, 2026-09-27, using the human
   operator's own ADC, which already had access — see `docs/phase1-acceptance.md` for row counts,
   date range and measurements). This item is still needed, unchanged, before the **Cloud Run job's
   service account** can run the GSC loader unattended on schedule — the job runs as that SA, not as
   the operator's own credentials. Unblocks: scheduled (non-manual) Search Console loads once the job
   exists (item 4) and schedulers are resumed (item 11).

8. **First CMS backfill.**
   Who: whoever ran items 1-3. What:
   `python -m loaders run --sources cms --full` then `cd dbt && dbt build`. Verify: `assert_
   webapp_orders_present` no longer appears as a warning; the two pinned-fact tests
   (`assert_post_launch_orders_pinned`, `assert_post_launch_ticket_revenue_pinned`) become meaningful —
   expect roughly 5,328 orders (±1%, i.e. 5,275-5,381) and $474.1k net ticket revenue (±1%, i.e.
   $469,359-$478,841) for `business_date between '2026-06-23' and '2026-09-17'`. Unblocks: real
   new-site orders throughout `core`/`mart`; the Slack brief's warehouse path becomes meaningful
   (`brief/README.md`'s "Before switching" precondition 1).

9. **The Stripe load.**
   Owned by the **economic truth layer plan** (a separate, already-in-progress plan/session), not this
   task; it requires the repository owner's explicit approval before it runs. As of the last check in
   this task (2026-09-27, during the Search Console backfill above), `raw_stripe.balance_transactions`
   held 65,000 rows — that plan's load appears to be in progress or done; this task did not run it and
   did not check again after that point, so check `select count(*) from raw_stripe.balance_transactions`
   for the current state before assuming either way. It is a full-history load (from 2026-06-19) of
   several hundred thousand Stripe objects, expected to take roughly 20-40 minutes once approved. The
   sanitiser that strips personal data from Stripe payloads before they're stored is already merged
   (commit `4d21fe5`). **Order matching for Stripe rows
   (joining a Stripe transaction to a `core.orders` row) is delivered by that same plan, not by this
   one** — until it lands, `core_stripe_transactions.order_key` is NULL on every row, so
   `mart.orders_reconciliation` can only compare day-level totals (CMS-side orders/revenue vs.
   Stripe-side charges/net/fees for the same day), not per-order variance. Verify (once that plan
   reports it done): `select count(*) from raw_stripe.balance_transactions` is non-zero;
   `mart.orders_reconciliation` has rows with `variance_pct` populated for recent days. Unblocks:
   success criterion 1 and 2 (spec §11); the brief's precondition 2 in `brief/README.md`.

10. **Drop Meta and Pinterest spend CSVs in the bucket.**
    Who: whoever manages the Ads Manager exports. What: export the standard daily-by-campaign CSV from
    each platform's Ads Manager and upload to `gs://sns-analytics-drop/spend/meta/*.csv` and
    `gs://sns-analytics-drop/spend/pinterest/*.csv` (bucket created by item 4). Required columns after
    header normalisation: `date, campaign_name, spend, impressions, clicks` (see
    `loaders/spend_csv.py`'s `HEADER_MAP` for accepted header spellings). Verify:
    `python -m loaders run --sources spend` reports non-zero rows for `spend.meta`/`spend.pinterest` in
    `ops.run_log`. Unblocks: Meta/Pinterest rows in `core.core_ad_spend` and `mart.mart_paid_performance`.

11. **One manual job execution, then resume both schedulers.**
    Who: the human from item 4, Cloud Shell, after items 5-10 are in whatever state they'll be in for
    go-live (not all need to be complete — the job tolerates partial source failure). What:
    `gcloud run jobs execute sns-analytics --region us-east1 --wait`; confirm exit 0 and the Slack line
    `sns-analytics daily OK — loaders rc=0, dbt rc=0` (or investigate `PROBLEMS` via `ops.run_log`
    first). Then: `gcloud scheduler jobs resume sns-analytics-daily --location us-east1 && gcloud
    scheduler jobs resume sns-analytics-hourly --location us-east1`. Verify: watch two hourly runs and
    one daily run land in `ops.run_log` with `status = 'ok'`. Unblocks: the pipeline runs unattended.

12. **Create the Looker Studio report.**
    Who: anyone with BigQuery Data Viewer on `mart`/`core` (spec §9 — the user's own Google identity).
    What: follow `docs/looker-studio.md` step by step. Verify: both data sources connect, page 1 and
    page 2 render with real numbers once items 8/9 have landed real data (before that, expect mostly
    zeros/blanks on the Paid page — not a report bug). Unblocks: a shareable dashboard for the team.

13. **Apply the brief patch.**
    Who: whoever owns deploys of the `sipandscript-sns.webapp.cms` repo's `scripts/google-ads/`
    Cloud Run job. What: first work through `brief/README.md`'s "Before switching `BRIEF_SOURCE` to
    `warehouse` in production" checklist (new-site orders flowing — item 8 above; a real day's
    orders/revenue compared warehouse-vs-Stripe-dashboard — item 9 above; daily job finishing before
    the brief's schedule) — only once all three hold, apply
    `patch -p0 < /path/to/sns-analytics/brief/ga_report_wiring.patch` from that repo's
    `scripts/google-ads/` directory, vendor `brief/warehouse.py` (+ `brief/__init__.py`) into
    `scripts/google-ads/brief/`, and set `BRIEF_SOURCE=warehouse` on that Cloud Run job's deploy
    command. Verify: the morning brief in `#analytics` shows orders/revenue that match the Stripe
    dashboard for a real recent day. Unblocks: the Slack brief runs off this warehouse instead of the
    GA4 Data API directly.
