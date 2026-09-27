# Infra

`setup.sh` is idempotent. Run it from Cloud Shell (`gcloud` on the dev laptop is broken). Re-running setup.sh is safe; it never re-pauses existing schedulers and never recreates the transfer. Manual follow-ups it prints:
1. Set secret values: `printf '%s' "$STRIPE_KEY" | gcloud secrets versions add stripe-restricted-key --data-file=-` and the same for `cms-export-token` (value = `Analytics__ExportApiKey` in Doppler).
2. Authorise the Google Ads transfer in the console and backfill 90 days.
3. Add `sns-analytics@sipandscript.iam.gserviceaccount.com` as a Restricted user on both Search Console properties.
4. After the first clean manual run (`gcloud run jobs execute sns-analytics --region us-east1 --wait`), resume both schedulers.
Local datasets only: `python infra/bq_admin.py datasets`.
