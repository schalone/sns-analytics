"""Warehouse-backed data for the morning brief.

Replaces the GA4 Data API path in the reference implementation (`ga_report.py`, in the CMS repo that runs the
brief) with queries against this pipeline's BigQuery marts. `report_data(bq, today)` returns the exact same
structure as `ga_report.report_data(key_file, today)`:

    {
        "text": str,                                   # human-readable brief body
        "fields": [(label: str, value: str), ...],      # exactly 5 pairs, in order:
                                                         # Sessions, Orders, Revenue, Conversion rate, Avg order
        "flags": [str, ...],                            # zero or more warning lines (drops, zero-order days)
        "series": [(date, sessions: int, orders: int), ...],  # 28 days ending yesterday, zero-filled
        "when": date,                                   # yesterday's date
    }

`bq` is a `google.cloud.bigquery.Client`. Every query below binds its date (and limit) arguments as BigQuery
query parameters -- never as interpolated string literals -- so this module has no SQL-injection surface and
no per-day query-plan cache miss from literal-valued queries.

Known approximations versus the GA4 version (documented here, not hidden in the numbers):

* **"users" is reported as sessions.** GA4's `totalUsers` is a cross-session, cross-device identity count with
  no warehouse equivalent in phase one (no persistent visitor identity table). `headline_dict` sets
  `"users"` equal to `"sessions"` so the dict shape matches; nothing downstream (`fields`, `flags`, `text`)
  ever surfaces the GA4 report's "users" figure either, so this has no visible effect on the brief's output.
* **"orders" means ticket orders, "revenue" means net revenue.** `ticket_orders` (ticket sales only, excludes
  gift cards and other order types) is this pipeline's closest analogue to GA4's deduplicated
  `ecommercePurchases` count; `net_revenue` (gross less refunds) is the closest analogue to GA4's
  `purchaseRevenue`. Average order value divides ticket orders' net revenue (`ticket_net_revenue`) by ticket
  orders, so numerator and denominator are the same population. All are already deduplicated by the dbt models that build `core_orders` /
  `core_session_orders` (one row per `order_key`), so there is no need to replicate the GA4 version's own
  transaction-id dedup logic here.
* **Sessions include phantom-referral sessions.** GA4's `accounts.google.com` phantom referral is excluded
  outright from the GA4 version's session/channel/landing counts. `core_sessions` instead *re-attributes*
  phantom sessions (that sign-in, and the Stripe Checkout return from `checkout.stripe.com` / `*.stripe.com`)
  to the inherited prior source, else Direct, at the model layer (see `core_sessions.sql`) rather than
  dropping them, so warehouse-sourced session totals and channel splits will not match the GA4 version
  exactly even once orders are flowing (see `brief/README.md`).
* **`platform_era` is never referenced.** That mart column was renamed from `pre_launch`; every query
  here sums across all rows regardless of that column, so it was unaffected by the rename.
* **`metro_key` is never filtered on for totals.** Every session row in `mart_daily_kpis` carries
  `metro_key IS NULL`, and metro rows carry orders/revenue only (see `mart_daily_kpis.sql`). Summing every
  row of a date range therefore yields that range's true totals without double-counting or dropping
  metro-attributed orders; filtering to `metro_key IS NULL` would silently undercount orders and revenue.
  (`landing()` has no `metro_key` at all -- it reads `core_sessions` directly, which carries no metro
  attribution.)
* **`unreliable_ga4` windows report CVR as unavailable, not a number.** `mart_daily_kpis.unreliable_ga4`
  flags the 2026-06-19..22 GA4 cutover blackout (`date_flags` seed) by forcing that date's own `cvr` to NULL
  at the mart layer. `headline_dict` rolls up `logical_or(unreliable_ga4)` for its window and, when true,
  every place this module renders a CVR for that window (the "CVR ..." segment of `_headline`'s text and the
  "Conversion rate" row of `_headline_fields`) shows `"n/a"` instead of a computed percentage -- mirroring
  how the GA4 version's own `pct()` already renders an unavailable comparison as `"n/a"`. Sessions, orders and
  revenue are still shown as normal even when a window is flagged (only CVR is undefined by construction; the
  other three are real counts, not ratios). A window flagged this way also adds
  `"⚠ window includes dates with unreliable GA4 tracking — sessions and CVR not comparable"` to `flags()`.
  `daily_series` deliberately does **not** consult this flag -- its per-day sessions/orders feed the brief's
  chart, which shows what was actually recorded for every day regardless of tracking reliability.
"""
from __future__ import annotations

import datetime as dt

from google.cloud import bigquery

PROJECT = "sipandscript"

# Final-review I11: "Other" (sessions whose source/medium match no rule) and "Unattributed" (orders with no GA4
# session) are listed too, so the channel lines always add up to the headline.
CHANNELS = ["Organic Search", "Paid Search", "Paid Social", "Organic Social", "Direct", "Email", "Referral", "Other", "Unattributed"]
DROP_FLAG = 0.25          # flag a headline metric down more than 25%, matching ga_report.py's DROP_FLAG


# --------------------------------------------------------------------------------- query helpers ---
def _rows(bq, sql, **params):
    """Run `sql` against `bq` with `params` bound as query parameters (DATE for date values, INT64 for ints)
    and return the result as a list of plain dicts."""
    query_parameters = []
    for name, value in params.items():
        if isinstance(value, dt.date):
            query_parameters.append(bigquery.ScalarQueryParameter(name, "DATE", value))
        elif isinstance(value, int):
            query_parameters.append(bigquery.ScalarQueryParameter(name, "INT64", value))
        else:
            raise TypeError(f"unsupported query parameter type for {name!r}: {type(value)!r}")
    cfg = bigquery.QueryJobConfig(query_parameters=query_parameters)
    return [dict(r) for r in bq.query(sql, job_config=cfg).result()]


# --------------------------------------------------------------------------------- data functions ---
def headline_dict(bq, start, end):
    """{"sessions", "users", "purchases", "revenue", "ticket_revenue", "unreliable_ga4"} totalled over [start, end]
    inclusive. "revenue" is net revenue of every order; "ticket_revenue" is ticket orders' net revenue (the AOV
    numerator, same population as "purchases").

    Sums across every channel_group/metro_key row for the range: session rows always carry
    `metro_key IS NULL` and metro rows carry orders/revenue only, so summing every row (not just
    `metro_key IS NULL` rows) gives the range's true totals without dropping metro-attributed orders.

    `unreliable_ga4` is `logical_or(unreliable_ga4)` across every day in the range -- true if *any* day in
    this window is flagged (the mart's own `cvr` is NULL on those days for the same reason). Callers must not
    render a CVR for a window where this is true (see this module's docstring)."""
    rows = _rows(bq, f"""
      select sum(sessions) as sessions, sum(ticket_orders) as purchases, sum(net_revenue) as revenue,
        sum(ticket_net_revenue) as ticket_revenue, logical_or(unreliable_ga4) as unreliable_ga4
      from `{PROJECT}.mart.mart_daily_kpis`
      where business_date between @start_date and @end_date
    """, start_date=start, end_date=end)
    r = rows[0] if rows else {}
    sessions = r.get("sessions") or 0
    return {"sessions": sessions, "users": sessions, "purchases": r.get("purchases") or 0,
            "revenue": r.get("revenue") or 0, "ticket_revenue": r.get("ticket_revenue") or 0,
            "unreliable_ga4": bool(r.get("unreliable_ga4"))}


def channels(bq, start, end):
    """{channel_name: (sessions, purchases, revenue)} over [start, end] inclusive, one entry for every name in
    `CHANNELS` (zero-filled if absent from the query result). The set includes "Other" and "Unattributed"
    (orders with no GA4 session), so the channel lines add up to the headline; any other `channel_group` the
    mart might grow is still dropped.

    No `metro_key` filter, for the same reason as `headline_dict`: session rows (the only rows with sessions)
    always carry `metro_key IS NULL`, and every order row -- metro-attributed or not -- must be counted once."""
    rows = _rows(bq, f"""
      select channel_group, sum(sessions) as sessions, sum(ticket_orders) as purchases, sum(net_revenue) as revenue
      from `{PROJECT}.mart.mart_daily_kpis`
      where business_date between @start_date and @end_date
      group by 1
    """, start_date=start, end_date=end)
    out = {c: (0, 0, 0.0) for c in CHANNELS}
    for r in rows:
        name = r.get("channel_group")
        if name in out:
            out[name] = (r.get("sessions") or 0, r.get("purchases") or 0, r.get("revenue") or 0)
    return out


def landing(bq, start, end, limit=10):
    """[(page, sessions, purchases)] for the top `limit` landing pages by session count over [start, end]
    inclusive, ordered by sessions descending.

    Reads `core_sessions` / `core_session_orders` / `core_orders` directly -- `mart_daily_kpis` has no
    landing-page dimension, and this is a genuinely per-session computation, so there is no `metro_key` in
    scope at all here. Joined through to `core_orders` and filtered to `order_type = 'ticket'` so "purchases"
    means the same thing (ticket orders) here as it does everywhere else in this module -- without that join,
    a gift-card or other non-ticket order linked to a session would inflate this count relative to the
    ticket-order totals shown elsewhere in the same brief.

    Both measures are `count(distinct ...)`, never `count(*)`: `core_session_orders` holds one row per
    *order*, so a session that produced more than one order joins to more than one row here, and `count(*)`
    would count that single session once per order it produced (fan-out). `count(distinct s.session_key)`
    counts the session once regardless of how many orders it joins to; `count(distinct ... order_key ...)`
    counts each ticket order once regardless of which of a session's joined rows it appears on."""
    rows = _rows(bq, f"""
      select s.landing_page_path as page, count(distinct s.session_key) as sessions,
        count(distinct case when o.order_type = 'ticket' then so.order_key end) as purchases
      from `{PROJECT}.core.core_sessions` s
      left join `{PROJECT}.core.core_session_orders` so using (session_key)
      left join `{PROJECT}.core.core_orders` o using (order_key)
      where s.session_date between @start_date and @end_date
      group by 1
      order by sessions desc
      limit @limit_n
    """, start_date=start, end_date=end, limit_n=limit)
    return [(r["page"], r["sessions"], r["purchases"]) for r in rows]


def daily_series(bq, today, days=28):
    """[(date, sessions, orders)] for the `days` days ending yesterday, zero-filled for any day with no
    matching row (a day with zero activity, or a gap in the mart)."""
    end = today - dt.timedelta(days=1)
    start = end - dt.timedelta(days=days - 1)
    rows = _rows(bq, f"""
      select business_date as d, sum(sessions) as sessions, sum(ticket_orders) as orders
      from `{PROJECT}.mart.mart_daily_kpis`
      where business_date between @start_date and @end_date
      group by 1
    """, start_date=start, end_date=end)
    by_day = {r["d"]: r for r in rows}
    out = []
    for i in range(days):
        d = start + dt.timedelta(days=i)
        r = by_day.get(d, {})
        out.append((d, r.get("sessions", 0) or 0, r.get("orders", 0) or 0))
    return out


# --------------------------------------------------------------------------------- text (ported from ga_report.py) ---
# Copied from .superpowers/sdd/2026-09-26-analytics-pipeline/brief-ref/ga_report.py (functions pct/headline/
# headline_fields/flags/build_text), so `report_data`'s "fields"/"flags"/"text" shapes match key by key. They
# are re-implemented here, not imported from ga_report.py, so this module has no import-time dependency on a
# module that lives in a different repository and is only vendored alongside it at deploy time (see
# brief/README.md). If that reference file's wording, thresholds (e.g. DROP_FLAG) or field labels change,
# these must be manually re-synced -- there is no shared import to keep them honest.
def _pct(cur, prev):
    if not prev:
        return "n/a" if not cur else "new"
    d = (cur - prev) / prev
    return f"{d:+.0%}"


def _money(x):
    return f"${x:,.0f}"


def _cvr_str(d):
    """CVR as a formatted percentage, or "n/a" (matching `_pct`'s own convention for an unavailable
    comparison) when `d`'s window includes a date the mart flags `unreliable_ga4` -- the mart itself reports
    that day's `cvr` as NULL, so a ratio computed from this window's sessions/purchases would be misleading,
    not just imprecise."""
    if d.get("unreliable_ga4"):
        return "n/a"
    cvr = d["purchases"] / d["sessions"] if d["sessions"] else 0
    return f"{cvr:.2%}"


def _aov(d):
    """Average ticket order value: ticket orders' net revenue / ticket orders, so numerator and denominator are
    the same population (the headline "revenue" also includes gift-card and other orders)."""
    return d.get("ticket_revenue", 0) / d["purchases"] if d["purchases"] else 0


def _headline(cur, prev):
    aov = _aov
    parts = [f"{cur['sessions']:,} sessions ({_pct(cur['sessions'], prev['sessions'])})",
              f"{cur['purchases']} orders ({_pct(cur['purchases'], prev['purchases'])})",
              f"{_money(cur['revenue'])} ({_pct(cur['revenue'], prev['revenue'])})",
              f"CVR {_cvr_str(cur)} (was {_cvr_str(prev)})", f"AOV {_money(aov(cur))} (was {_money(aov(prev))})"]
    return " · ".join(parts)


def _headline_fields(cur, prev):
    aov = _aov
    return [("Sessions", f"{cur['sessions']:,} ({_pct(cur['sessions'], prev['sessions'])})"),
            ("Orders", f"{cur['purchases']} ({_pct(cur['purchases'], prev['purchases'])})"),
            ("Revenue", f"{_money(cur['revenue'])} ({_pct(cur['revenue'], prev['revenue'])})"),
            ("Conversion rate", f"{_cvr_str(cur)} (was {_cvr_str(prev)})"),
            ("Avg order", f"{_money(aov(cur))} (was {_money(aov(prev))})")]


def _flags(cur, prev):
    out = []
    for k, label in (("sessions", "sessions"), ("purchases", "orders"), ("revenue", "revenue")):
        if prev[k] and cur[k] < prev[k] * (1 - DROP_FLAG):
            out.append(f"⚠ {label} down {_pct(cur[k], prev[k])} vs comparison")
    if cur["sessions"] >= 200 and cur["purchases"] == 0:
        out.append("⚠ zero orders despite traffic — check purchase tracking")
    if cur.get("unreliable_ga4") or prev.get("unreliable_ga4"):
        out.append("⚠ window includes dates with unreliable GA4 tracking — sessions and CVR not comparable")
    return out


def _build_text(y, wk, channel_rows, landing_rows, when):
    lines = [f"*Sip & Script website daily — {when:%a %b %d}* (warehouse; orders = ticket orders, revenue = net revenue)",
             f"Yesterday vs same weekday last week: {_headline(*y)}",
             f"Last 7 days vs prior 7: {_headline(*wk)}"]
    lines += _flags(*y)
    ch = [f"{n}: {s:,} sess · {p} orders · {_money(r)}" for n, (s, p, r) in channel_rows.items() if s or p]
    if ch:
        lines.append("*Yesterday by channel:* " + "; ".join(ch))
    if landing_rows:
        lines.append("*Top landing pages yesterday:* " + "; ".join(f"{pg} ({s} sess, {p} orders)" for pg, s, p in landing_rows))
    return "\n".join(lines)


# --------------------------------------------------------------------------------- entry point ---
def report_data(bq, today=None):
    """Everything the brief needs: text, headline fields, flags, daily series -- same shape as
    `ga_report.report_data(key_file, today)` (see this module's docstring)."""
    if today is None:
        import zoneinfo
        today = dt.datetime.now(zoneinfo.ZoneInfo("America/New_York")).date()

    y_cur_date = today - dt.timedelta(days=1)
    y_prev_date = y_cur_date - dt.timedelta(days=7)          # same weekday last week
    wk_cur_start, wk_cur_end = y_cur_date - dt.timedelta(days=6), y_cur_date
    wk_prev_start, wk_prev_end = y_cur_date - dt.timedelta(days=13), y_cur_date - dt.timedelta(days=7)

    y = (headline_dict(bq, y_cur_date, y_cur_date), headline_dict(bq, y_prev_date, y_prev_date))
    wk = (headline_dict(bq, wk_cur_start, wk_cur_end), headline_dict(bq, wk_prev_start, wk_prev_end))
    ch = channels(bq, y_cur_date, y_cur_date)
    lp = landing(bq, y_cur_date, y_cur_date, limit=8)          # 8, matching the GA4 version's top-landing-page cap
    series = daily_series(bq, today, days=28)

    return {
        "text": _build_text(y, wk, ch, lp, y_cur_date),
        "fields": _headline_fields(*y),
        "flags": _flags(*y),
        "series": series,
        "when": y_cur_date,
    }
