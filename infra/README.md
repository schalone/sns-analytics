# Infra

`setup.sh` is idempotent. Run it from Cloud Shell (`gcloud` and `bq` on the dev laptop are broken). Re-running
it is safe: it never re-pauses or resumes existing schedulers (it only converges their schedule, target and
empty body) and never recreates the transfer.

What it creates: the service account and its IAM (BigQuery roles per dataset; Secret Manager access granted
per secret on `stripe-restricted-key`, `cms-export-token` and `slack-ads-sync-bot-token`, never project-wide;
`run.invoker` on each job), the spend bucket, the two secret placeholders, the Google Ads transfer, and two
Cloud Run jobs from one image, each with a fixed mode and `--max-retries 0`:

| Job | Env | Scheduler (created PAUSED) |
|---|---|---|
| `sns-analytics-daily` | `MODE=daily`, `SOURCES=cms,stripe,gsc,spend` (a job deployed before Stripe was added still has `cms,gsc,spend`; in a fresh project the Stripe steps fail until the history is loaded once with `python -m loaders run --sources stripe --full`; see `docs/runbook.md`) | `sns-analytics-daily`, `0 11 * * *` UTC |
| `sns-analytics-hourly` | `MODE=hourly` | `sns-analytics-hourly`, `30 0-10,12-23 * * *` UTC |

Schedulers POST an empty body `{}` to `…/jobs/<job>:run` (no overrides).

Manual follow-ups it prints:
1. Give every secret an enabled version (a secret without one stops both jobs from starting):
   `printf '%s' "$STRIPE_KEY" | gcloud secrets versions add stripe-restricted-key --data-file=-` and the same for
   `cms-export-token` (value = `Analytics__ExportApiKey` in Doppler); `slack-ads-sync-bot-token` already exists.
2. Authorise the Google Ads transfer in the console and backfill 90 days.
3. Add `sns-analytics@sipandscript.iam.gserviceaccount.com` as a Restricted user on both Search Console properties.
4. After one clean manual run of each job (`gcloud run jobs execute sns-analytics-daily --region us-east1 --wait`,
   then the same for `sns-analytics-hourly`), resume both schedulers.
5. If a single job named `sns-analytics` exists from an earlier version of this script, delete it.

Local datasets only: `python infra/bq_admin.py datasets`. Raw tables: `python infra/create_raw_tables.py`.
