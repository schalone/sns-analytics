# Looker Studio — "Sip & Script — Website & Sales"

Step-by-step creation of the report described in the original Task 16 brief and spec §1
("Consumers... Looker Studio dashboards"). Column names below are copied verbatim from
`dbt/models/marts/mart_daily_kpis.sql` and `dbt/models/marts/mart_paid_performance.sql` — check those
files if a mart's columns ever change; this doc will drift otherwise.

**Report URL:** _(paste here once created — not yet created as part of this task; report
creation requires interactive Looker Studio UI access this session does not have. Everything below
is the exact procedure to follow.)_

## 1. Data sources

Go to [Looker Studio](https://lookerstudio.google.com) → **Create** → **Data source** → **BigQuery**
connector, twice:

1. **`mart.mart_daily_kpis`**
   - Project: `sipandscript`, dataset: `mart`, table: `mart_daily_kpis`.
   - Under the data source's sharing settings: **"Viewer's credentials" OFF**, **"Owner's
     credentials" ON** — viewers use your (the report owner's) BigQuery access, so they don't each
     need their own `roles/bigquery.dataViewer` grant on `mart`/`core` (spec §9 already grants that to
     your Google identity; viewers of the report don't need it individually).
   - Columns as defined by the model: `business_date` (DATE), `pre_launch` (BOOLEAN),
     `channel_group` (TEXT), `metro_key` (TEXT, nullable), `sessions` (NUMBER), `engaged_sessions`
     (NUMBER), `orders` (NUMBER), `ticket_orders` (NUMBER), `seats` (NUMBER), `gross_revenue`
     (NUMBER/currency), `net_revenue` (NUMBER/currency), `cvr` (NUMBER/percent, nullable), `aov`
     (NUMBER/currency, nullable), `new_customers` (NUMBER), `unreliable_ga4` (BOOLEAN).
2. **`mart.mart_paid_performance`**
   - Project: `sipandscript`, dataset: `mart`, table: `mart_paid_performance`.
   - Same sharing settings: viewer's credentials off, owner's credentials on.
   - Columns: `date` (DATE), `platform` (TEXT: `google`/`meta`/`pinterest`), `campaign_id` (TEXT,
     nullable — only populated for `google`), `campaign_name` (TEXT), `campaign_name_norm` (TEXT,
     lower/trimmed — join key only, don't surface it), `metro_key` (TEXT, nullable), `spend`
     (NUMBER/currency), `impressions` (NUMBER), `clicks` (NUMBER), `sessions` (NUMBER), `orders`
     (NUMBER), `seats` (NUMBER), `net_revenue` (NUMBER/currency), `roas` (NUMBER, nullable), `cpa`
     (NUMBER/currency, nullable).

Name the report **"Sip & Script — Website & Sales"** when creating it (Create → Report, add both data
sources above).

## 2. CVR — read this before adding the scorecard

`mart_daily_kpis.cvr` is **already a per-row ratio** (`ticket_orders / sessions`, computed with
`safe_divide` in the model, NULL when sessions are 0/absent or `metro_key` is not null or the day is
flagged `unreliable_ga4`). Looker Studio's default aggregation for a NUMBER field is SUM (or whatever
you pick), and **neither SUM nor AVERAGE of the row-level `cvr` values is correct** once you group by
anything other than the exact grain the row already has — e.g. summing `cvr` across a date range adds
percentages together, and averaging it weights every day/channel cell equally regardless of its
session volume.

**Rule for this report: only ever display CVR on a chart/scorecard filtered to `metro_key IS NULL`,
and always as a calculated field `SUM(ticket_orders) / SUM(sessions)`, never `SUM(cvr)` or
`AVG(cvr)`.**

Create the calculated field once, on the `mart_daily_kpis` data source, name it `CVR (calc)`:

```
SUM(ticket_orders) / SUM(sessions)
```

Format it as a percent. Use `CVR (calc)`, not the raw `cvr` column, on every scorecard/chart in this
report. Every chart that uses it must carry a filter `metro_key IS NULL` (metro-level rows in
`mart_daily_kpis` are additional breakout rows for the *same* sessions/orders — including them would
double-count sessions and orders in any aggregate).

## 3. Page 1 — "Overview"

Data source: `mart.mart_daily_kpis`.

1. **Date range control** — top of the page, defaults to a reasonable window (e.g. last 90 days);
   field `business_date`.
2. **Four scorecards**, each with a filter `metro_key IS NULL` (add the filter per-chart, or add one
   page-level filter if the whole page should only ever show the metro-null grain — recommended, since
   every chart on this page uses the non-metro rows):
   - **Sessions** — `SUM(sessions)`.
   - **Ticket orders** — `SUM(ticket_orders)`.
   - **Net revenue** — `SUM(net_revenue)`, currency format.
   - **CVR** — the `CVR (calc)` field from §2, percent format.
3. **Time series chart** — dimension `business_date`, metrics `sessions`, `ticket_orders`,
   `net_revenue` (pick 2-3 to avoid a cluttered dual axis; sessions + ticket orders on one axis, net
   revenue on a second axis works well). Filter `metro_key IS NULL`.
4. **Table by `channel_group`** — dimension `channel_group`, metrics `sessions`, `orders`,
   `ticket_orders`, `net_revenue`, and the `CVR (calc)` field. Filter `metro_key IS NULL` (channel
   breakdowns in this mart are also only meaningful at the non-metro grain — metro rows don't carry
   `channel_group` breakdowns the same way; check current data before assuming otherwise, but the
   model's `grid` construction unions session rows, which never carry a metro, so metro-level rows in
   practice only ever come from the `orders` side and will show as extra `channel_group` values with
   `metro_key` set — the page-level filter above already excludes them).

## 4. Page 2 — "Paid"

Data source: `mart.mart_paid_performance`.

1. **Table by `platform, campaign_name`** — dimensions `platform`, `campaign_name`; metrics `spend`,
   `orders`, `roas`, `cpa` (both already computed ratios in the model — `roas = net_revenue / spend`,
   `cpa = spend / orders`, both NULL rather than 0 when the denominator is 0/absent, which Looker
   Studio will render as blank; that's correct, not a bug). Sort by `spend` descending. Add
   `impressions` and `clicks` as optional extra columns if there's room.
2. **Metro bar chart** — dimension `metro_key`, metrics `spend` and `orders` (dual bars or two
   side-by-side charts). `metro_key` is only populated for Google campaigns matched via
   `campaign_metro_map`/GA4 metro attribution today; expect many rows with `metro_key` null until
   Meta/Pinterest campaign-to-metro mapping is added — that's expected, not a defect, given phase one's
   scope (spec §12: multi-touch attribution is phase two).
3. Optional: a page-level date control on `date`.

Note: while `google_ads_enabled` is `false` (see `docs/runbook.md`) and before the Meta/Pinterest CSV
drop has real files, `mart_paid_performance` has zero rows and this page will be empty — that's
expected, not a report-building error (see `docs/handoff.md` items 6 and 10).

## 5. Share

Share → add the team (email addresses omitted from this doc deliberately — add them directly in the
Looker Studio UI, not in this repo). Since owner's credentials are on for both data sources, viewers
need only be added as viewers/editors of the *report* — no separate BigQuery IAM grant required for
them individually.

Paste the final report URL at the top of this file once created.
