# sns-analytics

BigQuery analytics pipeline for Sip & Script: four Python loaders land raw source data in BigQuery on a
schedule, dbt (BigQuery adapter) transforms it into a tested core model and four marts, and
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
    common/             bq.py (RawWriter), config.py (Settings), state.py (LoadState/run_step), slack.py,
                        dbt_results.py (summarises dbt's run_results.json for the status message)
    cms.py               CMS export API loader (source `cms`) -- not deployable yet, see docs/handoff.md
    stripe_loader.py      Stripe API loader (source `stripe`) -- owned by the economic truth layer plan
    stripe_sanitize.py    strips personal data from Stripe payloads before they're stored
    gsc.py                 Search Console Search Analytics API loader (source `gsc`)
    spend_csv.py           Meta/Pinterest CSV-drop loader (source `spend`)
  dbt/                  dbt-core project (dbt-bigquery)
    models/staging/       one view per raw entity (cms/, stripe/, gsc/, spend/, woo/)
    models/core/           cleaned entities: orders, sessions, events, ad_spend, search_daily, ...; the economics
                           layer: stripe_transactions, customer_identity, order_item_economics, seat_transfers,
                           bookings, event_daily, event_economics, customers, ad_spend_allocation
    models/marts/          mart_daily_kpis, mart_paid_performance, mart_orders_reconciliation, mart_event_performance
    models/ops/            ops_unallocated_ad_spend
    tests/                 singular data tests (corrections, pinned facts, reconciliation)
    seeds/                 date_flags.csv, campaign_metro_map.csv
    selectors.yml          the `hourly` selector used by the hourly job
  brief/                warehouse-backed data for the Slack morning brief (module + patch; see brief/README.md)
  infra/                setup.sh (idempotent GCP setup, run from Cloud Shell), bq_admin.py, create_raw_tables.py
  scripts/              econ_check_order.py (read-only second opinion on one order's charges, refunds and fees
                        straight from Stripe; prints amounts only)
  jobs/                 entrypoint.sh (loaders -> dbt build -> Slack status), used by the root Dockerfile
  tests/                pytest for loaders, with recorded fixtures -- no live API calls
  docs/                 runbook, Looker Studio setup, handoff checklist, phase-one acceptance record,
                        ECON-001 validation record
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

# dbt, from dbt/, against the same BigQuery project via your own ADC.
# Set a schema prefix first: without it a local build writes the PRODUCTION staging/core/mart/ops tables.
cd dbt && export DBT_PROFILES_DIR=$(pwd) DBT_SCHEMA_PREFIX=dev_<your name>
../.venv/bin/dbt build          # writes dev_<name>_staging, dev_<name>_core, dev_<name>_mart, dev_<name>_ops
```

See `docs/runbook.md` for the full loader/dbt command reference (per-source runs, `--full`, watermark
resets, rebuilding a model and its descendants, `--full-refresh` cost, secret rotation, reading
failures from `ops.run_log`). See
`docs/handoff.md` for the ordered list of what a human still needs to do to take this pipeline live,
and what's already live in BigQuery today versus what isn't. See `docs/looker-studio.md` for building
the Looker Studio report against `mart.mart_daily_kpis` and `mart.mart_paid_performance`.

Two Cloud Run jobs (us-east1) run `jobs/entrypoint.sh` from the same image: `sns-analytics-daily`
(`MODE=daily`: CMS, Stripe, Search Console and spend loaders, then the whole dbt project; a job deployed
before Stripe was added still has `SOURCES=cms,gsc,spend`, see `docs/runbook.md`) and `sns-analytics-hourly`
(`MODE=hourly`: CMS loader, then `dbt build --selector hourly`), on the schedules `infra/setup.sh` creates
(paused until a human resumes them per `docs/handoff.md`).

## Economics

Revenue left after refunds and Stripe fees is split 40% to Sip & Script (S&S) and 60% to the instructor.
Per ticket booking (one order item, that is order x event, in `core_bookings`):

```
realized_revenue   = ticket line value + allocated service fee - allocated discount
net_distributable  = realized_revenue - refunded_amount - processing_fee
sns_share          = 0.40 x net_distributable          (dbt var sns_share_rate)
instructor_share   = 0.60 x net_distributable          (dbt var instructor_share_rate)
sns_contribution   = sns_share - allocated_ad_spend    (event level and above)
```

Materials are paid by instructors from their share and are never subtracted from S&S figures.
`processing_fee` is the Stripe fee on the order's charge, refund and dispute transactions, allocated by line
total; when an order has no Stripe match it is estimated (`legacy_fee_rate`, `legacy_fee_fixed`), which
applies to 14 legacy bookings. A fully refunded booking keeps a negative net: Stripe keeps its fee.

**Transferred seats.** The legacy site moved a seat to another class by creating a zero-total order, one
per seat, whose parent is the original paid order; the instructor who teaches the class attended earns
the money. So the seat and its money follow the transfer: the transfer booking (`booking_kind =
'transfer_in'`) sits on the class attended, from the transfer date, and carries the original line's
realized revenue, refund, fee and shares per seat, found through `transfer_root_order_key`; the original
booking keeps only the seats that stayed (`seats_purchased`, `seats_transferred_out`). A transfer that
was itself moved on again holds no seat and no money (`transfer_superseded`). Transfer orders are not
purchases and are left out of the KPI mart's order and seat counts. Zero-total orders with ticket value and no paid
origin (`unpaid_zero_total`, likely tickets bought with gift cards, not established) keep their line
value with no fee and are labelled so they can be excluded.

New tables:

- `core_stripe_transactions`: every Stripe balance transaction with the order it matches and how it matched.
- `core_customer_identity`: one row per order with its customer hash and where the identity came from.
- `core_order_item_economics`: every order item (tickets, gift cards, other) with its allocated economics.
- `core_seat_transfers`: each legacy transfer order line with its root order, depth and whether it holds its seat.
- `core_bookings`: the economics fact, one row per ticket order item.
- `core_event_daily`: the booking curve, event x day, with cumulative seats, revenue, S&S share and ad spend.
- `core_event_economics`: one row per event with seats, utilisation, money, contribution and pace.
- `core_customers`: one row per resolved customer with lifetime figures.
- `core_ad_spend_allocation` and `ops_unallocated_ad_spend`: ad spend divided among the events selling that day, and what could not be.
- `mart_event_performance`: `core_event_economics` plus peer benchmarks.

How these figures were checked by hand against Stripe and the archive, and what is not yet validated:
`docs/econ-001-validation.md`.
