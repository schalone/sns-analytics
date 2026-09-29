#!/usr/bin/env bash
# Build the brief/ads image from the repo root and roll the Cloud Run job `sns-ads-sync` onto it.
# Schedulers (sns-ga-report-daily 12:15 UTC --brief, sns-ads-sync-weekly Mon 11:00 UTC --apply) are unchanged.
# Usage: brief/deploy.sh            (from anywhere inside the repo)
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
PROJECT=sipandscript REGION=us-east1 JOB=sns-ads-sync
IMAGE="$REGION-docker.pkg.dev/$PROJECT/cloud-run-source-deploy/$JOB:$(git rev-parse --short HEAD)"
SA=ads-builder@$PROJECT.iam.gserviceaccount.com
cat > /tmp/cloudbuild-brief.yaml <<YAML
steps:
- name: gcr.io/cloud-builders/docker
  args: ['build', '-f', 'brief/Dockerfile', '-t', '$IMAGE', '.']
images: ['$IMAGE']
YAML
gcloud builds submit --project "$PROJECT" --region "$REGION" --config /tmp/cloudbuild-brief.yaml . --quiet
gcloud run jobs deploy "$JOB" --project "$PROJECT" --region "$REGION" --image "$IMAGE" \
  --service-account "$SA" --task-timeout 20m --max-retries 0 --memory 1Gi \
  --set-env-vars "STATE_BUCKET=sns-ads-sync,ANTHROPIC_FEDERATION_RULE_ID=fdrl_01DeyYjK2CitumthUG1dqVm5,ANTHROPIC_ORGANIZATION_ID=6b6f3926-f414-4288-9d14-d9c85e874398,ANTHROPIC_SERVICE_ACCOUNT_ID=svac_01R9YZ7NYdEL3Ys53FbUto2f,ANTHROPIC_WORKSPACE_ID=wrkspc_01TezEU4bYbdcBZRj2tnSAue${BRIEF_SOURCE:+,BRIEF_SOURCE=$BRIEF_SOURCE}" \
  --set-secrets "SLACK_WEBHOOK_URL=slack-ads-sync-webhook:latest,SLACK_BOT_TOKEN=slack-ads-sync-bot-token:latest" --quiet
echo "deployed $IMAGE"
