# brief — warehouse-backed data for the morning Slack brief

## What this is

The daily "morning brief" that posts to `#analytics` is a set of Python scripts (`ga_report.py`, `slack_post.py`,
`ai_summary.py`, `charts.py`, ...) that live and deploy from a **different** repository
(`sipandscript-sns.webapp.cms`, as a Cloud Run job built from its `scripts/google-ads/` folder). Today
`ga_report.report_data(key_file, today)` gets its numbers by calling the GA4 Data API directly.

This directory (`brief/` in **this** repo, sns-analytics) adds an alternative data source for that same
function: `brief/warehouse.py`, whose `report_data(bq, today)` returns the exact same structure —

```python
{
    "text": str,                                    # human-readable brief body
    "fields": [(label: str, value: str), ...],       # exactly 5 pairs: Sessions, Orders, Revenue,
                                                      # Conversion rate, Avg order
    "flags": [str, ...],                             # zero or more warning lines
    "series": [(date, sessions: int, orders: int), ...],  # 28 days ending yesterday, zero-filled
    "when": date,                                    # yesterday's date
}
```

— computed from this pipeline's BigQuery marts (`mart.mart_daily_kpis`, `core.core_sessions`,
`core.core_session_orders`, `core.core_orders`) instead of GA4. It has one job: fetch and shape data. It does
not touch Slack, charts, or the AI summary — those stay exactly as they are today.

`brief/ga_report_wiring.patch` is the minimal change to `ga_report.py` that lets it use this module. It is
**not applied to anything in this repo** — it's a diff against a file in the other (CMS) repo, produced and
verified here (see below) because this session is not permitted to modify, move, or create anything under
that repo's working directory.

See `brief/warehouse.py`'s module docstring for exactly how each field is computed and every known
approximation versus the GA4 version (in short: "users" is reported as sessions, "orders" means ticket orders,
"revenue" means net revenue, and warehouse session totals will not exactly match GA4's once orders resume,
because the warehouse re-attributes phantom referrals (the `accounts.google.com` sign-in and the Stripe Checkout
return from `checkout.stripe.com`) rather than excluding them).

Two definitions changed on 2026-09-27 (final-review I11 and minors): the channel lines include `Other`
(sessions whose source/medium match no channel rule) and `Unattributed` (orders with no GA4 session), so they
add up to the headline; and "Avg order" divides ticket orders' net revenue (`mart_daily_kpis.ticket_net_revenue`)
by ticket orders, so numerator and denominator are the same population.

One of those approximations is worth calling out here too: `mart_daily_kpis.unreliable_ga4` flags the 2026-06-19..22 GA4
cutover blackout, and the mart itself reports that period's `cvr` as NULL. Any brief window (yesterday vs
same weekday last week, or the 7-vs-7 comparison) that includes one of those dates shows `"CVR n/a"` instead
of a computed percentage, and adds a `"⚠ window includes dates with unreliable GA4 tracking — sessions and
CVR not comparable"` line to the brief's flags. Sessions, orders and revenue are still shown as normal for
that window — only the CVR ratio is suppressed, since it's the one the mart itself can't compute for those
days. The daily chart (`series`) is unaffected and always shows the days' actual recorded sessions/orders.

## Layout (since the job moved into this repo, 2026-09-28)

The job itself lives here now (moved from `sipandscript-sns.webapp.cms/scripts/google-ads/`):

| file | role |
|---|---|
| `sync_radii.py` | entrypoint: `--apply` weekly radius sync, `--report` Ads report, `--ga-report` website report, `--brief` the combined morning brief; inventory-drop guard; Cloud Storage state |
| `ga_report.py` | website numbers from GA4 (orders = distinct transaction ids), or from `warehouse.py` when `BRIEF_SOURCE=warehouse` |
| `warehouse.py` | the BigQuery-backed `report_data` described above |
| `ai_summary.py` | Claude narrative via Workload Identity Federation (no API key) |
| `slack_post.py`, `charts.py` | Block Kit card + thread + PNG charts via the Ad Sync Bot token; webhook fallback |
| `build_campaigns.py`, `metros.json`, `rest_of_us.json` | idempotent Google Ads campaign builder and its inputs |
| `Dockerfile`, `requirements.txt`, `deploy.sh` | own image built from the repo root; `deploy.sh` rolls `sns-ads-sync` |

Tests: `tests/test_brief_*.py` (unittest-style, collected by pytest). Launch record and account facts:
`docs/google-ads-search-launch.md`.

The `BRIEF_SOURCE=warehouse` switch is a plain `from brief.warehouse import report_data` inside
`ga_report.report_data` — the old cross-repo patch and vendoring steps are gone. Set the variable on the job by
running `BRIEF_SOURCE=warehouse brief/deploy.sh` once the preconditions below hold.

## IAM

The brief's Cloud Run job runs as `ads-builder@sipandscript.iam.gserviceaccount.com`. `infra/setup.sh` in
**this** repo already grants that service account everything the warehouse path needs:

* `roles/bigquery.dataViewer` on the `mart` and `core` datasets
* `roles/bigquery.jobUser` on the `sipandscript` project (needed to run queries at all)

No further IAM changes are required to switch the brief over; this was verified by reading
`infra/setup.sh`, not by granting anything new.

## Env var

* `BRIEF_SOURCE=warehouse` — read data from BigQuery via `brief.warehouse.report_data` instead of the GA4
  Data API.
* Unset (or any other value) — unchanged GA4 path.

## Before switching `BRIEF_SOURCE` to `warehouse` in production

Do **not** flip the env var until all of the following are true:

1. **New-site orders are flowing into the warehouse.** As of this writing the dbt test/warning
   `assert_webapp_orders_present` is still firing (`WARN 1` in the latest `dbt test` run) — there have been
   zero `ticket_orders` in `mart_daily_kpis` for any post-launch (`business_date >= 2026-06-19`) day, which a
   direct BigQuery sanity query confirms. Until that warning is gone, the warehouse brief will report
   "0 orders" and "zero orders despite traffic" every single day regardless of real sales — not because the
   integration is broken, but because the orders genuinely aren't there yet.
2. **Yesterday's orders and revenue from the warehouse brief must be compared against the Stripe dashboard**
   for at least one real day with non-zero orders, and match within refunds, before trusting it unattended.
3. **The pipeline's daily job must finish before the brief's scheduled time.** `sns-analytics-daily` needs to
   have completed (and refreshed `mart_daily_kpis` for "yesterday") before `sns-ga-report-daily` runs, or the
   brief will read a stale or partially-populated day. Confirm the daily job's finish time and the brief's
   schedule don't race before switching.
4. **Job-failure alerting must be in place before switching.** Unlike the GA4 path, a warehouse query failure
   (BigQuery outage, IAM misconfiguration, a mart that failed to build) has no fallback: `report_data` doesn't
   catch it, retry against GA4, or post stale/partial numbers — it simply raises, and the brief job fails to
   post that day. That's the right failure mode (silently posting wrong numbers would be worse), but only if
   someone actually notices the job failed. Confirm the Cloud Run job's failure/alerting is wired up (e.g. a
   Cloud Monitoring alert on job failure, or whatever this job's existing on-call mechanism is) before
   switching, so a missed morning brief gets noticed the same day rather than days later.

Only after all four hold should `BRIEF_SOURCE=warehouse` be set on the Cloud Run job's deploy command (that
step lives in the CMS repo / its deploy docs, not here).
