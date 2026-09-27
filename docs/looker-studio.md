# Looker Studio — "Sip & Script — Website & Sales"

Step-by-step creation of the report described in spec §1 ("Consumers... Looker Studio dashboards"). Column
names below are copied from `dbt/models/marts/mart_daily_kpis.sql` and
`dbt/models/marts/mart_paid_performance.sql`; check those files if a mart's columns change.

**Report URL:** _(paste here once created — the report has not been created yet; creating it needs
interactive Looker Studio access.)_

## 1. Data sources

Go to [Looker Studio](https://lookerstudio.google.com) → **Create** → **Data source** → **BigQuery**
connector, twice:

1. **`mart.mart_daily_kpis`**
   - Project `sipandscript`, dataset `mart`, table `mart_daily_kpis`.
   - Sharing: **"Viewer's credentials" OFF**, **"Owner's credentials" ON**, so viewers use the report
     owner's BigQuery access and need no grant of their own.
   - Columns: `business_date` (DATE), `pre_launch` (BOOLEAN), `channel_group` (TEXT), `metro_key` (TEXT,
     nullable), `sessions`, `engaged_sessions`, `orders`, `ticket_orders`, `seats` (NUMBER),
     `gross_revenue`, `net_revenue`, `ticket_net_revenue` (NUMBER, currency), `channel_ticket_orders`
     (NUMBER, NULL on metro rows), `cvr` (NUMBER, nullable), `aov` (NUMBER, currency, nullable),
     `new_customers` (NUMBER), `unreliable_ga4` (BOOLEAN).
2. **`mart.mart_paid_performance`**
   - Project `sipandscript`, dataset `mart`, table `mart_paid_performance`; same sharing settings.
   - Columns: `date` (DATE), `platform` (TEXT: `google`/`meta`/`pinterest`), `campaign_id` (TEXT, only for
     `google`), `campaign_name` (TEXT), `campaign_name_norm` (TEXT, join key only — don't surface it),
     `metro_key` (TEXT, nullable), `spend` (currency), `impressions`, `clicks`, `sessions`, `orders`,
     `seats` (NUMBER), `net_revenue` (currency), `roas` (NUMBER, nullable), `cpa` (currency, nullable).

Name the report **"Sip & Script — Website & Sales"** (Create → Report, add both data sources).

## 2. How `mart_daily_kpis` rows add up — read this first

One row per `business_date` × `pre_launch` × `channel_group` × `metro_key`.

- **Orders, ticket orders, seats, gross/net revenue, ticket net revenue and new customers** sit on exactly
  one row each: the row of the order's metro (its event's metro, else its billing zip's metro), or the
  `metro_key IS NULL` row when it has none. **Sum them over ALL rows.** Never filter a chart that shows
  orders or revenue to `metro_key IS NULL`: once orders carry metros that silently drops them.
- **Sessions and engaged sessions** sit only on `metro_key IS NULL` rows (GA4 has no metro). Summing them
  over all rows gives the same answer as summing the null-metro rows.
- **CVR** must use the per-channel total of ticket orders, not the null-metro row's own `ticket_orders`.
  That total is `channel_ticket_orders`: the ticket orders of the date, `pre_launch` and channel summed
  over **all** metro values, carried on the null-metro row and NULL on metro rows. So over any set of rows,
  `SUM(channel_ticket_orders) / SUM(sessions)` is the CVR of the null-metro rows — the correct one — with
  no filter needed.

Create these calculated fields once, on the `mart_daily_kpis` data source:

| Field name | Formula | Format |
|---|---|---|
| `CVR (calc)` | `SUM(channel_ticket_orders) / SUM(sessions)` | percent |
| `AOV (calc)` | `SUM(ticket_net_revenue) / SUM(ticket_orders)` | currency |

Never display `SUM(cvr)`, `AVG(cvr)` or `AVG(aov)`: the stored `cvr`/`aov` are per-row ratios and do not
aggregate. `cvr` is also NULL on dates flagged `unreliable_ga4` (the 2026-06-19..22 GA4 cutover blackout);
exclude those dates from CVR charts with a filter `unreliable_ga4 = false`, or show the flag next to them.
CVR by metro is not defined (sessions carry no metro).

## 3. Page 1 — "Overview"

Data source: `mart.mart_daily_kpis`. **No page-level `metro_key` filter.**

1. **Date range control** on `business_date` (e.g. last 90 days).
2. **Scorecards:** Sessions `SUM(sessions)`; Ticket orders `SUM(ticket_orders)`; Net revenue
   `SUM(net_revenue)` (currency); CVR `CVR (calc)` with a chart filter `unreliable_ga4 = false`; AOV
   `AOV (calc)`.
3. **Time series** — dimension `business_date`; metrics `sessions` and `ticket_orders` on one axis,
   `net_revenue` on a second axis.
4. **Table by `channel_group`** — metrics `sessions`, `orders`, `ticket_orders`, `net_revenue`,
   `CVR (calc)`. All rows, no metro filter. `Unattributed` holds orders with no GA4 session (it has no
   sessions, so its CVR is blank); `Other` holds sessions whose source/medium match no channel rule.
5. Optional **table by `metro_key`** — metrics `orders`, `ticket_orders`, `seats`, `net_revenue` only
   (no sessions, no CVR). The blank `metro_key` row is orders with no metro.

## 4. Page 2 — "Paid"

Data source: `mart.mart_paid_performance`.

1. **Table by `platform, campaign_name`** — metrics `spend`, `orders`, `roas`, `cpa` (per-row ratios,
   NULL when the denominator is 0; show them per campaign-day row only, or add calculated fields
   `SUM(net_revenue) / SUM(spend)` and `SUM(spend) / SUM(orders)` for totals). Sort by `spend` descending;
   add `impressions` and `clicks` if there is room.
2. **Metro bar chart** — dimension `metro_key`, metrics `spend` and `orders`. Many rows have no metro until
   campaign-to-metro mapping (`campaign_metro_map` seed) covers every campaign; expected in phase one.
3. Optional page-level date control on `date`.

While `google_ads_enabled` is `false` and before the first Meta/Pinterest CSV drop, `mart_paid_performance`
has zero rows and this page is empty (see `docs/handoff.md` items 6 and 10).

## 5. Share

Share → add the team in the Looker Studio UI (addresses deliberately not recorded here). With owner's
credentials on both data sources, viewers need only access to the report.

Paste the final report URL at the top of this file once created.
