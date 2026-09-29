#!/usr/bin/env bash
# One Cloud Run job per mode, MODE fixed in the job's env (sns-analytics-daily: MODE=daily,
# sns-analytics-hourly: MODE=hourly). Loaders never abort the run; dbt builds on whatever loaded.
#   daily : loaders for $SOURCES (default cms,stripe,gsc,spend; the Stripe history is loaded and its watermark
#           set, so each run loads Stripe incrementally), then the whole dbt project.
#   hourly: the CMS loader only, then `dbt build --selector hourly` (CMS-derived models with their staging
#           ancestors and tests, never the GA4-backed session models).
set -uo pipefail
MODE="${MODE:-daily}"
SOURCES="${SOURCES:-cms,stripe,gsc,spend}"
DBT_DIR=/app/dbt
export LOADERS_SUMMARY_FILE="${LOADERS_SUMMARY_FILE:-/tmp/loaders-summary.txt}"
export DBT_RESULTS_FILE="$DBT_DIR/target/run_results.json"
rm -f "$LOADERS_SUMMARY_FILE" "$DBT_RESULTS_FILE"
if [ "$MODE" = "hourly" ]; then
  python -m loaders run --sources cms --mode hourly; rc=$?
  ( cd "$DBT_DIR" && dbt build --selector hourly --target prod ); drc=$?
else
  python -m loaders run --sources "$SOURCES" --mode daily; rc=$?
  ( cd "$DBT_DIR" && dbt build --target prod ); drc=$?
fi
python - <<'EOF' "$rc" "$drc" "$MODE"
# Final status: ONE message per run (spec §10) with the dbt model/test counts and up to 10 failing nodes, and
# one ops.run_log row for the dbt invocation. Hourly runs post only problems. Never changes the exit code.
import os, sys
from loaders.common.dbt_results import summarise_run_results
from loaders.common.slack import compose_run_status, post_status, should_post
rc, drc, mode = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
summary = ""
path = os.environ.get("LOADERS_SUMMARY_FILE", "")
if path and os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        summary = f.read()
dbt = summarise_run_results(os.environ["DBT_RESULTS_FILE"])
try:
    from loaders.common.config import Settings
    settings = Settings.from_env(os.environ)
except Exception as e:  # noqa: BLE001 - still print the status line
    print(f"status: settings unavailable ({type(e).__name__}: {e})")
    settings = None
text = compose_run_status(mode, rc, drc, settings.run_id if settings else "?", summary, dbt_line=dbt.line())
if settings is not None:
    try:
        from google.cloud import bigquery
        from loaders.common.state import LoadState
        state = LoadState(bigquery.Client(project=settings.project, location=settings.location), settings.project)
        state.log(settings.run_id, f"dbt.{mode}", "ok" if drc == 0 and dbt.ok else "error", dbt.nodes,
                  ", ".join(dbt.failed_nodes) or (dbt.error or ""))
    except Exception as e:  # noqa: BLE001 - a run_log failure must not lose the status message
        text += f"\n⚠ ops.run_log write failed: {type(e).__name__}"
if settings is not None and should_post(mode, rc, drc):
    post_status(settings, text)
else:
    print(text)
EOF
exit $(( rc != 0 || drc != 0 ))
