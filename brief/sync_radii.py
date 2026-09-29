#!/usr/bin/env python3
"""Weekly Google Ads radius sync for Sip & Script search campaigns.

Reads the live account (metro campaigns + the "Rest of US" campaign's radii), pulls the upcoming
in-person class inventory from the public site API, and applies fixed rules:

  * Rest of US radius with 0 bookable classes            -> radius removed
  * cluster of bookable classes not inside any radius     -> new radius added (40 mi)
  * Rest of US radius reaching into a metro campaign's circle -> trimmed to touch it (floor 10 mi); removed if its
    centre is inside the circle (the metro campaign, with its metro landing page, owns that area)
  * metro campaign with 0 bookable classes in its radius  -> campaign paused (labelled sync:paused)
  * sync-paused metro campaign with >= 1 class            -> campaign re-enabled
  * any radius/metro with >= PROMOTE_AT classes for PROMOTE_WEEKS straight runs -> flagged for a metro page

State (snapshots + streaks) lives in a GCS bucket (or a local dir with --state-dir).
Usage:
  sync_radii.py --dry-run [--state-dir DIR]     # plan only
  sync_radii.py --apply   [--state-dir DIR]     # mutate + notify
  sync_radii.py --report                        # daily Ads performance summary -> Slack (no mutations)
  sync_radii.py --ga-report                     # daily GA4 website summary -> Slack (see ga_report.py)
  sync_radii.py --brief                         # morning brief: AI narrative + website + ads in ONE message
Env: GOOGLE_ADS_CONFIG (yaml path; default ADC), SLACK_WEBHOOK_URL (optional), STATE_BUCKET (default sns-ads-sync).
"""
import argparse, datetime as dt, json, math, os, sys, time, urllib.request, urllib.parse

CID = "1863952460"
SITE = "https://www.sipandscript.com"
REST_CAMPAIGN = "SNS | Search | Near Me | Rest of US"
METRO_PREFIX = "SNS | Search | Near Me | "
ADD_AT = 1            # classes needed to add / keep a Rest of US radius, or re-enable a metro campaign
DROP_AT = 0           # remove a radius / pause a metro campaign at this count
PROMOTE_AT = 13
PROMOTE_WEEKS = 4
NEW_RADIUS_MILES = 40.0
MIN_RADIUS_MILES = 10.0    # floor for a radius trimmed to stay out of a metro campaign's circle
MAX_INVENTORY_DROP = 0.5   # refuse to apply if bookable classes fell by more than this vs the previous run
MIN_INVENTORY = 100        # or if the count is implausibly small (API shape change / outage)
PAUSED_LABEL = "sync:paused"
STATES = ["Alabama","Alaska","Arizona","Arkansas","California","Colorado","Connecticut","Delaware","District of Columbia","Florida","Georgia","Hawaii","Idaho","Illinois","Indiana","Iowa","Kansas","Kentucky","Louisiana","Maine","Maryland","Massachusetts","Michigan","Minnesota","Mississippi","Missouri","Montana","Nebraska","Nevada","New Hampshire","New Jersey","New Mexico","New York","North Carolina","North Dakota","Ohio","Oklahoma","Oregon","Pennsylvania","Rhode Island","South Carolina","South Dakota","Tennessee","Texas","Utah","Vermont","Virginia","Washington","West Virginia","Wisconsin","Wyoming"]


# ------------------------------------------------------------ pure logic ---
def haversine_miles(lat1, lng1, lat2, lng2):
    r = 3958.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def count_within(classes, lat, lng, miles):
    return sum(1 for c in classes if haversine_miles(lat, lng, c["lat"], c["lng"]) <= miles)


def uncovered(classes, radii):
    """Classes not inside any (lat, lng, miles) radius."""
    return [c for c in classes if not any(haversine_miles(c["lat"], c["lng"], la, ln, ) <= mi for la, ln, mi in radii)]


def allowed_miles(lat, lng, metros, miles=NEW_RADIUS_MILES):
    """Largest radius (at most `miles`, at least MIN_RADIUS_MILES) centred here that stops where the nearest metro
    circle starts. None when the centre itself is inside a metro circle."""
    gap = min((haversine_miles(lat, lng, m["lat"], m["lng"]) - m["miles"] for m in metros), default=miles)
    if gap <= 0: return None
    return round(max(MIN_RADIUS_MILES, min(miles, gap)), 1)


def name_radius(classes, r):
    """Google does not persist an address on a proximity criterion, so name a radius after the most common
    city among the classes inside it (stable while the radius has inventory)."""
    members = [c for c in classes if haversine_miles(r["lat"], r["lng"], c["lat"], c["lng"]) <= r["miles"]]
    if not members: return None
    cities = {}
    for c in members: cities[(c["city"], c["state"])] = cities.get((c["city"], c["state"]), 0) + 1
    (city, state), _ = max(cities.items(), key=lambda kv: kv[1])
    return f"{city}, {state}"


def cluster(classes, miles=NEW_RADIUS_MILES, radius_for=None):
    """Greedy: repeatedly take the class with the most neighbours and centre the radius ON that class
    (a centroid could leave an edge member outside the radius and spawn a satellite next run); name it
    after the most common member city. radius_for(lat, lng) gives a per-centre radius (metro-overlap trim).
    Returns [{lat,lng,name,state,count,miles}]."""
    rest = list(classes); out = []
    rf = radius_for or (lambda lat, lng: miles)
    while rest:
        best = max(rest, key=lambda c: count_within(rest, c["lat"], c["lng"], rf(c["lat"], c["lng"])))
        miles = rf(best["lat"], best["lng"])
        members = [c for c in rest if haversine_miles(best["lat"], best["lng"], c["lat"], c["lng"]) <= miles]
        lat, lng = best["lat"], best["lng"]
        cities = {}
        for c in members: cities[(c["city"], c["state"])] = cities.get((c["city"], c["state"]), 0) + 1
        (city, state), _ = max(cities.items(), key=lambda kv: kv[1])
        out.append({"lat": round(lat, 5), "lng": round(lng, 5), "name": city, "state": state, "count": len(members), "miles": miles})
        rest = [c for c in rest if c not in members]
    return out


def inventory_guard(current, previous):
    """(ok, reason). A broken API would look like an empty catalogue and the rules would start pausing metros and
    removing radii — so a collapse in inventory blocks all mutations until a human looks."""
    if current < MIN_INVENTORY:
        return False, f"only {current} bookable classes found (minimum {MIN_INVENTORY}) — inventory feed looks broken"
    if previous and current < previous * (1 - MAX_INVENTORY_DROP):
        return False, f"bookable classes fell from {previous} to {current} ({(current - previous) / previous:+.0%}) — more than the {MAX_INVENTORY_DROP:.0%} guard"
    return True, ""


def decide(metros, radii, classes, history):
    """metros: [{id,name,status,lat,lng,miles,sync_paused}], radii: [{criterion_id,lat,lng,miles,name}],
    classes: [{lat,lng,city,state}], history: {key: [counts...]} newest last.
    Returns a plan dict; pure."""
    plan = {"pause": [], "enable": [], "remove_radii": [], "trim_radii": [], "add_radii": [], "promote": [], "counts": {}, "names": {}}
    def key(kind, lat, lng): return f"{kind}:{lat:.2f},{lng:.2f}"   # stable across renames
    for m in metros:
        n = count_within(classes, m["lat"], m["lng"], m["miles"]); k = key("metro", m["lat"], m["lng"])
        plan["counts"][k] = n; plan["names"][k] = m["name"]
        if m["status"] == "ENABLED" and n <= DROP_AT: plan["pause"].append({**m, "count": n})
        elif m["status"] == "PAUSED" and m["sync_paused"] and n >= ADD_AT: plan["enable"].append({**m, "count": n})
    kept = []
    for r in radii:
        k = key("radius", r["lat"], r["lng"]); r["name"] = name_radius(classes, r) or r["name"]
        room = allowed_miles(r["lat"], r["lng"], metros, r["miles"])
        if room is None:   # centre inside a metro circle: that campaign owns it
            plan["remove_radii"].append({**r, "count": count_within(classes, r["lat"], r["lng"], r["miles"])}); continue
        n = count_within(classes, r["lat"], r["lng"], room); plan["counts"][k] = n; plan["names"][k] = r["name"]
        if n <= DROP_AT: plan["remove_radii"].append({**r, "count": n}); continue
        if room < r["miles"] - 0.5: plan["trim_radii"].append({**r, "new_miles": room, "count": n})
        kept.append((r["lat"], r["lng"], room))
    covered = [(m["lat"], m["lng"], m["miles"]) for m in metros] + kept
    for c in cluster(uncovered(classes, covered), radius_for=lambda lat, lng: allowed_miles(lat, lng, metros)):
        if c["count"] >= ADD_AT:
            plan["add_radii"].append(c); k = key("radius", c["lat"], c["lng"])
            plan["counts"][k] = c["count"]; plan["names"][k] = f"{c['name']}, {c['state']}"
    for k, n in plan["counts"].items():
        streak = list(history.get(k, [])) + [n]
        if len(streak) >= PROMOTE_WEEKS and all(x >= PROMOTE_AT for x in streak[-PROMOTE_WEEKS:]) and k.startswith("radius:"):
            plan["promote"].append({"key": k, "name": plan["names"].get(k, k), "count": n, "weeks": PROMOTE_WEEKS})
    return plan


def summarize(plan, when):
    lines = [f"*Sip & Script Ads radius sync — {when}*"]
    lines.append(f"Inventory: {sum(v for k, v in plan['counts'].items() if k.startswith('metro:'))} classes in metro radii, "
                 f"{sum(v for k, v in plan['counts'].items() if k.startswith('radius:'))} in Rest of US radii.")
    for k, label in (("pause", "Paused metro campaigns"), ("enable", "Re-enabled metro campaigns"),
                     ("remove_radii", "Removed radii"), ("add_radii", "Added radii")):
        if plan[k]:
            lines.append(f"*{label}:* " + ", ".join(f"{x.get('name')}{', ' + x['state'] if x.get('state') else ''} ({x['count']})" for x in plan[k]))
    if plan.get("trim_radii"):
        lines.append("*Trimmed radii (metro overlap):* " + ", ".join(f"{x['name']} {x['miles']:.0f}→{x['new_miles']:.0f} mi ({x['count']})" for x in plan["trim_radii"]))
    if plan["promote"]:
        lines.append("*Ready for a metro page (" + f"≥{PROMOTE_AT} classes for {PROMOTE_WEEKS} weeks):* " + ", ".join(f"{x['name']} ({x['count']})" for x in plan["promote"]))
    if not any(plan.get(k) for k in ("pause", "enable", "remove_radii", "trim_radii", "add_radii", "promote")):
        lines.append("No changes.")
    return "\n".join(lines)


# ------------------------------------------------------------ inventory ---
def fetch_inventory(fetch=None, sleep=1.05):
    fetch = fetch or _http_json
    seen = {}; now = dt.datetime.now(dt.timezone.utc)
    for st in STATES:
        url = f"{SITE}/api/events/near?" + urllib.parse.urlencode({"query": st, "mode": "in-person", "pageSize": 500})
        for e in (fetch(url).get("results") or []):
            if e.get("isSoldOut") or e.get("latitude") is None: continue
            seen[e["key"]] = {"lat": e["latitude"], "lng": e["longitude"], "city": (e.get("city") or "").strip(), "state": (e.get("state") or "").strip()}
        time.sleep(sleep)
    return list(seen.values())


def _http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "sns-ads-sync/1.0", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r: return json.load(r)


# ------------------------------------------------------------ state ---
class State:
    def __init__(self, bucket=None, local_dir=None):
        self.local = local_dir; self.bucket = bucket
        if not local_dir:
            from google.cloud import storage
            self.b = storage.Client().bucket(bucket)
    def read(self, name, default):
        try:
            if self.local:
                p = os.path.join(self.local, name); return json.load(open(p)) if os.path.exists(p) else default
            blob = self.b.blob(name); return json.loads(blob.download_as_text()) if blob.exists() else default
        except Exception as e:
            print("state read failed:", e); return default
    def write(self, name, obj):
        if self.local:
            os.makedirs(self.local, exist_ok=True); json.dump(obj, open(os.path.join(self.local, name), "w"), indent=1)
        else: self.b.blob(name).upload_from_string(json.dumps(obj, indent=1), content_type="application/json")


# ------------------------------------------------------------ ads ---
class Ads:
    def __init__(self):
        from google.ads.googleads.client import GoogleAdsClient
        cfg = os.environ.get("GOOGLE_ADS_CONFIG")
        self.client = GoogleAdsClient.load_from_storage(cfg) if cfg else GoogleAdsClient.load_from_dict({"use_proto_plus": True, "use_application_default_credentials": True})
        self.ga = self.client.get_service("GoogleAdsService")
    def q(self, g): return list(self.ga.search(customer_id=CID, query=g))
    def label_rn(self):
        r = self.q(f"SELECT label.resource_name FROM label WHERE label.name = '{PAUSED_LABEL}'")
        if r: return r[0].label.resource_name
        op = self.client.get_type("LabelOperation"); op.create.name = PAUSED_LABEL
        return self.client.get_service("LabelService").mutate_labels(customer_id=CID, operations=[op]).results[0].resource_name
    def read(self):
        labelled = {r.campaign.id for r in self.q(f"SELECT campaign.id, label.name FROM campaign_label WHERE label.name = '{PAUSED_LABEL}'")}
        metros, rest_id = [], None
        for r in self.q(f"SELECT campaign.id, campaign.name, campaign.status FROM campaign WHERE campaign.name LIKE '{METRO_PREFIX}%' AND campaign.status != 'REMOVED'"):
            if r.campaign.name == REST_CAMPAIGN: rest_id = r.campaign.id; continue
            metros.append({"id": r.campaign.id, "name": r.campaign.name[len(METRO_PREFIX):], "status": r.campaign.status.name, "sync_paused": r.campaign.id in labelled})
        prox = {}
        for r in self.q("SELECT campaign.id, campaign_criterion.criterion_id, campaign_criterion.proximity.radius, campaign_criterion.proximity.geo_point.latitude_in_micro_degrees, campaign_criterion.proximity.geo_point.longitude_in_micro_degrees FROM campaign_criterion WHERE campaign_criterion.type = 'PROXIMITY' AND campaign.name LIKE 'SNS | %'"):
            p = r.campaign_criterion.proximity
            prox.setdefault(r.campaign.id, []).append({"criterion_id": r.campaign_criterion.criterion_id, "lat": p.geo_point.latitude_in_micro_degrees / 1e6, "lng": p.geo_point.longitude_in_micro_degrees / 1e6, "miles": p.radius, "name": f"{p.geo_point.latitude_in_micro_degrees/1e6:.2f},{p.geo_point.longitude_in_micro_degrees/1e6:.2f}"})
        for m in metros:
            p = prox.get(m["id"], [{}])[0]; m.update({"lat": p.get("lat"), "lng": p.get("lng"), "miles": p.get("miles", 40.0)})
        metros = [m for m in metros if m["lat"] is not None]
        return metros, rest_id, prox.get(rest_id, [])
    def apply(self, plan, rest_id):
        E = self.client.enums; C = self.client
        if plan["pause"] or plan["enable"]:
            ops, lops, lrm = [], [], []
            lab = self.label_rn()
            for m in plan["pause"] + plan["enable"]:
                op = C.get_type("CampaignOperation"); c = op.update; c.resource_name = f"customers/{CID}/campaigns/{m['id']}"
                c.status = E.CampaignStatusEnum.PAUSED if m in plan["pause"] else E.CampaignStatusEnum.ENABLED
                op.update_mask.paths.append("status"); ops.append(op)
                lo = C.get_type("CampaignLabelOperation")
                if m in plan["pause"]: lo.create.campaign = c.resource_name; lo.create.label = lab; lops.append(lo)
                else: lo.remove = f"customers/{CID}/campaignLabels/{m['id']}~{lab.split('/')[-1]}"; lrm.append(lo)
            C.get_service("CampaignService").mutate_campaigns(customer_id=CID, operations=ops)
            if lops: C.get_service("CampaignLabelService").mutate_campaign_labels(customer_id=CID, operations=lops)
            if lrm: C.get_service("CampaignLabelService").mutate_campaign_labels(customer_id=CID, operations=lrm)
        ops = []
        for r in plan["remove_radii"] + plan.get("trim_radii", []):   # a proximity radius is immutable: trim = remove + re-add
            op = C.get_type("CampaignCriterionOperation"); op.remove = f"customers/{CID}/campaignCriteria/{rest_id}~{r['criterion_id']}"; ops.append(op)
        for a in plan["add_radii"] + [{**t, "miles": t["new_miles"]} for t in plan.get("trim_radii", [])]:
            op = C.get_type("CampaignCriterionOperation"); cc = op.create; cc.campaign = f"customers/{CID}/campaigns/{rest_id}"
            cc.proximity.geo_point.latitude_in_micro_degrees = int(round(a["lat"] * 1e6)); cc.proximity.geo_point.longitude_in_micro_degrees = int(round(a["lng"] * 1e6))
            cc.proximity.radius = a.get("miles", NEW_RADIUS_MILES); cc.proximity.radius_units = E.ProximityRadiusUnitsEnum.MILES
            ops.append(op)
        if ops: C.get_service("CampaignCriterionService").mutate_campaign_criteria(customer_id=CID, operations=ops)


# ------------------------------------------------------------ daily report ---
def ads_daily_series(ads, today_local, days=28):
    """[(date, cost, clicks, conversions)] for SNS campaigns over the `days` days ending yesterday."""
    y = today_local - dt.timedelta(days=1); a = y - dt.timedelta(days=days - 1); agg = {}
    for r in ads.q(f"SELECT segments.date, metrics.cost_micros, metrics.clicks, metrics.conversions FROM campaign WHERE campaign.name LIKE 'SNS | %' AND segments.date BETWEEN '{a:%Y-%m-%d}' AND '{y:%Y-%m-%d}'"):
        o = agg.setdefault(r.segments.date, [0.0, 0, 0.0]); o[0] += r.metrics.cost_micros / 1e6; o[1] += r.metrics.clicks; o[2] += r.metrics.conversions
    return [(a + dt.timedelta(days=i), *agg.get(f"{a + dt.timedelta(days=i):%Y-%m-%d}", [0.0, 0, 0.0])) for i in range(days)]


def performance_report(ads, today_local, data=None):
    """Yesterday + last 7 days per campaign, pacing vs budget, top search terms. Read-only.
    Pass data=[] to also receive the structured pieces (headline, rows, flags) via that list."""
    y = today_local - dt.timedelta(days=1); d7 = today_local - dt.timedelta(days=7)
    def rng(a, b): return f"segments.date BETWEEN '{a:%Y-%m-%d}' AND '{b:%Y-%m-%d}'"
    def camp(a, b):
        out = {}
        for r in ads.q(f"SELECT campaign.name, campaign.primary_status, campaign_budget.amount_micros, metrics.cost_micros, metrics.clicks, metrics.impressions, metrics.conversions, metrics.conversions_value FROM campaign WHERE campaign.name LIKE 'SNS | %' AND campaign.status = 'ENABLED' AND {rng(a, b)}"):
            m = r.metrics; o = out.setdefault(r.campaign.name, {"cost": 0, "clicks": 0, "impr": 0, "conv": 0, "value": 0, "budget": r.campaign_budget.amount_micros / 1e6, "status": r.campaign.primary_status.name})
            o["cost"] += m.cost_micros / 1e6; o["clicks"] += m.clicks; o["impr"] += m.impressions; o["conv"] += m.conversions; o["value"] += m.conversions_value
        return out
    yd, wk = camp(y, y), camp(d7, y)
    enabled, budgets = {}, {}
    for r in ads.q("SELECT campaign.name, campaign.primary_status, campaign_budget.resource_name, campaign_budget.amount_micros FROM campaign WHERE campaign.name LIKE 'SNS | %' AND campaign.status = 'ENABLED'"):
        enabled[r.campaign.name] = (r.campaign.primary_status.name, r.campaign_budget.amount_micros / 1e6); budgets[r.campaign_budget.resource_name] = r.campaign_budget.amount_micros / 1e6
    def tot(d): return {k: sum(v[k] for v in d.values()) for k in ("cost", "clicks", "impr", "conv", "value")}
    ty, tw = tot(yd), tot(wk)
    def line(t): 
        ctr = 100 * t["clicks"] / t["impr"] if t["impr"] else 0; cpc = t["cost"] / t["clicks"] if t["clicks"] else 0
        return f"${t['cost']:.2f} · {t['impr']:,} impr · {t['clicks']} clicks ({ctr:.1f}% CTR, ${cpc:.2f} CPC) · {t['conv']:.0f} purchases (${t['value']:.0f})"
    lines = [f"*Sip & Script Ads daily report — {y:%a %b %d}*", f"Yesterday: {line(ty)}", f"Last 7 days: {line(tw)}"]
    daily_budget = sum(budgets.values()); lines.append(f"Daily budget ${daily_budget:.0f}; yesterday spent {100 * ty['cost'] / daily_budget if daily_budget else 0:.0f}% of it.")
    rows = []
    for name, (status, budget) in enabled.items():
        o = yd.get(name, {"cost": 0, "clicks": 0, "impr": 0, "conv": 0}); w = wk.get(name, {"cost": 0, "clicks": 0, "impr": 0, "conv": 0})
        short = name.replace("SNS | Search | ", "")
        flag = "⚠ no impressions 7d" if w["impr"] == 0 else ("⚠ budget-capped" if budget and o["cost"] >= 0.95 * budget else ("⚠ " + status if status not in ("ELIGIBLE", "LEARNING") else ""))
        rows.append((o["cost"], f"{short}: ${o['cost']:.2f}/{budget:.0f} · {o['impr']} impr · {o['clicks']} clk · {o['conv']:.0f} conv (7d: {w['clicks']} clk, {w['conv']:.0f} conv) {flag}".rstrip(), o["impr"] > 0))
    rows.sort(key=lambda x: -x[0]); lines.append("*By campaign (yesterday, 7d):*"); lines += ["• " + r for _, r, _ in rows]
    if data is not None:
        active = [r for _, r, served in rows if served]
        data.append({"headline": line(ty) + f" · spent {100 * ty['cost'] / daily_budget if daily_budget else 0:.0f}% of ${daily_budget:.0f} budget",
                     "rows": [r for _, r, _ in rows], "active": active, "flagged": [r for _, r, served in rows if "⚠" in r and served]})
    terms = {}
    for r in ads.q(f"SELECT search_term_view.search_term, metrics.cost_micros, metrics.clicks, metrics.conversions FROM search_term_view WHERE campaign.name LIKE 'SNS | %' AND {rng(d7, y)}"):
        t = terms.setdefault(r.search_term_view.search_term, [0, 0, 0]); t[0] += r.metrics.cost_micros / 1e6; t[1] += r.metrics.clicks; t[2] += r.metrics.conversions
    top = sorted(terms.items(), key=lambda kv: -kv[1][0])[:12]
    if top: lines.append("*Top search terms, 7d by cost:* " + "; ".join(f"{t} (${c:.2f}, {k} clk, {v:.0f} conv)" for t, (c, k, v) in top))
    return "\n".join(lines)


def notify(text):
    url = os.environ.get("SLACK_WEBHOOK_URL")
    if not url: print("(no SLACK_WEBHOOK_URL; summary not posted)"); return
    req = urllib.request.Request(url, data=json.dumps({"text": text}).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r: print("slack:", r.status)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--apply", action="store_true"); ap.add_argument("--report", action="store_true"); ap.add_argument("--ga-report", action="store_true"); ap.add_argument("--brief", action="store_true"); ap.add_argument("--state-dir")
    a = ap.parse_args()
    if a.brief:
        import zoneinfo
        from brief import ga_report, ai_summary, slack_post, charts
        today = dt.datetime.now(zoneinfo.ZoneInfo("America/New_York")).date(); label = f"{today - dt.timedelta(days=1):%a %b %d}"
        ga = ga_report.report_data(key_file=os.environ.get("GA4_KEY_FILE"), today=today)
        ads = Ads(); adata = []; ads_text = performance_report(ads, today, data=adata); adata = adata[0]
        story = ai_summary.narrative(ga["text"], ads_text)
        movers = (adata["active"][:5] + [r for r in adata["flagged"] if r not in adata["active"][:5]])[:7]
        blocks = slack_post.brief_blocks(label, story, ga["fields"], adata["headline"], ga["flags"], movers)
        thread = ga["text"] + "\n\n" + ads_text
        images = []
        try:
            gs = ga["series"]; images.append(("website-28d.png", charts.line_chart([d for d, _, _ in gs], {"Sessions": [s_ for _, s_, _ in gs]}, "Website, last 28 days", "sessions", right=("Orders", [o for _, _, o in gs])), "Website: sessions and orders, 28 days"))
            ad = ads_daily_series(ads, today); images.append(("ads-28d.png", charts.line_chart([d for d, *_ in ad], {"Spend $": [c for _, c, _, _ in ad], "Clicks": [k for _, _, k, _ in ad]}, "Google Ads, last 28 days", "spend / clicks", right=("Purchases", [v for *_, v in ad])), "Google Ads: spend, clicks and purchases, 28 days"))
        except Exception as e: print("charts failed:", e)
        fallback = f"*Morning brief — {label}*\n" + (f"_{story}_\n\n" if story else "") + thread
        print(fallback); print("posted via", slack_post.post_brief(blocks, fallback, thread_text=thread, images=images)); return 0
    if a.ga_report:
        from brief import ga_report
        text = ga_report.report(key_file=os.environ.get("GA4_KEY_FILE")); print(text); notify(text); return 0
    if a.report:
        import zoneinfo
        text = performance_report(Ads(), dt.datetime.now(zoneinfo.ZoneInfo("America/New_York")).date()); print(text); notify(text); return 0
    if not (a.dry_run or a.apply): ap.error("pass --dry-run, --apply or --report")
    when = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    ads = Ads(); metros, rest_id, radii = ads.read()
    print(f"account: {len(metros)} metro campaigns, {len(radii)} Rest of US radii (campaign {rest_id})")
    classes = fetch_inventory(); print(f"inventory: {len(classes)} bookable in-person classes")
    state = State(bucket=os.environ.get("STATE_BUCKET", "sns-ads-sync"), local_dir=a.state_dir)
    history = state.read("history.json", {})
    previous = (history.get("_inventory") or [None])[-1]
    ok, why = inventory_guard(len(classes), previous)
    plan = decide(metros, radii, classes, history)
    text = summarize(plan, when + (" (dry run)" if a.dry_run else "")); print(text)
    for k, v in sorted(plan["counts"].items(), key=lambda kv: -kv[1]): print(f"  {v:3d}  {plan['names'].get(k, k)}  [{k}]")
    if not ok:
        alert = f"*Sip & Script Ads radius sync — {when}: NOT APPLIED*\n⚠ {why}. No campaigns or radii were changed; the plan above is what it would have done. Check {SITE}/api/events/near and re-run once inventory looks right."
        print(alert)
        if a.apply: notify(alert)
        return 2
    if a.apply:
        ads.apply(plan, rest_id)
        for k, n in plan["counts"].items(): history[k] = (history.get(k, []) + [n])[-12:]
        history["_inventory"] = (history.get("_inventory") or [])[-12:] + [len(classes)]
        state.write("history.json", history); state.write(f"snapshots/{when}.json", {"plan": plan, "classes": len(classes)})
        notify(text)
    return 0


if __name__ == "__main__": sys.exit(main())
