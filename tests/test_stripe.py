import datetime as dt

from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from loaders.stripe_loader import BACKFILL_FROM, OVERLAP, load_stripe
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


class _Obj(dict):
    """Stripe objects behave like dicts with .id and to_dict()."""
    @property
    def id(self): return self["id"]
    def to_dict_recursive(self): return dict(self)


class _Resource:
    def __init__(self, items): self.items, self.calls = items, []
    def list(self, **kw):
        self.calls.append(kw)
        items = self.items
        class _L:
            def auto_paging_iter(_self): return iter(items)
        return _L()


class FakeStripe:
    def __init__(self):
        self.BalanceTransaction = _Resource([_Obj(id="txn_1", created=1790336000, type="charge", amount=13600, fee=425, net=13175, source=_Obj(id="ch_1", metadata={"OrderGuid": "1111"}))])
        self.Refund = _Resource([_Obj(id="re_1", created=1758803600, amount=6800, status="succeeded")])
        self.Dispute = _Resource([]); self.Payout = _Resource([])


def _settings(): return Settings.from_env({"CMS_BASE_URL": "x", "STRIPE_RESTRICTED_KEY": "rk_test"})


def test_full_backfill_starts_at_launch_and_expands_source():
    bq = FakeBqClient(); api = FakeStripe()
    res = load_stripe(_settings(), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), full=True, api=api)
    assert [r.status for r in res] == ["ok"] * 4
    assert api.BalanceTransaction.calls[0] == {"limit": 100, "created": {"gte": int(BACKFILL_FROM.timestamp())}, "expand": ["data.source"]}
    dest, rows = [l for l in bq.loads if l[0].endswith("raw_stripe.balance_transactions")][0]
    assert rows[0]["key"] == "txn_1" and rows[0]["updated_at"] == "2026-09-25T11:33:20+00:00"


def test_incremental_uses_watermark_minus_overlap():
    bq = FakeBqClient(); api = FakeStripe()
    wm = dt.datetime(2026, 9, 25, 0, 0, tzinfo=UTC)
    bq.query_results.extend([[{"watermark": wm, "cursor": None}]] * 8)
    load_stripe(_settings(), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), api=api)
    assert api.Refund.calls[0]["created"]["gte"] == int((wm - OVERLAP).timestamp())


def test_missing_key_is_step_error():
    bq = FakeBqClient(); s = Settings.from_env({"CMS_BASE_URL": "x"})
    res = load_stripe(s, RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), api=FakeStripe())
    assert all(r.status == "error" and "STRIPE_RESTRICTED_KEY" in r.message for r in res)
