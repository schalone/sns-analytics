#!/usr/bin/env bash
# MODE=daily|hourly (default daily). Loaders never abort the run; dbt builds on whatever loaded.
set -uo pipefail
MODE="${MODE:-daily}"
export LOADERS_SUMMARY_FILE="${LOADERS_SUMMARY_FILE:-/tmp/loaders-summary.txt}"
rm -f "$LOADERS_SUMMARY_FILE"
if [ "$MODE" = "hourly" ]; then
  python -m loaders run --sources cms --mode hourly; rc=$?
  ( cd /app/dbt && dbt build --select tag:hourly --target prod ); drc=$?
else
  python -m loaders run --mode daily; rc=$?
  ( cd /app/dbt && dbt build --target prod ); drc=$?
fi
python - <<'EOF' "$rc" "$drc" "$MODE"
import os, sys
from loaders.common.config import Settings
from loaders.common.slack import compose_run_status, post_status
rc, drc, mode = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
summary_file = os.environ.get("LOADERS_SUMMARY_FILE", "")
summary = ""
if summary_file and os.path.exists(summary_file):
    with open(summary_file, encoding="utf-8") as f:
        summary = f.read()
s = Settings.from_env(os.environ)
post_status(s, compose_run_status(mode, rc, drc, s.run_id, summary))
EOF
exit $(( rc != 0 || drc != 0 ))
