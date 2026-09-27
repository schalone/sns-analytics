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
because the warehouse re-attributes the `accounts.google.com` phantom referral rather than excluding it).

One of those is worth calling out here too: `mart_daily_kpis.unreliable_ga4` flags the 2026-06-19..22 GA4
cutover blackout, and the mart itself reports that period's `cvr` as NULL. Any brief window (yesterday vs
same weekday last week, or the 7-vs-7 comparison) that includes one of those dates shows `"CVR n/a"` instead
of a computed percentage, and adds a `"⚠ window includes dates with unreliable GA4 tracking — sessions and
CVR not comparable"` line to the brief's flags. Sessions, orders and revenue are still shown as normal for
that window — only the CVR ratio is suppressed, since it's the one the mart itself can't compute for those
days. The daily chart (`series`) is unaffected and always shows the days' actual recorded sessions/orders.

## Applying the patch (in the CMS repo, not here)

From `scripts/google-ads/` in the `sipandscript-sns.webapp.cms` checkout:

```bash
patch -p0 < /path/to/sns-analytics/brief/ga_report_wiring.patch
```

This adds one `import os` and, at the top of `report_data`, one `if os.environ.get("BRIEF_SOURCE") ==
"warehouse": ...` branch that calls `brief.warehouse.report_data(bigquery.Client(), today)` and returns it
directly. When `BRIEF_SOURCE` is unset (the default), that `if` is false and `report_data` falls straight
through to the untouched GA4 path below it — behaviour is unchanged. Verified in this session with
`patch --dry-run` against the reference copy of `ga_report.py`, then applied for real to a throwaway copy in a
temp directory and diffed byte-for-byte against the intended result (see `task-15-report.md` for the exact
commands and output) — never against the CMS repo's actual working directory.

## Vendoring `brief/warehouse.py` next to the scripts

The brief runs as a Cloud Run job built from the CMS repo's `scripts/google-ads/` folder, so
`brief/warehouse.py` (plus an empty `brief/__init__.py`) needs to physically exist inside that folder at
build time, as `scripts/google-ads/brief/warehouse.py` — a plain Python package sitting next to
`ga_report.py`, `slack_post.py`, etc. Two ways to get it there, either is fine:

* **Vendor (simplest, no new dependency):** copy `brief/` from this repo into
  `scripts/google-ads/brief/` in the CMS repo, committed alongside the patched `ga_report.py`. Re-copy it
  whenever `brief/warehouse.py` changes here.
* **Install:** add `google-cloud-bigquery>=3.45,<4` (this repo's own pin) to
  `scripts/google-ads/requirements.txt`, and either install this repo as a dependency of the Cloud Run image
  or vendor just the one file as above. There's no packaging metadata in this repo for `brief` today (it's a
  small, single-purpose module, not a published package), so plain vendoring is the lower-friction option
  unless the CMS build already has a mechanism for pulling in sibling-repo code.

Either way, `google-cloud-bigquery` must be importable in that Cloud Run image, since `report_data`'s
warehouse path constructs a `bigquery.Client()`.

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
