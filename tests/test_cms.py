import datetime as dt
import json
import pathlib

from loaders.cms import CmsClient, KEY_FIELD, OVERLAP, load_cms
from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from tests.fakes import FakeBqClient

FIX = pathlib.Path(__file__).parent / "fixtures"
UTC = dt.timezone.utc


class FakeHttp:
    """Maps (path, query) -> response body. Records every request."""
    def __init__(self, responses): self.responses, self.calls = responses, []
    def get(self, url, headers=None, params=None, timeout=None):
        self.calls.append((url, headers, dict(params or {})))
        key = (url.rsplit("/", 1)[-1], (params or {}).get("cursor"))
        body = self.responses[key]
        return _Resp(body)


class _Resp:
    def __init__(self, body): self._body, self.status_code = body, 200
    def raise_for_status(self): pass
    def json(self): return self._body


def _http_for_orders():
    p1 = json.loads((FIX / "cms_orders_page1.json").read_text()); p2 = json.loads((FIX / "cms_orders_page2.json").read_text())
    empty = {"entity": "x", "generatedAt": "2026-09-26T12:00:00Z", "items": [], "nextCursor": None}
    responses = {("orders", None): p1, ("orders", "c2"): p2}
    for e in ["order_items", "tickets", "refunds", "promo_redemptions", "gift_cards", "gift_card_transactions", "checkout_sessions", "events", "venues", "metros", "instructors"]:
        responses[(e, None)] = dict(empty, entity=e)
    return FakeHttp(responses)


def test_iter_pages_follows_cursor_and_sends_bearer():
    http = _http_for_orders(); c = CmsClient("https://cms.test", "tok", http=http)
    pages = list(c.iter_pages("orders", since=None, full=True))
    assert [len(p["items"]) for p in pages] == [2, 1]
    url, headers, params = http.calls[0]
    assert url == "https://cms.test/api/export/orders" and headers["Authorization"] == "Bearer tok"
    assert params == {"pageSize": 1000, "full": 1}
    assert http.calls[1][2]["cursor"] == "c2"


def test_load_cms_appends_rows_and_sets_watermark_with_overlap():
    http = _http_for_orders(); bq = FakeBqClient()
    settings = Settings.from_env({"CMS_BASE_URL": "https://cms.test", "CMS_EXPORT_TOKEN": "tok"})
    state = LoadState(bq, "sipandscript"); bq.query_results.extend([[]] * 12)     # no watermarks yet
    results = load_cms(settings, RawWriter(bq, "sipandscript", "run-1"), state, http=http, full=True)
    orders = [r for r in results if r.step == "cms.orders"][0]
    assert orders.status == "ok" and orders.rows == 3
    dest, rows = [l for l in bq.loads if l[0].endswith(".raw_cms.orders")][0]
    assert rows[0]["key"] == "11111111-1111-1111-1111-111111111111" and rows[1]["updated_at"] == "2026-09-25T12:30:00+00:00"
    merge = [q for q in bq.queries if "load_state" in q[0] and q[1].get("entity") == "orders"][0]
    assert merge[1]["watermark"] == dt.datetime(2026, 9, 25, 13, 1, tzinfo=UTC) - OVERLAP


def test_incremental_uses_since_from_watermark():
    http = _http_for_orders(); bq = FakeBqClient()
    settings = Settings.from_env({"CMS_BASE_URL": "https://cms.test", "CMS_EXPORT_TOKEN": "tok"})
    state = LoadState(bq, "sipandscript")
    wm = dt.datetime(2026, 9, 25, 8, 0, tzinfo=UTC)
    bq.query_results.extend([[{"watermark": wm, "cursor": None}]] + [[]] * 11)
    load_cms(settings, RawWriter(bq, "sipandscript", "run-1"), state, http=http, mode="hourly")
    first_orders_call = [c for c in http.calls if c[0].endswith("/orders")][0]
    assert first_orders_call[2]["since"] == "2026-09-25T08:00:00Z" and "full" not in first_orders_call[2]


def test_key_field_covers_every_entity():
    assert set(KEY_FIELD) == {"orders", "order_items", "tickets", "refunds", "promo_redemptions", "gift_cards", "gift_card_transactions", "checkout_sessions", "events", "venues", "metros", "instructors"}


def test_missing_token_is_a_step_error_not_a_crash():
    bq = FakeBqClient(); settings = Settings.from_env({"CMS_BASE_URL": "https://cms.test"})
    results = load_cms(settings, RawWriter(bq, "sipandscript", "run-1"), LoadState(bq, "sipandscript"), http=FakeHttp({}))
    assert all(r.status == "error" and "CMS_EXPORT_TOKEN" in r.message for r in results)
