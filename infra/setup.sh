#!/usr/bin/env bash
# Idempotent GCP setup for the sns-analytics pipeline. Run in Cloud Shell: bash infra/setup.sh
set -euo pipefail
PROJECT=sipandscript; REGION=us-east1; LOCATION=US
SA=sns-analytics@${PROJECT}.iam.gserviceaccount.com
JOB=sns-analytics; BUCKET=sns-analytics-drop; ADS_CUSTOMER=1863952460
gcloud config set project $PROJECT >/dev/null

echo "## datasets"
for d in raw_cms raw_stripe raw_gsc raw_spend google_ads ops staging core mart; do
  bq --location=$LOCATION mk --dataset --quiet "$PROJECT:$d" 2>/dev/null || true
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
gcloud projects add-iam-policy-binding $PROJECT --member serviceAccount:$SA --role roles/secretmanager.secretAccessor --quiet >/dev/null

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

echo "## Google Ads transfer"
if ! bq ls --transfer_config --transfer_location=$LOCATION --format=prettyjson | grep -q '"displayName": "sns-google-ads"'; then
  bq mk --transfer_config --transfer_location=$LOCATION --project_id=$PROJECT --data_source=google_ads \
     --display_name=sns-google-ads --target_dataset=google_ads --params="{\"customer_id\":\"$ADS_CUSTOMER\",\"include_pmax\":true}"
  echo "   -> authorise the transfer in the console (BigQuery > Data transfers > sns-google-ads) with a user who can read Ads customer $ADS_CUSTOMER, then schedule a backfill of 90 days."
fi

echo "## Cloud Run job"
gcloud run jobs deploy $JOB --source . --region $REGION --service-account $SA --memory 2Gi --task-timeout 3600 \
  --set-env-vars CMS_BASE_URL=https://www.sipandscript.com,GCP_PROJECT=$PROJECT,SLACK_CHANNEL=C0C459A46ET,MODE=daily,LOADERS_SUMMARY_FILE=/tmp/loaders-summary.txt \
  --set-secrets STRIPE_RESTRICTED_KEY=stripe-restricted-key:latest,CMS_EXPORT_TOKEN=cms-export-token:latest,SLACK_BOT_TOKEN=slack-ads-sync-bot-token:latest

gcloud run jobs add-iam-policy-binding $JOB --region $REGION --member serviceAccount:$SA --role roles/run.invoker --quiet >/dev/null

echo "## schedulers"
RUN_URI="https://run.googleapis.com/v2/projects/$PROJECT/locations/$REGION/jobs/$JOB:run"
gcloud scheduler jobs describe sns-analytics-daily --location $REGION >/dev/null 2>&1 \
  || gcloud scheduler jobs create http sns-analytics-daily --location $REGION --schedule "0 11 * * *" --time-zone UTC --uri "$RUN_URI" --http-method POST \
       --oauth-service-account-email $SA --message-body '{"overrides":{"containerOverrides":[{"env":[{"name":"MODE","value":"daily"}]}]}}'
gcloud scheduler jobs describe sns-analytics-hourly --location $REGION >/dev/null 2>&1 \
  || gcloud scheduler jobs create http sns-analytics-hourly --location $REGION --schedule "30 * * * *" --time-zone UTC --uri "$RUN_URI" --http-method POST \
       --oauth-service-account-email $SA --message-body '{"overrides":{"containerOverrides":[{"env":[{"name":"MODE","value":"hourly"}]}]}}'
gcloud scheduler jobs pause sns-analytics-daily --location $REGION; gcloud scheduler jobs pause sns-analytics-hourly --location $REGION
echo "schedulers created PAUSED; resume after the first successful manual run (Task 16)."
