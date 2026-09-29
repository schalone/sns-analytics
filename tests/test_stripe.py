import datetime as dt
import json

import stripe

from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from loaders.stripe_loader import OVERLAP, load_stripe
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


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
        # Real stripe-python objects (constructed locally, no network call) so serialisation is
        # exercised against the actual SDK shape rather than a hand-rolled dict stand-in.
        txn = stripe.BalanceTransaction.construct_from({
            "id": "txn_1", "object": "balance_transaction", "created": 1790336000, "type": "charge", "amount": 13600, "fee": 425, "net": 13175,
            "source": {"id": "ch_1", "object": "charge", "description": "Sip & Script - Order 70123",
                       "receipt_email": "jane@example.com", "billing_details": {"email": "jane@example.com", "name": "Jane Q Public"},
                       "metadata": {"CheckoutSessionKey": "22222222-2222-2222-2222-222222222222", "OrderId": "99887", "customer_name": "Jane Q Public"}},
        }, "sk_test_x")
        refund = stripe.Refund.construct_from({
            "id": "re_1", "created": 1758803600, "amount": 6800, "status": "succeeded",
        }, "sk_test_x")
        self.BalanceTransaction = _Resource([txn])
        self.Refund = _Resource([refund])
        self.Dispute = _Resource([]); self.Payout = _Resource([])


def _settings(): return Settings.from_env({"CMS_BASE_URL": "x", "STRIPE_RESTRICTED_KEY": "rk_test"})


def test_full_backfill_has_no_created_filter_and_stores_sanitised_payload():
    bq = FakeBqClient(); api = FakeStripe()
    res = load_stripe(_settings(), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), full=True, api=api)
    assert [r.status for r in res] == ["ok"] * 4
    assert api.BalanceTransaction.calls[0] == {"limit": 100, "expand": ["data.source"]}
    assert api.Refund.calls[0] == {"limit": 100}
    dest, rows = [l for l in bq.loads if l[0].endswith("raw_stripe.balance_transactions")][0]
    assert rows[0]["key"] == "txn_1" and rows[0]["updated_at"] == "2026-09-25T11:33:20+00:00"
    raw = json.dumps(rows[0]["payload"])
    for leaked in ("jane@example.com", "Jane Q Public", "99887", "Order 70123"):
        assert leaked not in raw
    payload = json.loads(raw)
    assert payload["source"]["metadata"] == {"CheckoutSessionKey": "22222222-2222-2222-2222-222222222222"}
    assert payload["source"]["order_ref"] == "70123"
    assert len(payload["source"]["customer_hash"]) == 64


def test_incremental_run_without_watermark_refuses_and_never_calls_stripe():
    # Without a watermark an incremental run would page the whole account history. It must refuse instead:
    # the history load is a deliberate one-off with --full.
    bq = FakeBqClient(); api = FakeStripe()
    res = load_stripe(_settings(), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), api=api)
    assert [r.status for r in res] == ["error"] * 4
    for r, entity in zip(res, ("balance_transactions", "refunds", "disputes", "payouts")):
        assert f"no Stripe watermark for {entity}: run once with --full to load history" in r.message
        assert r.rows == 0
    for resource in (api.BalanceTransaction, api.Refund, api.Dispute, api.Payout):
        assert resource.calls == []
    assert not [l for l in bq.loads if "raw_stripe" in l[0]]


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
