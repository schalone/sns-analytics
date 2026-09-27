import datetime as dt

from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from loaders.gsc import DIMENSION_SETS, load_gsc, row_key
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


class FakeGsc:
    def __init__(self): self.calls = []
    def searchanalytics(self): return self
    def query(self, siteUrl, body):
        self.calls.append((siteUrl, body))
        class _E:
            def execute(_self):
                if body["startRow"] > 0:
                    return {}
                return {"rows": [{"keys": [body["startDate"], "https://www.sipandscript.com/metros/dallas/", "calligraphy classes dallas"] if len(body["dimensions"]) == 3
                                  else [body["startDate"], "https://www.sipandscript.com/", "MOBILE", "usa"], "clicks": 3, "impressions": 40, "ctr": 0.075, "position": 4.2}]}
        return _E()


def test_row_key_is_stable_and_property_scoped():
    a = row_key("https://sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])
    b = row_key("https://www.sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])
    assert a != b and len(a) == 40 and a == row_key("https://sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])


def test_gsc_key_and_updated_at():
    bq = FakeBqClient(); svc = FakeGsc(); today = dt.date(2026, 9, 26)
    s = Settings.from_env({"CMS_BASE_URL": "x"})
    bq.query_results.extend([[{"watermark": dt.datetime(2026, 9, 24, tzinfo=UTC), "cursor": None}]] * 12)
    res = load_gsc(s, RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), service=svc, today=today)
    assert all(r.status == "ok" for r in res)
    # window = watermark - 3 days .. today - 2 (GSC data is final ~2 days later)
    dates = sorted({c[1]["startDate"] for c in svc.calls})
    assert dates[0] == "2026-09-21" and dates[-1] == "2026-09-24"
    dest, rows = [l for l in bq.loads if l[0].endswith("raw_gsc.page_query")][0]
    assert rows[0]["updated_at"].startswith("2026-09-26")           # updated_at = load day, so a restated day supersedes older loads
    assert rows[0]["key"] == row_key("https://sipandscript.com/", DIMENSION_SETS["page_query"], ["2026-09-21", "https://www.sipandscript.com/metros/dallas/", "calligraphy classes dallas"])


def test_full_backfills_480_days():
    bq = FakeBqClient(); svc = FakeGsc(); today = dt.date(2026, 9, 26)
    load_gsc(Settings.from_env({"CMS_BASE_URL": "x"}), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), full=True, service=svc, today=today)
    assert min(c[1]["startDate"] for c in svc.calls) == "2025-06-03"
