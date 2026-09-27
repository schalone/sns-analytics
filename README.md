# sns-analytics

BigQuery analytics pipeline for Sip & Script: four Python loaders land raw source data in BigQuery on a
schedule, dbt (BigQuery adapter) transforms it into a tested core model and three phase-one marts, and
consumers (Claude via the BigQuery MCP, Looker Studio, the Slack morning brief) read the marts.

Design: `docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md`. Implementation plans:
`docs/superpowers/plans/2026-09-26-analytics-pipeline.md` (this pipeline) and
`docs/superpowers/plans/2026-09-27-economic-truth-layer.md` (a follow-on plan that owns the Stripe load
and order-matching rework). Operational docs: `docs/runbook.md`, `docs/looker-studio.md`,
`docs/handoff.md`, `docs/phase1-acceptance.md`.

## Repository layout

```
sns-analytics/
  loaders/              Python package: one module per source + shared CLI
    common/             bq.py (RawWriter), config.py (Settings), state.py (LoadState/run_step), slack.py
    cms.py               CMS export API loader (source `cms`) -- not deployable yet, see docs/handoff.md
    stripe_loader.py      Stripe API loader (source `stripe`) -- owned by the economic truth layer plan
    stripe_sanitize.py    strips personal data from Stripe payloads before they're stored
    gsc.py                 Search Console Search Analytics API loader (source `gsc`)
    spend_csv.py           Meta/Pinterest CSV-drop loader (source `spend`)
  dbt/                  dbt-core project (dbt-bigquery)
    models/staging/       one view per raw entity (cms/, stripe/, gsc/, spend/, woo/)
    models/core/           cleaned entities: orders, sessions, events, ad_spend, search_daily, ...
    models/marts/          mart_daily_kpis, mart_paid_performance, mart_orders_reconciliation
    tests/                 singular data tests (corrections, pinned facts, reconciliation)
    seeds/                 date_flags.csv, campaign_metro_map.csv
  brief/                warehouse-backed data for the Slack morning brief (module + patch; see brief/README.md)
  infra/                setup.sh (idempotent GCP setup, run from Cloud Shell), bq_admin.py, create_raw_tables.py
  jobs/                 entrypoint.sh (loaders -> dbt build -> Slack status), used by the root Dockerfile
  tests/                pytest for loaders, with recorded fixtures -- no live API calls
  docs/                 runbook, Looker Studio setup, handoff checklist, phase-one acceptance record
  docs/superpowers/     specs and plans (design docs, not runtime code)
```

## Quick start

```bash
# one-time: create the venv (already exists in a checked-out worktree; python3.11+, matches pyproject)
python3.11 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]"

# tests (loaders only; no BigQuery/API calls -- recorded fixtures)
pytest -q

# run one loader locally (needs Application Default Credentials: gcloud auth application-default login)
export CMS_BASE_URL=https://www.sipandscript.com CMS_EXPORT_TOKEN=...
python -m loaders run --sources cms

# dbt, from dbt/, against the same BigQuery project via your own ADC
cd dbt && export DBT_PROFILES_DIR=$(pwd)
../.venv/bin/dbt build
```

See `docs/runbook.md` for the full loader/dbt command reference (per-source runs, `--full`, watermark
resets, rebuilding a model and its descendants, `--full-refresh` cost, secret rotation, reading
failures from `ops.run_log`, and a known open issue in the raw-payload write path). See
`docs/handoff.md` for the ordered list of what a human still needs to do to take this pipeline live,
and what's already live in BigQuery today versus what isn't. See `docs/looker-studio.md` for building
the Looker Studio report against `mart.mart_daily_kpis` and `mart.mart_paid_performance`.

Cloud Run job `sns-analytics` (us-east1) runs `jobs/entrypoint.sh` on the schedules `infra/setup.sh`
creates (paused until a human resumes them per `docs/handoff.md`).
