#!/usr/bin/env python3
"""Build the Sip & Script Google Ads search campaigns (2026-09-25 design).

Usage:
  python build_campaigns.py --dry-run      # validate + print the plan, no API writes
  python build_campaigns.py --apply        # create everything (campaigns PAUSED)
  python build_campaigns.py --report       # read back what exists

Auth: ~/.config/gcloud/sns-google-ads.yaml (service account ads-builder@sipandscript).
Idempotent by name: existing budgets / campaigns / ad groups / conversion actions are reused,
so a re-run only fills in what is missing.
"""
import argparse, json, os, re, sys
from pathlib import Path

CID = "1863952460"
SITE = "https://www.sipandscript.com"
CONFIG = os.path.expanduser("~/.config/gcloud/sns-google-ads.yaml")
HERE = Path(__file__).resolve().parent
METROS = json.load(open(HERE / "metros.json"))
REST_OF_US = json.load(open(HERE / "rest_of_us.json"))   # clusters with classes but no metro page (+ the 5 held metros)

# ---------------------------------------------------------------- design ---
DAILY = {  # USD per day, matching the live account: $100 total ≈ $3,040 / 30.4
    "near_me_shared": 45.0,
    "city_named": 15.0,
    "brand": 10.0,  # raised from 5 on 2026-09-27: lost 17% impression share to budget
    "rest_of_us": 30.0,  # 10 -> 50 on 2026-09-25, cut to 30 on 2026-09-27 with the metro-overlap trim
}
MONTHLY_BUDGET = 3050.0
REST_OF_US_RADIUS = {"lehigh-valley": 30}   # default RADIUS_MILES; Lehigh trimmed to limit Philadelphia overlap
MAX_CPC = 2.00
RADIUS_MILES = 40
MIN_CLASSES_FOR_NEAR_ME = 13   # Houston 13 / Scottsdale 13 in, CT 10 / Detroit 9 / Austin 7 out
NEAR_ME_HOLD = {"houston", "scottsdale", "connecticut", "detroit", "austin"}  # per approved design

CITY_LABEL = {  # short label for headlines (<=30 chars once templated)
    "austin": "Austin", "boston": "Boston", "san-francisco": "Bay Area", "nyc": "NYC",
    "washington-dc": "DC", "dallas": "Dallas", "houston": "Houston",
    "los-angeles": "Los Angeles", "chicago": "Chicago", "scottsdale": "Scottsdale",
    "nashville": "Nashville", "detroit": "Detroit", "tampa": "Tampa", "seattle": "Seattle",
    "raleigh-durham": "Raleigh", "nh-maine": "NH & Maine", "connecticut": "Connecticut",
    "san-antonio": "San Antonio", "rhode-island": "Rhode Island", "atlanta": "Atlanta",
    "philadelphia": "Philadelphia",
}
METRO_NAME = {  # campaign / ad group naming
    "san-francisco": "Bay Area", "nyc": "NYC", "washington-dc": "Washington DC",
    "raleigh-durham": "Raleigh-Durham", "nh-maine": "NH & Maine", "connecticut": "Connecticut",
    "rhode-island": "Rhode Island",
}
CITY_ALIASES = {  # for the national city-named campaign
    "austin": ["austin"],
    "boston": ["boston", "cambridge ma"],
    "san-francisco": ["san francisco", "bay area", "east bay", "oakland", "san jose"],
    "nyc": ["nyc", "new york", "new york city", "manhattan", "brooklyn", "long island"],
    "washington-dc": ["dc", "washington dc", "northern virginia", "arlington va", "baltimore", "annapolis"],
    "dallas": ["dallas", "fort worth", "dfw", "plano"],
    "houston": ["houston"],
    "los-angeles": ["los angeles", "orange county", "long beach", "santa monica"],
    "chicago": ["chicago", "naperville"],
    "scottsdale": ["scottsdale", "phoenix", "mesa az", "tempe"],
    "nashville": ["nashville", "franklin tn"],
    "detroit": ["detroit", "ann arbor"],
    "tampa": ["tampa", "st petersburg", "clearwater"],
    "seattle": ["seattle", "bellevue"],
    "raleigh-durham": ["raleigh", "durham", "chapel hill", "cary nc"],
    "nh-maine": ["portsmouth nh", "new hampshire", "maine", "portland maine"],
    "connecticut": ["connecticut", "hartford"],
    "san-antonio": ["san antonio"],
    "rhode-island": ["rhode island", "providence"],
    "atlanta": ["atlanta", "alpharetta", "marietta"],
    "philadelphia": ["philadelphia", "philly", "king of prussia", "south jersey"],
}

GENERIC_KEYWORDS = [
    "calligraphy classes near me", "calligraphy class near me", "calligraphy classes",
    "calligraphy class", "calligraphy lessons near me", "calligraphy lessons",
    "calligraphy workshop", "calligraphy workshops near me", "calligraphy classes for adults",
    "calligraphy classes for beginners", "hand lettering classes near me", "lettering classes near me",
    "modern calligraphy class", "caligraphy classes", "caligraphy class near me",
    "calligraphy course near me", "brush lettering class",
]
CITY_TEMPLATES_PHRASE = ["calligraphy classes {c}", "calligraphy class {c}", "{c} calligraphy classes",
                         "calligraphy workshop {c}", "calligraphy lessons {c}"]
CITY_TEMPLATES_EXACT = ["calligraphy classes {c}", "calligraphy class {c}", "{c} calligraphy classes"]

BRAND_KEYWORDS = {  # text -> match types
    "sip and script": ["EXACT", "PHRASE"], "sip & script": ["EXACT", "PHRASE"],
    "sip n script": ["EXACT", "PHRASE"], "sipandscript": ["EXACT"],
    "sip and script calligraphy": ["PHRASE"], "script and sip": ["PHRASE"], "sips and scripts": ["EXACT"],
}

NEGATIVES = [
    "free", "online", "virtual", "zoom", "tutorial", "youtube", "pdf", "worksheet", "printable",
    "font", "fonts", "generator", "app", "kids", "children", "toddler", "teen", "chinese", "arabic",
    "japanese", "islamic", "job", "jobs", "hiring", "salary", "supplies", "pen", "pens", "nib", "ink",
    "kit", "book", "degree", "certificate", "calligrapher", "wedding", "envelope addressing",
    "teach", "instructor", "quran", "hebrew", "korean", "tattoo", "cricut", "diploma",
    # added 2026-09-27 after the two-day search-terms review: DIY / informational + off-target
    "how to", "practice", "alphabet", "sheets", "tips", "guide", "exercises", "guild", "tutor",
    "engraving", "gothic", "shodo", "paper source", "marcy robinson",
]

# phrase negatives on every NON-brand campaign so brand searches serve from the Brand campaign (added 2026-09-27)
BRAND_NEGATIVES = ["sip and script", "sip & script", "sip n script", "sipandscript", "sips and scripts", "script and sip"]

# Every claim below is on the live metro pages: all materials included, beginner friendly,
# (no 'drink'/'sip' wording in ad text — it trips Google's alcohol-information policy; 2026-09-25)
# no experience needed, 4.9 rating / 10,000+ students, tickets from $65.
COMMON_HEADLINES = [
    "Sip & Script Calligraphy Class", "All Materials Included", "Beginners Welcome",
    "No Experience Needed", "Held at Cozy Local Venues", "Rated 4.9 by 10,000+ Students",
    "Modern Calligraphy Workshops", "Learn Modern Calligraphy", "Tickets From $65",
    "Book Your Seat Online", "Fun Night Out With Friends", "A Creative Night Out",
    "Local Venues Near You", "Classes Near You This Week",
]
DESCRIPTIONS = [
    "Learn modern calligraphy at a welcoming local venue near you. All materials included.",
    "Beginner-friendly workshops. Come solo or bring friends. Rated 4.9 by 10,000+ students.",
    "Everything you need is provided. Tickets from $65. See upcoming dates and book online.",
    "Hands-on instruction from a local Sip & Script instructor. No experience needed to join.",
]
BRAND_HEADLINES = [
    "Sip & Script | Official Site", "Sip & Script Calligraphy", "Find a Class Near You",
    "All Materials Included", "Rated 4.9 by 10,000+ Students", "Book Tickets Online",
    "Modern Calligraphy Workshops", "Beginners Welcome", "Held at Cozy Local Venues",
    "Private & Corporate Events", "Gift Cards Available",
]
SITELINKS = [
    ("Private Events", "Bridal parties, birthdays, showers", "Supplies and instructor provided", "/private-events/"),
    ("Corporate & Teams", "Onsite or offsite team workshops", "Calligraphy for groups of any size", "/corporate-events/"),
    ("Gift Cards", "Give a calligraphy class", "Redeemable at any location", "/shop/gift-cards/"),
    ("FAQs", "What to expect at class", "Materials, drinks, skill level", "/faqs/"),
]


def city_headline(slug):
    c = CITY_LABEL[slug]
    for t in (f"Calligraphy Classes in {c}", f"{c} Calligraphy Classes", f"{c} Calligraphy Class"):
        if len(t) <= 30:
            return t
    return "Calligraphy Classes Near You"


def metro_name(slug):
    return METRO_NAME.get(slug, slug.replace("-", " ").title())


def near_me_slugs():
    return [s for s in METROS if s not in NEAR_ME_HOLD and METROS[s]["total"] >= MIN_CLASSES_FOR_NEAR_ME]


def plan():
    """Pure description of everything to build (no API)."""
    p = {"budgets": {}, "campaigns": [], "negatives": NEGATIVES, "sitelinks": SITELINKS,
         "conversion_actions": [("Ticket purchase", "PURCHASE", True), ("Begin checkout", "BEGIN_CHECKOUT", False)]}
    p["budgets"]["SNS | Budget | Near Me (shared)"] = (DAILY["near_me_shared"], True)
    p["budgets"]["SNS | Budget | City Named"] = (DAILY["city_named"], False)
    p["budgets"]["SNS | Budget | Brand"] = (DAILY["brand"], False)
    for s in near_me_slugs():
        m = METROS[s]
        p["campaigns"].append({
            "name": f"SNS | Search | Near Me | {metro_name(s)}", "budget": "SNS | Budget | Near Me (shared)",
            "geo": {"proximity": (m["lat"], m["lng"], RADIUS_MILES)},
            "ad_groups": [{
                "name": "Calligraphy classes - generic", "final_url": f"{SITE}/metros/{s}/",
                "keywords": [(k, mt) for k in GENERIC_KEYWORDS for mt in ("PHRASE", "EXACT")],
                "headlines": [(city_headline(s), "HEADLINE_1")] + [(h, None) for h in COMMON_HEADLINES],
                "descriptions": DESCRIPTIONS, "paths": ("classes", CITY_LABEL[s].lower().replace("the ", "").replace(" & ", "-").replace(" ", "-")[:15]),
            }],
        })
    p["budgets"]["SNS | Budget | Rest of US"] = (DAILY["rest_of_us"], False)
    p["campaigns"].append({
        "name": "SNS | Search | Near Me | Rest of US", "budget": "SNS | Budget | Rest of US",
        "geo": {"proximities": [(m["lat"], m["lng"], REST_OF_US_RADIUS.get(k, RADIUS_MILES)) for k, m in REST_OF_US.items()]},
        "ad_groups": [{
            "name": "Calligraphy classes - generic", "final_url": f"{SITE}/events/",
            "keywords": [(k, mt) for k in GENERIC_KEYWORDS for mt in ("PHRASE", "EXACT")],
            "headlines": [("Calligraphy Classes Near You", "HEADLINE_1")] + [(h, None) for h in COMMON_HEADLINES if h != "Classes Near You This Week"] + [("Find a Class in Your City", None)],
            "descriptions": DESCRIPTIONS, "paths": ("classes", "near-me"),
        }],
    })
    city_groups = []
    for s in METROS:
        kws = []
        for c in CITY_ALIASES[s]:
            kws += [(t.format(c=c), "PHRASE") for t in CITY_TEMPLATES_PHRASE]
            kws += [(t.format(c=c), "EXACT") for t in CITY_TEMPLATES_EXACT]
        city_groups.append({
            "name": metro_name(s), "final_url": f"{SITE}/metros/{s}/", "keywords": kws,
            "headlines": [(city_headline(s), "HEADLINE_1")] + [(h, None) for h in COMMON_HEADLINES],
            "descriptions": DESCRIPTIONS, "paths": ("classes", CITY_LABEL[s].lower().replace("the ", "").replace(" & ", "-").replace(" ", "-")[:15]),
        })
    p["campaigns"].append({"name": "SNS | Search | City Named | National", "budget": "SNS | Budget | City Named",
                           "geo": {"location": 2840}, "ad_groups": city_groups})
    p["campaigns"].append({"name": "SNS | Search | Brand", "budget": "SNS | Budget | Brand", "geo": {"location": 2840},
                           "ad_groups": [{
                               "name": "Brand", "final_url": f"{SITE}/",
                               "keywords": [(k, mt) for k, mts in BRAND_KEYWORDS.items() for mt in mts],
                               "headlines": [(BRAND_HEADLINES[0], "HEADLINE_1")] + [(h, None) for h in BRAND_HEADLINES[1:]],
                               "descriptions": DESCRIPTIONS, "paths": ("calligraphy", "classes"),
                           }]})
    return p


def validate(p):
    errs = []
    for c in p["campaigns"]:
        for g in c["ad_groups"]:
            hs = [h for h, _ in g["headlines"]]
            if not 3 <= len(hs) <= 15: errs.append(f"{c['name']}/{g['name']}: {len(hs)} headlines")
            if len(set(hs)) != len(hs): errs.append(f"{c['name']}/{g['name']}: duplicate headlines")
            for h in hs:
                if len(h) > 30: errs.append(f"headline >30: {h!r} ({len(h)})")
            if not 2 <= len(g["descriptions"]) <= 4: errs.append(f"{g['name']}: description count")
            for d in g["descriptions"]:
                if len(d) > 90: errs.append(f"description >90: {d!r} ({len(d)})")
            for pth in g["paths"]:
                if len(pth) > 15: errs.append(f"path >15: {pth!r}")
            if len(set(g["keywords"])) != len(g["keywords"]): errs.append(f"{g['name']}: duplicate keywords")
            for k, _ in g["keywords"]:
                if len(k) > 80 or len(k.split()) > 10: errs.append(f"keyword too long: {k!r}")
    for t, d1, d2, _ in p["sitelinks"]:
        if len(t) > 25 or len(d1) > 35 or len(d2) > 35: errs.append(f"sitelink too long: {t}")
    total_daily = sum(v for v, _ in p["budgets"].values())
    if total_daily * 30.4 > MONTHLY_BUDGET * 1.02: errs.append(f"daily budgets {total_daily} exceed monthly cap")
    return errs


def describe(p):
    n_kw = sum(len(g["keywords"]) for c in p["campaigns"] for g in c["ad_groups"])
    n_ag = sum(len(c["ad_groups"]) for c in p["campaigns"])
    print(f"{len(p['campaigns'])} campaigns, {n_ag} ad groups, {n_kw} keywords, {len(p['negatives'])} negatives, "
          f"{len(p['sitelinks'])} sitelinks, {len(p['conversion_actions'])} conversion actions")
    for name, (amt, shared) in p["budgets"].items():
        print(f"  budget {name}: ${amt:.2f}/day{' shared' if shared else ''}")
    print(f"  daily total ${sum(v for v,_ in p['budgets'].values()):.2f} ≈ ${sum(v for v,_ in p['budgets'].values())*30.4:,.0f}/month; max CPC ${MAX_CPC:.2f}")
    for c in p["campaigns"]:
        geo = c["geo"]
        g = (f"radius {geo['proximity'][2]}mi @ {geo['proximity'][0]:.3f},{geo['proximity'][1]:.3f}" if "proximity" in geo
             else f"{len(geo['proximities'])} radii" if "proximities" in geo else f"geo {geo['location']}")
        print(f"  {c['name']}  [{g}]  {len(c['ad_groups'])} ad group(s), {sum(len(a['keywords']) for a in c['ad_groups'])} kws")
    g = p["campaigns"][0]["ad_groups"][0]
    print("  sample RSA:", [h for h, _ in g["headlines"]][:4], "…", g["final_url"])


# ------------------------------------------------------------------ API ---
class Builder:
    def __init__(self):
        from google.ads.googleads.client import GoogleAdsClient
        self.client = GoogleAdsClient.load_from_storage(CONFIG)
        self.ga = self.client.get_service("GoogleAdsService")
        self.created = []

    def q(self, gaql):
        return list(self.ga.search(customer_id=CID, query=gaql))

    def find(self, gaql):
        r = self.q(gaql)
        return r[0] if r else None

    def mutate(self, service, op_attr, ops):
        svc = self.client.get_service(service)
        method = getattr(svc, f"mutate_{op_attr}")
        resp = method(customer_id=CID, operations=ops)
        return [r.resource_name for r in resp.results]

    # -- budgets
    def budget(self, name, daily, shared, campaign_names=()):
        # Google renames a NON-shared budget to its campaign's name, so look it up by either name.
        names = ", ".join(f"'{n}'" for n in (name, *campaign_names))
        row = self.find(f"SELECT campaign_budget.resource_name FROM campaign_budget WHERE campaign_budget.name IN ({names}) AND campaign_budget.status = 'ENABLED'")
        if row: return row.campaign_budget.resource_name
        op = self.client.get_type("CampaignBudgetOperation"); b = op.create
        b.name = name; b.amount_micros = int(daily * 1e6); b.explicitly_shared = shared
        b.delivery_method = self.client.enums.BudgetDeliveryMethodEnum.STANDARD
        rn = self.mutate("CampaignBudgetService", "campaign_budgets", [op])[0]; self.created.append(rn); return rn

    # -- portfolio bid strategy (REQUIRED for campaigns on a shared budget: campaign-level Maximize Clicks on a shared
    #    budget is reported as BIDDING_STRATEGY_MISCONFIGURED / MISCONFIGURED_SHARED_BUDGET — seen 2026-09-26)
    def portfolio(self, name):
        row = self.find(f"SELECT bidding_strategy.resource_name FROM bidding_strategy WHERE bidding_strategy.name = '{name}' AND bidding_strategy.status = 'ENABLED'")
        if row: return row.bidding_strategy.resource_name
        op = self.client.get_type("BiddingStrategyOperation"); b = op.create
        b.name = name; b.target_spend.cpc_bid_ceiling_micros = int(MAX_CPC * 1e6)
        rn = self.mutate("BiddingStrategyService", "bidding_strategies", [op])[0]; self.created.append(rn); return rn

    # -- negative keyword list
    def negative_list(self, name, words, match_type="BROAD"):
        row = self.find(f"SELECT shared_set.resource_name FROM shared_set WHERE shared_set.name = '{name}' AND shared_set.status = 'ENABLED'")
        if row: return row.shared_set.resource_name
        op = self.client.get_type("SharedSetOperation"); s = op.create
        s.name = name; s.type_ = self.client.enums.SharedSetTypeEnum.NEGATIVE_KEYWORDS
        rn = self.mutate("SharedSetService", "shared_sets", [op])[0]; self.created.append(rn)
        ops = []
        for w in words:
            o = self.client.get_type("SharedCriterionOperation"); c = o.create
            c.shared_set = rn; c.keyword.text = w; c.keyword.match_type = getattr(self.client.enums.KeywordMatchTypeEnum, match_type)
            ops.append(o)
        self.mutate("SharedCriterionService", "shared_criteria", ops)
        return rn

    # -- conversion actions
    def conversion_action(self, name, category, primary):
        row = self.find(f"SELECT conversion_action.resource_name FROM conversion_action WHERE conversion_action.name = '{name}'")
        if row: return row.conversion_action.resource_name
        op = self.client.get_type("ConversionActionOperation"); a = op.create
        a.name = name; a.type_ = self.client.enums.ConversionActionTypeEnum.WEBPAGE
        a.category = getattr(self.client.enums.ConversionActionCategoryEnum, category)
        a.status = self.client.enums.ConversionActionStatusEnum.ENABLED
        a.primary_for_goal = primary
        # purchases count every order (a visitor placed two from one click on 2026-09-26); other actions once per click
        a.counting_type = getattr(self.client.enums.ConversionActionCountingTypeEnum, "MANY_PER_CLICK" if category == "PURCHASE" else "ONE_PER_CLICK")
        a.value_settings.default_value = 0.0; a.value_settings.always_use_default_value = False
        a.click_through_lookback_window_days = 30; a.view_through_lookback_window_days = 1
        rn = self.mutate("ConversionActionService", "conversion_actions", [op])[0]; self.created.append(rn); return rn

    # -- sitelinks (account-level assets, attached per campaign)
    def sitelink_assets(self):
        rns = []
        for text, d1, d2, path in SITELINKS:
            row = self.find(f"SELECT asset.resource_name FROM asset WHERE asset.type = 'SITELINK' AND asset.sitelink_asset.link_text = '{text}'")
            if row: rns.append(row.asset.resource_name); continue
            op = self.client.get_type("AssetOperation"); a = op.create
            a.sitelink_asset.link_text = text; a.sitelink_asset.description1 = d1; a.sitelink_asset.description2 = d2
            a.final_urls.append(SITE + path)
            rn = self.mutate("AssetService", "assets", [op])[0]; self.created.append(rn); rns.append(rn)
        return rns

    def attach_sitelinks(self, campaign_rn, asset_rns):
        existing = {r.campaign_asset.asset for r in self.q(
            f"SELECT campaign_asset.asset FROM campaign_asset WHERE campaign_asset.campaign = '{campaign_rn}' AND campaign_asset.field_type = 'SITELINK'")}
        ops = []
        for a in asset_rns:
            if a in existing: continue
            op = self.client.get_type("CampaignAssetOperation"); ca = op.create
            ca.campaign = campaign_rn; ca.asset = a; ca.field_type = self.client.enums.AssetFieldTypeEnum.SITELINK
            ops.append(op)
        if ops: self.mutate("CampaignAssetService", "campaign_assets", ops)

    # -- campaign
    def campaign(self, spec, budget_rn, negative_set_rn, portfolio_rn=None, brand_negative_set_rn=None):
        row = self.find(f"SELECT campaign.resource_name, campaign.status FROM campaign WHERE campaign.name = '{spec['name']}' AND campaign.status != 'REMOVED'")
        if row: return row.campaign.resource_name, False
        op = self.client.get_type("CampaignOperation"); c = op.create
        c.name = spec["name"]; c.campaign_budget = budget_rn
        c.status = self.client.enums.CampaignStatusEnum.PAUSED
        c.advertising_channel_type = self.client.enums.AdvertisingChannelTypeEnum.SEARCH
        if portfolio_rn: c.bidding_strategy = portfolio_rn                  # shared budget → portfolio Maximize clicks
        else: c.target_spend.cpc_bid_ceiling_micros = int(MAX_CPC * 1e6)   # own budget → campaign-level Maximize clicks
        ns = c.network_settings
        ns.target_google_search = True; ns.target_search_network = False
        ns.target_content_network = False; ns.target_partner_search_network = False
        c.geo_target_type_setting.positive_geo_target_type = self.client.enums.PositiveGeoTargetTypeEnum.PRESENCE
        c.geo_target_type_setting.negative_geo_target_type = self.client.enums.NegativeGeoTargetTypeEnum.PRESENCE
        if hasattr(c, "contains_eu_political_advertising"):
            c.contains_eu_political_advertising = self.client.enums.EuPoliticalAdvertisingStatusEnum.DOES_NOT_CONTAIN_EU_POLITICAL_ADVERTISING
        rn = self.mutate("CampaignService", "campaigns", [op])[0]; self.created.append(rn)
        # criteria: language, geo, negative list
        ops = []
        o = self.client.get_type("CampaignCriterionOperation"); cc = o.create
        cc.campaign = rn; cc.language.language_constant = "languageConstants/1000"; ops.append(o)
        prox = spec["geo"].get("proximities") or ([spec["geo"]["proximity"]] if "proximity" in spec["geo"] else [])
        for lat, lng, miles in prox:
            o = self.client.get_type("CampaignCriterionOperation"); cc = o.create; cc.campaign = rn
            cc.proximity.geo_point.latitude_in_micro_degrees = int(round(lat * 1e6))
            cc.proximity.geo_point.longitude_in_micro_degrees = int(round(lng * 1e6))
            cc.proximity.radius = float(miles); cc.proximity.radius_units = self.client.enums.ProximityRadiusUnitsEnum.MILES
            ops.append(o)
        if not prox:
            o = self.client.get_type("CampaignCriterionOperation"); cc = o.create; cc.campaign = rn
            cc.location.geo_target_constant = f"geoTargetConstants/{spec['geo']['location']}"
            ops.append(o)
        self.mutate("CampaignCriterionService", "campaign_criteria", ops)
        o = self.client.get_type("CampaignSharedSetOperation"); css = o.create
        css.campaign = rn; css.shared_set = negative_set_rn
        ops = [o]
        if brand_negative_set_rn:
            o = self.client.get_type("CampaignSharedSetOperation"); css = o.create
            css.campaign = rn; css.shared_set = brand_negative_set_rn; ops.append(o)
        self.mutate("CampaignSharedSetService", "campaign_shared_sets", ops)
        return rn, True

    def ad_group(self, campaign_rn, spec):
        row = self.find(f"SELECT ad_group.resource_name FROM ad_group WHERE ad_group.campaign = '{campaign_rn}' AND ad_group.name = '{spec['name']}' AND ad_group.status != 'REMOVED'")
        if row: return row.ad_group.resource_name, False
        op = self.client.get_type("AdGroupOperation"); g = op.create
        g.name = spec["name"]; g.campaign = campaign_rn
        g.status = self.client.enums.AdGroupStatusEnum.ENABLED
        g.type_ = self.client.enums.AdGroupTypeEnum.SEARCH_STANDARD
        g.cpc_bid_micros = int(MAX_CPC * 1e6)
        rn = self.mutate("AdGroupService", "ad_groups", [op])[0]; self.created.append(rn)
        # keywords
        ops = []
        for text, mt in spec["keywords"]:
            o = self.client.get_type("AdGroupCriterionOperation"); k = o.create
            k.ad_group = rn; k.status = self.client.enums.AdGroupCriterionStatusEnum.ENABLED
            k.keyword.text = text; k.keyword.match_type = getattr(self.client.enums.KeywordMatchTypeEnum, mt)
            k.final_urls.append(spec["final_url"])
            ops.append(o)
        for i in range(0, len(ops), 500):
            self.mutate("AdGroupCriterionService", "ad_group_criteria", ops[i:i+500])
        # responsive search ad
        o = self.client.get_type("AdGroupAdOperation"); ad = o.create
        ad.ad_group = rn; ad.status = self.client.enums.AdGroupAdStatusEnum.ENABLED
        ad.ad.final_urls.append(spec["final_url"])
        rsa = ad.ad.responsive_search_ad
        for text, pin in spec["headlines"]:
            h = self.client.get_type("AdTextAsset"); h.text = text
            if pin: h.pinned_field = getattr(self.client.enums.ServedAssetFieldTypeEnum, pin)
            rsa.headlines.append(h)
        for text in spec["descriptions"]:
            d = self.client.get_type("AdTextAsset"); d.text = text; rsa.descriptions.append(d)
        rsa.path1, rsa.path2 = spec["paths"]
        self.mutate("AdGroupAdService", "ad_group_ads", [o])
        return rn, True

    def report(self):
        print("== SNS campaigns ==")
        for r in self.q("SELECT campaign.id, campaign.name, campaign.status, campaign_budget.amount_micros, campaign_budget.explicitly_shared, campaign.bidding_strategy_type FROM campaign WHERE campaign.name LIKE 'SNS | %' AND campaign.status != 'REMOVED' ORDER BY campaign.name"):
            c = r.campaign; b = r.campaign_budget
            n_ag = len(self.q(f"SELECT ad_group.id FROM ad_group WHERE campaign.id = {c.id} AND ad_group.status != 'REMOVED'"))
            n_kw = len(self.q(f"SELECT ad_group_criterion.criterion_id FROM ad_group_criterion WHERE campaign.id = {c.id} AND ad_group_criterion.type = 'KEYWORD' AND ad_group_criterion.negative = FALSE AND ad_group_criterion.status != 'REMOVED'"))
            n_ads = len(self.q(f"SELECT ad_group_ad.ad.id, ad_group_ad.policy_summary.approval_status FROM ad_group_ad WHERE campaign.id = {c.id} AND ad_group_ad.status != 'REMOVED'"))
            geo = [f"{x.campaign_criterion.proximity.radius:.0f}mi radius" if x.campaign_criterion.type_.name == "PROXIMITY" else x.campaign_criterion.location.geo_target_constant.split('/')[-1]
                   for x in self.q(f"SELECT campaign_criterion.type, campaign_criterion.proximity.radius, campaign_criterion.location.geo_target_constant FROM campaign_criterion WHERE campaign.id = {c.id} AND campaign_criterion.type IN ('LOCATION','PROXIMITY')")]
            print(f"{c.id} | {c.name} | {c.status.name} | ${b.amount_micros/1e6:.2f}/day{' shared' if b.explicitly_shared else ''} | {c.bidding_strategy_type.name} | {n_ag} ad groups | {n_kw} kws | {n_ads} ads | geo {','.join(geo) if len(geo) < 4 else str(len(geo)) + ' radii'}")
        print("== conversion actions ==")
        for r in self.q("SELECT conversion_action.id, conversion_action.name, conversion_action.category, conversion_action.primary_for_goal, conversion_action.status, conversion_action.tag_snippets FROM conversion_action WHERE conversion_action.status = 'ENABLED'"):
            a = r.conversion_action
            label = ""
            for s in a.tag_snippets:
                m = re.search(r"AW-\d+/([A-Za-z0-9_-]+)", s.event_snippet or "")
                if m: label = m.group(1); break
            print(f"{a.id} | {a.name} | {a.category.name} | primary={a.primary_for_goal} | {a.status.name} | label={label}")
        print("== negative lists ==")
        for r in self.q("SELECT shared_set.id, shared_set.name, shared_set.member_count FROM shared_set WHERE shared_set.status = 'ENABLED'"):
            print(f"{r.shared_set.id} | {r.shared_set.name} | {r.shared_set.member_count} terms")


def apply(p):
    b = Builder()
    print("conversion actions …")
    for name, cat, primary in p["conversion_actions"]:
        print("  ", b.conversion_action(name, cat, primary))
    print("negative list …")
    neg = b.negative_list("SNS | Negatives | Calligraphy classes", p["negatives"]); print("  ", neg)
    brand_neg = b.negative_list("SNS | Negatives | Brand terms (non-brand campaigns)", BRAND_NEGATIVES, "PHRASE"); print("  ", brand_neg)
    print("sitelinks …")
    links = b.sitelink_assets(); print("  ", len(links))
    budgets = {name: b.budget(name, amt, shared, [c["name"] for c in p["campaigns"] if c["budget"] == name])
               for name, (amt, shared) in p["budgets"].items()}
    for name, rn in budgets.items(): print("budget", name, "->", rn)
    portfolios = {name: b.portfolio("SNS | Portfolio | Max clicks $2 cap (Near Me shared budget)")
                  for name, (amt, shared) in p["budgets"].items() if shared}
    for c in p["campaigns"]:
        rn, new = b.campaign(c, budgets[c["budget"]], neg, portfolios.get(c["budget"]),
                             None if c["name"] == "SNS | Search | Brand" else brand_neg)
        print(("created " if new else "exists  ") + c["name"], "->", rn)
        b.attach_sitelinks(rn, links)
        for g in c["ad_groups"]:
            grn, gnew = b.ad_group(rn, g)
            print(f"    {'created' if gnew else 'exists '} ad group {g['name']} ({len(g['keywords'])} kws) -> {grn}")
    print(f"\ncreated {len(b.created)} top-level resources")
    b.report()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--apply", action="store_true"); ap.add_argument("--report", action="store_true")
    a = ap.parse_args()
    if a.report: Builder().report(); sys.exit(0)
    p = plan(); errs = validate(p); describe(p)
    if errs:
        print("\nVALIDATION ERRORS:"); [print("  -", e) for e in errs]; sys.exit(1)
    print("validation OK")
    if a.apply:
        from google.ads.googleads.errors import GoogleAdsException
        try: apply(p)
        except GoogleAdsException as e:
            for err in e.failure.errors: print("GoogleAdsException:", err.error_code, "-", err.message, "-", err.trigger, [str(x.field_name) for x in err.location.field_path_elements])
            sys.exit(1)
