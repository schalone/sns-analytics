import datetime as dt

from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import Watermark
from loaders.gsc import DIMENSION_SETS, OVERLAP_DAYS, load_gsc, row_key, step_name_for
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc
SAMPLE = {"page": "https://www.sipandscript.com/metros/dallas/", "query": "calligraphy classes dallas",
          "device": "MOBILE", "country": "usa"}


class FakeGsc:
    """Returns one row per (day, dimension set); raises on `fail_on` (an ISO date) when given."""
    def __init__(self, fail_on: str | None = None):
        self.calls = []; self.fail_on = fail_on
    def searchanalytics(self): return self
    def query(self, siteUrl, body):
        self.calls.append((siteUrl, body))
        fail_on = self.fail_on
        class _E:
            def execute(_self):
                if fail_on and body["startDate"] == fail_on:
                    raise RuntimeError("quota exceeded")
                if body["startRow"] > 0:
                    return {}
                keys = [body["startDate"] if d == "date" else SAMPLE[d] for d in body["dimensions"]]
                return {"rows": [{"keys": keys, "clicks": 3, "impressions": 40, "ctr": 0.075, "position": 4.2}]}
        return _E()


class MemState:
    """In-memory LoadState: records every watermark write and every run_log row."""
    def __init__(self, marks=None):
        self.marks = dict(marks or {}); self.sets = []; self.logs = []
    def get(self, source, entity):
        return self.marks.get((source, entity))
    def set(self, source, entity, updated_at, cursor=None):
        self.marks[(source, entity)] = Watermark(updated_at, cursor); self.sets.append((entity, updated_at.date()))
    def log(self, run_id, step, status, rows, message=""):
        self.logs.append((step, status, rows))


def _settings(**kw):
    s = Settings.from_env({"CMS_BASE_URL": "x"})
    return s if not kw else Settings(**{**s.__dict__, **kw})


def test_row_key_is_stable_and_property_scoped():
    a = row_key("https://sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])
    b = row_key("https://www.sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])
    assert a != b and len(a) == 40 and a == row_key("https://sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])


def test_dimension_sets_are_the_complete_totals_plus_partial_page_query():
    assert DIMENSION_SETS == {"totals": ["date"], "page": ["date", "page"], "device_country": ["date", "device", "country"],
                              "page_query": ["date", "page", "query"]}


def test_gsc_key_and_updated_at():
    bq = FakeBqClient(); svc = FakeGsc(); today = dt.date(2026, 9, 26)
    s = _settings()
    wm = Watermark(dt.datetime(2026, 9, 24, tzinfo=UTC))
    state = MemState({("gsc", step_name_for(n, p)): wm for n in DIMENSION_SETS for p in s.gsc_properties})
    res = load_gsc(s, RawWriter(bq, "sipandscript", "r"), state, service=svc, today=today)
    assert [r.step for r in res] == [f"gsc.{n}.{p}" for p in ("apex", "www") for n in DIMENSION_SETS]
    assert all(r.status == "ok" for r in res)
    # window = watermark - 3 days .. today - 2 (GSC data is final ~2 days later)
    dates = sorted({c[1]["startDate"] for c in svc.calls})
    assert dates[0] == "2026-09-21" and dates[-1] == "2026-09-24"
    dest, rows = [l for l in bq.loads if l[0].endswith("raw_gsc.page_query")][0]
    assert rows[0]["updated_at"].startswith("2026-09-26")           # updated_at = load day, so a restated day supersedes older loads
    assert rows[0]["key"] == row_key("https://sipandscript.com/", DIMENSION_SETS["page_query"], ["2026-09-21", SAMPLE["page"], SAMPLE["query"]])
    tot = [l for l in bq.loads if l[0].endswith("raw_gsc.totals")][0][1][0]
    assert tot["payload"] == {"property": "https://sipandscript.com/", "date": "2026-09-21", "clicks": 3, "impressions": 40, "ctr": 0.075, "position": 4.2}
    assert {l[0].rsplit(".", 1)[1] for l in bq.loads} == set(DIMENSION_SETS)


def test_full_backfills_480_days():
    bq = FakeBqClient(); svc = FakeGsc(); today = dt.date(2026, 9, 26)
    load_gsc(_settings(), RawWriter(bq, "sipandscript", "r"), MemState(), full=True, service=svc, today=today)
    assert min(c[1]["startDate"] for c in svc.calls) == "2025-06-03"


def test_sets_restricts_the_dimension_sets_loaded():
    bq = FakeBqClient(); svc = FakeGsc(); today = dt.date(2026, 9, 26)
    res = load_gsc(_settings(), RawWriter(bq, "sipandscript", "r"), MemState(), full=True, service=svc, today=today,
                   sets=["totals", "page", "device_country"])
    assert {r.step.split(".")[1] for r in res} == {"totals", "page", "device_country"}
    assert all(c[1]["dimensions"] != ["date", "page", "query"] for c in svc.calls)


def test_interrupted_backfill_keeps_per_day_watermark_and_resumes():
    """A service error on the third day: two days loaded, watermark at day two, step error; the next run
    starts OVERLAP_DAYS before the watermark (day two), not at the start of the backfill again."""
    today = dt.date(2026, 9, 26); end = today - dt.timedelta(days=2)
    day1 = end - dt.timedelta(days=5); day2 = day1 + dt.timedelta(days=1); day3 = day2 + dt.timedelta(days=1)
    s = _settings(gsc_properties=("https://www.sipandscript.com/",))
    step = step_name_for("totals", s.gsc_properties[0])
    state = MemState({("gsc", step): Watermark(dt.datetime.combine(day1 + dt.timedelta(days=OVERLAP_DAYS), dt.time(), tzinfo=UTC))})
    bq = FakeBqClient(); svc = FakeGsc(fail_on=day3.isoformat())
    res = load_gsc(s, RawWriter(bq, "sipandscript", "r"), state, service=svc, today=today, sets=["totals"])
    assert [(r.step, r.status) for r in res] == [(step, "error")]
    assert "quota exceeded" in res[0].message
    assert len(bq.loads) == 2                                         # day one and day two were written
    assert state.sets == [(step, day1), (step, day2)]                 # watermark advanced per day, stopped at day two
    assert state.get("gsc", step).updated_at.date() == day2

    svc2 = FakeGsc()
    res2 = load_gsc(s, RawWriter(FakeBqClient(), "sipandscript", "r"), state, service=svc2, today=today, sets=["totals"])
    assert res2[0].status == "ok"
    assert min(c[1]["startDate"] for c in svc2.calls) == (day2 - dt.timedelta(days=OVERLAP_DAYS)).isoformat()
    assert state.get("gsc", step).updated_at.date() == end
