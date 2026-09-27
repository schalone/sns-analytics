#!/usr/bin/env bash
# Idempotent GCP setup for the sns-analytics pipeline. Run in Cloud Shell: bash infra/setup.sh
set -euo pipefail
PROJECT=sipandscript; REGION=us-east1; LOCATION=US
SA=sns-analytics@${PROJECT}.iam.gserviceaccount.com
DAILY_JOB=sns-analytics-daily; HOURLY_JOB=sns-analytics-hourly; BUCKET=sns-analytics-drop; ADS_CUSTOMER=1863952460
SECRETS="stripe-restricted-key cms-export-token slack-ads-sync-bot-token"
gcloud config set project $PROJECT >/dev/null

echo "## datasets"
for d in raw_cms raw_stripe raw_gsc raw_spend google_ads ops staging core mart; do
  if ! bq show --dataset "$PROJECT:$d" >/dev/null 2>&1; then
    bq --location=$LOCATION mk --dataset "$PROJECT:$d"
  fi
  loc=$(bq show --format=json --dataset "$PROJECT:$d" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("location",""))')
  if [ "$loc" != "$LOCATION" ]; then echo "ERROR: dataset $d is in '$loc', expected $LOCATION" >&2; exit 1; fi
done

echo "## service account + IAM"
gcloud iam service-accounts describe $SA >/dev/null 2>&1 || gcloud iam service-accounts create sns-analytics --display-name "sns-analytics pipeline"
gcloud projects add-iam-policy-binding $PROJECT --member serviceAccount:$SA --role roles/bigquery.jobUser --quiet >/dev/null
for d in raw_cms raw_stripe raw_gsc raw_spend ops staging core mart; do
  bq add-iam-policy-binding --member serviceAccount:$SA --role roles/bigquery.dataEditor "$PROJECT:$d" >/dev/null
done
for d in analytics_313669961 sipandscript_new_ds google_ads; do
  bq add-iam-policy-binding --member serviceAccount:$SA --role roles/bigquery.dataViewer "$PROJECT:$d" >/dev/null
done

echo "## ads-builder access"
gcloud projects add-iam-policy-binding $PROJECT --member serviceAccount:ads-builder@sipandscript.iam.gserviceaccount.com --role roles/bigquery.jobUser --quiet >/dev/null
for d in mart core; do
  bq add-iam-policy-binding --member serviceAccount:ads-builder@sipandscript.iam.gserviceaccount.com --role roles/bigquery.dataViewer "$PROJECT:$d" >/dev/null
done

echo "## bucket"
gsutil ls -b gs://$BUCKET >/dev/null 2>&1 || gsutil mb -l $REGION gs://$BUCKET
gsutil iam ch serviceAccount:$SA:objectViewer gs://$BUCKET

echo "## secrets (placeholders; set real values with: printf '%s' VALUE | gcloud secrets versions add NAME --data-file=-)"
for s in stripe-restricted-key cms-export-token; do
  gcloud secrets describe $s >/dev/null 2>&1 || gcloud secrets create $s --replication-policy=automatic
done
# Access is granted per secret, never project-wide. slack-ads-sync-bot-token already exists (the ads-sync bot's).
# A secret with no ENABLED version stops the jobs from starting at all: add a version before the first run.
for s in $SECRETS; do
  gcloud secrets add-iam-policy-binding $s --member serviceAccount:$SA --role roles/secretmanager.secretAccessor --quiet >/dev/null
done

echo "## Google Ads transfer"
transfer_configs=$(bq ls --transfer_config --transfer_location=$LOCATION --format=prettyjson 2>/dev/null || true)
if ! grep -q '"displayName": "sns-google-ads"' <<<"$transfer_configs"; then
  bq mk --transfer_config --transfer_location=$LOCATION --project_id=$PROJECT --data_source=google_ads \
     --display_name=sns-google-ads --target_dataset=google_ads --params="{\"customer_id\":\"$ADS_CUSTOMER\",\"include_pmax\":true}"
  echo "   -> authorise the transfer in the console (BigQuery > Data transfers > sns-google-ads) with a user who can read Ads customer $ADS_CUSTOMER, then schedule a backfill of 90 days."
fi

echo "## Cloud Run jobs (one per mode; MODE fixed in the job, no overrides, no retries)"
# Two jobs from the same image, so a scheduler can never override the mode and a failed run is never retried
# into an overlap with the next one. The daily job's SOURCES excludes stripe until the economic truth layer plan
# has completed its full-history Stripe load (that plan adds it).
# env lists use gcloud's alternate delimiter syntax (^;^) because SOURCES itself contains commas
COMMON_ENV="CMS_BASE_URL=https://www.sipandscript.com;GCP_PROJECT=$PROJECT;SLACK_CHANNEL=C0C459A46ET;LOADERS_SUMMARY_FILE=/tmp/loaders-summary.txt"
JOB_SECRETS="STRIPE_RESTRICTED_KEY=stripe-restricted-key:latest,CMS_EXPORT_TOKEN=cms-export-token:latest,SLACK_BOT_TOKEN=slack-ads-sync-bot-token:latest"
JOB_FLAGS=(--region $REGION --service-account $SA --memory 2Gi --task-timeout 3600 --max-retries 0 --set-secrets "$JOB_SECRETS")
gcloud run jobs deploy $DAILY_JOB --source . "${JOB_FLAGS[@]}" \
  --set-env-vars "^;^$COMMON_ENV;MODE=daily;SOURCES=cms,gsc,spend"
IMAGE=$(gcloud run jobs describe $DAILY_JOB --region $REGION --format='value(spec.template.spec.template.spec.containers[0].image)')
if [ -z "$IMAGE" ]; then echo "ERROR: could not read the image of $DAILY_JOB" >&2; exit 1; fi
gcloud run jobs deploy $HOURLY_JOB --image "$IMAGE" "${JOB_FLAGS[@]}" \
  --set-env-vars "^;^$COMMON_ENV;MODE=hourly"

for job in $DAILY_JOB $HOURLY_JOB; do
  gcloud run jobs add-iam-policy-binding $job --region $REGION --member serviceAccount:$SA --role roles/run.invoker --quiet >/dev/null
done

echo "## schedulers"
# The scheduler body is always {}: no containerOverrides. Hourly skips 11:30 UTC, the hour of the daily build
# (which builds a superset of the hourly selection).
RUN_BASE="https://run.googleapis.com/v2/projects/$PROJECT/locations/$REGION/jobs"
ensure_scheduler() {  # name schedule job
  local name=$1 schedule=$2 job=$3
  if ! gcloud scheduler jobs describe $name --location $REGION >/dev/null 2>&1; then
    gcloud scheduler jobs create http $name --location $REGION --schedule "$schedule" --time-zone UTC --uri "$RUN_BASE/$job:run" \
         --http-method POST --oauth-service-account-email $SA --message-body '{}'
    gcloud scheduler jobs pause $name --location $REGION
  else
    # converge an existing scheduler (e.g. one created for the old single job) without resuming or pausing it
    gcloud scheduler jobs update http $name --location $REGION --schedule "$schedule" --time-zone UTC --uri "$RUN_BASE/$job:run" \
         --http-method POST --oauth-service-account-email $SA --message-body '{}'
  fi
}
ensure_scheduler sns-analytics-daily "0 11 * * *" $DAILY_JOB
ensure_scheduler sns-analytics-hourly "30 0-10,12-23 * * *" $HOURLY_JOB
echo "new schedulers are created PAUSED; existing schedulers keep their paused/enabled state. Resume after the first successful manual run of each job."
echo "if the old single job 'sns-analytics' exists from an earlier version of this script, delete it: gcloud run jobs delete sns-analytics --region $REGION"
