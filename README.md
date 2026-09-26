# sns-analytics

BigQuery analytics pipeline for Sip & Script. Design: `docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md`.

    python3.12 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]"
    pytest
    CMS_BASE_URL=https://www.sipandscript.com CMS_EXPORT_TOKEN=... python -m loaders run --sources cms
    cd dbt && dbt build

Cloud Run job `sns-analytics` (us-east1) runs `jobs/entrypoint.sh` on the schedules in `infra/setup.sh`.
