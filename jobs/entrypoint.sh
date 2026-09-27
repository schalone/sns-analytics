#!/usr/bin/env bash
# MODE=daily|hourly (default daily). Loaders never abort the run; dbt builds on whatever loaded.
set -uo pipefail
MODE="${MODE:-daily}"
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
from loaders.common.slack import post_status
rc, drc, mode = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
s = Settings.from_env(os.environ)
status = "OK" if rc == 0 and drc == 0 else "PROBLEMS"
post_status(s, f"sns-analytics {mode} {status} — loaders rc={rc}, dbt rc={drc}, run {s.run_id}")
EOF
exit $(( rc != 0 || drc != 0 ))
