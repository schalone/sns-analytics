"""Daily GA4 website report for #analytics. Read-only. Purchases = DISTINCT transaction IDs (GA4's own purchase
count double-fires ~10%); revenue deduped the same way. Sessions exclude the phantom accounts.google.com referral.
Compares yesterday with the same weekday last week, and the last 7 days with the prior 7."""
import datetime as dt, collections, os

PROPERTY = "properties/313669961"
CHANNELS = ["Organic Search", "Paid Search", "Paid Social", "Organic Social", "Direct", "Email", "Referral"]
DROP_FLAG = 0.25          # flag a headline metric down more than 25%
PHANTOM_SOURCE = "accounts.google.com"
# Landing "pages" that are known tracking noise, not places visitors arrive (investigated 2026-10-02): blank /
# "(not set)" are timeout sessions with no page_view and no orders; /order-confirmation landings are buyers
# reopening their ticket page (plus a few in-app-browser Stripe returns that the CMS ga_cid passthrough now repairs).
NOISE_LANDING = ("", "(not set)")
NOISE_LANDING_PREFIX = "/order-confirmation"


# ------------------------------------------------------------ pure ---
def is_noise_landing(page):
    page = (page or "").strip()
    return page in NOISE_LANDING or page.startswith(NOISE_LANDING_PREFIX)


def dedupe(rows):
    """rows: [(key_tuple, transaction_id, events, revenue)] -> {key_tuple: (purchases, revenue)} counting each
    transaction id once per key and dividing its revenue by how many times it fired."""
    out = collections.defaultdict(lambda: [0, 0.0]); seen = set()
    for key, tid, events, revenue in rows:
        if not tid or tid in ("(not set)", "(other)") or (key, tid) in seen: continue
        seen.add((key, tid)); out[key][0] += 1; out[key][1] += revenue / max(events, 1)
    return {k: (v[0], v[1]) for k, v in out.items()}


def pct(cur, prev):
    if not prev: return "n/a" if not cur else "new"
    d = (cur - prev) / prev; return f"{d:+.0%}"


def money(x): return f"${x:,.0f}"


def headline(cur, prev):
    """cur/prev: dict sessions, users, purchases, revenue."""
    cvr = lambda d: d["purchases"] / d["sessions"] if d["sessions"] else 0
    aov = lambda d: d["revenue"] / d["purchases"] if d["purchases"] else 0
    parts = [f"{cur['sessions']:,} sessions ({pct(cur['sessions'], prev['sessions'])})",
             f"{cur['purchases']} orders ({pct(cur['purchases'], prev['purchases'])})",
             f"{money(cur['revenue'])} ({pct(cur['revenue'], prev['revenue'])})",
             f"CVR {cvr(cur):.2%} (was {cvr(prev):.2%})", f"AOV {money(aov(cur))} (was {money(aov(prev))})"]
    return " · ".join(parts)


def headline_fields(cur, prev):
    cvr = lambda d: d["purchases"] / d["sessions"] if d["sessions"] else 0
    aov = lambda d: d["revenue"] / d["purchases"] if d["purchases"] else 0
    return [("Sessions", f"{cur['sessions']:,} ({pct(cur['sessions'], prev['sessions'])})"),
            ("Orders", f"{cur['purchases']} ({pct(cur['purchases'], prev['purchases'])})"),
            ("Revenue", f"{money(cur['revenue'])} ({pct(cur['revenue'], prev['revenue'])})"),
            ("Conversion rate", f"{cvr(cur):.2%} (was {cvr(prev):.2%})"),
            ("Avg order", f"{money(aov(cur))} (was {money(aov(prev))})")]


def daily_series(ga, today, days=28):
    """[(date, sessions, orders)] for the `days` days ending yesterday; orders = distinct transaction ids per day."""
    y = today - dt.timedelta(days=1); a = y - dt.timedelta(days=days - 1)
    dr = [{"startDate": f"{a:%Y-%m-%d}", "endDate": f"{y:%Y-%m-%d}"}]
    sess = {r["dimensionValues"][0]["value"]: int(r["metricValues"][0]["value"]) for r in ga.run(
        {"dateRanges": dr, "dimensions": [{"name": "date"}], "metrics": [{"name": "sessions"}], "dimensionFilter": {"notExpression": _not_phantom()}, "limit": 1000})}
    rows = [((r["dimensionValues"][0]["value"],), r["dimensionValues"][1]["value"], int(r["metricValues"][0]["value"]), 0.0) for r in ga.run(
        {"dateRanges": dr, "dimensions": [{"name": "date"}, {"name": "transactionId"}], "metrics": [{"name": "ecommercePurchases"}], "limit": 100000})]
    orders = {k[0]: v[0] for k, v in dedupe(rows).items()}
    out = []
    for i in range(days):
        d = a + dt.timedelta(days=i); k = f"{d:%Y%m%d}"; out.append((d, sess.get(k, 0), orders.get(k, 0)))
    return out


def flags(cur, prev):
    out = []
    for k, label in (("sessions", "sessions"), ("purchases", "orders"), ("revenue", "revenue")):
        if prev[k] and cur[k] < prev[k] * (1 - DROP_FLAG): out.append(f"⚠ {label} down {pct(cur[k], prev[k])} vs comparison")
    if cur["sessions"] >= 200 and cur["purchases"] == 0: out.append("⚠ zero orders despite traffic — check purchase tracking")
    return out


def build_text(y, wk, channels, landing, when):
    """y/wk: (cur, prev) headline dicts; channels: {name: (sessions, purchases, revenue)}; landing: [(page, sessions, purchases)]."""
    lines = [f"*Sip & Script website daily — {when:%a %b %d}* (GA4; orders = unique transaction IDs)",
             f"Yesterday vs same weekday last week: {headline(*y)}",
             f"Last 7 days vs prior 7: {headline(*wk)}"]
    lines += flags(*y)
    ch = [f"{n}: {s:,} sess · {p} orders · {money(r)}" for n, (s, p, r) in channels.items() if s or p]
    if ch: lines.append("*Yesterday by channel:* " + "; ".join(ch))
    if landing: lines.append("*Top landing pages yesterday:* " + "; ".join(f"{pg} ({s} sess, {p} orders)" for pg, s, p in landing))
    return "\n".join(lines)


# ------------------------------------------------------------ GA4 ---
class GA:
    def __init__(self, key_file=None):
        import google.auth, google.auth.transport.requests, requests
        scopes = ["https://www.googleapis.com/auth/analytics.readonly"]
        if key_file:
            from google.oauth2 import service_account
            self.creds = service_account.Credentials.from_service_account_file(key_file, scopes=scopes)
        else:
            self.creds, _ = google.auth.default(scopes=scopes)
        self.creds.refresh(google.auth.transport.requests.Request()); self.http = requests
    def run(self, body):
        r = self.http.post(f"https://analyticsdata.googleapis.com/v1beta/{PROPERTY}:runReport", json=body, timeout=60,
                           headers={"Authorization": f"Bearer {self.creds.token}"})
        r.raise_for_status(); return r.json().get("rows", [])


def _not_phantom():
    return {"filter": {"fieldName": "sessionSource", "stringFilter": {"matchType": "EXACT", "value": PHANTOM_SOURCE}}, }


def fetch(ga, today):
    y = today - dt.timedelta(days=1); ylw = y - dt.timedelta(days=7)
    ranges = {"y": (y, y), "ylw": (ylw, ylw), "wk": (y - dt.timedelta(days=6), y), "pwk": (y - dt.timedelta(days=13), y - dt.timedelta(days=7))}
    dr = [{"startDate": f"{a:%Y-%m-%d}", "endDate": f"{b:%Y-%m-%d}", "name": n} for n, (a, b) in ranges.items()]
    not_phantom = {"notExpression": _not_phantom()}
    # traffic per range (phantom referral excluded)
    tot = {n: {"sessions": 0, "users": 0, "purchases": 0, "revenue": 0.0} for n in ranges}
    for r in ga.run({"dateRanges": dr, "metrics": [{"name": "sessions"}, {"name": "totalUsers"}], "dimensionFilter": not_phantom}):
        n = r["dimensionValues"][0]["value"]; tot[n]["sessions"] = int(r["metricValues"][0]["value"]); tot[n]["users"] = int(r["metricValues"][1]["value"])
    # purchases per range, deduped by transaction id
    # one call per range: with several dateRanges plus a transactionId dimension GA4 returns the same rows for
    # every range with summed metrics (verified 2026-09-25), so never combine them
    for n, (a, b) in ranges.items():
        rows = [((n,), r["dimensionValues"][0]["value"], int(r["metricValues"][0]["value"]), float(r["metricValues"][1]["value"]))
                for r in ga.run({"dateRanges": [{"startDate": f"{a:%Y-%m-%d}", "endDate": f"{b:%Y-%m-%d}"}], "dimensions": [{"name": "transactionId"}], "metrics": [{"name": "ecommercePurchases"}, {"name": "purchaseRevenue"}], "limit": 100000})]
        for _, (p, rev) in dedupe(rows).items(): tot[n]["purchases"] = p; tot[n]["revenue"] = rev
    # yesterday by channel
    ydr = [{"startDate": f"{y:%Y-%m-%d}", "endDate": f"{y:%Y-%m-%d}"}]
    ch = {c: [0, 0, 0.0] for c in CHANNELS}
    for r in ga.run({"dateRanges": ydr, "dimensions": [{"name": "sessionDefaultChannelGroup"}], "metrics": [{"name": "sessions"}], "dimensionFilter": not_phantom}):
        c = r["dimensionValues"][0]["value"]
        if c in ch: ch[c][0] = int(r["metricValues"][0]["value"])
    rows = [((r["dimensionValues"][0]["value"],), r["dimensionValues"][1]["value"], int(r["metricValues"][0]["value"]), float(r["metricValues"][1]["value"]))
            for r in ga.run({"dateRanges": ydr, "dimensions": [{"name": "sessionDefaultChannelGroup"}, {"name": "transactionId"}], "metrics": [{"name": "ecommercePurchases"}, {"name": "purchaseRevenue"}], "limit": 100000})]
    for (c,), (p, rev) in dedupe(rows).items():
        if c in ch: ch[c][1] = p; ch[c][2] = rev
    # top landing pages yesterday
    lp = {}
    for r in ga.run({"dateRanges": ydr, "dimensions": [{"name": "landingPage"}], "metrics": [{"name": "sessions"}], "dimensionFilter": not_phantom, "orderBys": [{"metric": {"metricName": "sessions"}, "desc": True}], "limit": 12}):
        pg = r["dimensionValues"][0]["value"]
        if not is_noise_landing(pg) and len(lp) < 8: lp[pg] = [int(r["metricValues"][0]["value"]), 0]
    rows = [((r["dimensionValues"][0]["value"],), r["dimensionValues"][1]["value"], int(r["metricValues"][0]["value"]), 0.0)
            for r in ga.run({"dateRanges": ydr, "dimensions": [{"name": "landingPage"}, {"name": "transactionId"}], "metrics": [{"name": "ecommercePurchases"}], "limit": 100000})]
    for (pg,), (p, _) in dedupe(rows).items():
        if pg in lp: lp[pg][1] = p
    landing = [(pg, s, p) for pg, (s, p) in lp.items()]
    return (tot["y"], tot["ylw"]), (tot["wk"], tot["pwk"]), {c: tuple(v) for c, v in ch.items()}, landing, y


def report(key_file=None, today=None, ga=None):
    import zoneinfo
    today = today or dt.datetime.now(zoneinfo.ZoneInfo("America/New_York")).date()
    y, wk, channels, landing, when = fetch(ga or GA(key_file), today)
    return build_text(y, wk, channels, landing, when)


def report_data(key_file=None, today=None):
    """Everything the brief needs: text, headline fields, flags, daily series."""
    import zoneinfo
    today = today or dt.datetime.now(zoneinfo.ZoneInfo("America/New_York")).date()
    if os.environ.get("BRIEF_SOURCE") == "warehouse":
        # Warehouse-backed numbers (BigQuery marts) — see brief/README.md for the preconditions before enabling.
        from brief.warehouse import report_data as warehouse_report_data
        from google.cloud import bigquery
        return warehouse_report_data(bigquery.Client(), today)
    ga = GA(key_file); y, wk, channels, landing, when = fetch(ga, today)
    return {"text": build_text(y, wk, channels, landing, when), "fields": headline_fields(*y), "flags": flags(*y),
            "series": daily_series(ga, today), "when": when}
