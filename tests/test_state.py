import datetime as dt

from loaders.common.state import LoadState, Watermark, run_step
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


def test_get_returns_none_when_missing():
    c = FakeBqClient(); c.query_results.append([])
    assert LoadState(c, "sipandscript").get("cms", "orders") is None


def test_get_parses_row():
    c = FakeBqClient(); c.query_results.append([{"watermark": dt.datetime(2026, 9, 25, tzinfo=UTC), "cursor": "abc"}])
    assert LoadState(c, "sipandscript").get("cms", "orders") == Watermark(dt.datetime(2026, 9, 25, tzinfo=UTC), "abc")


def test_set_uses_merge_with_params():
    c = FakeBqClient(); LoadState(c, "sipandscript").set("cms", "orders", dt.datetime(2026, 9, 25, tzinfo=UTC), "abc")
    sql, params = c.queries[-1]
    assert "MERGE `sipandscript.ops.load_state`" in sql and params == {"source": "cms", "entity": "orders", "watermark": dt.datetime(2026, 9, 25, tzinfo=UTC), "cursor": "abc"}


def test_run_step_logs_success_and_failure():
    c = FakeBqClient(); s = LoadState(c, "sipandscript")
    ok = run_step(s, "run-1", "cms.orders", lambda: 12)
    bad = run_step(s, "run-1", "stripe.refunds", lambda: (_ for _ in ()).throw(RuntimeError("boom")))
    assert (ok.status, ok.rows) == ("ok", 12)
    assert (bad.status, bad.rows) == ("error", 0) and "boom" in bad.message
    assert len([q for q in c.queries if "ops.run_log" in q[0]]) == 2


def test_watermark_not_advanced_on_failure():
    c = FakeBqClient(); s = LoadState(c, "sipandscript")
    def failing():
        raise RuntimeError("append failed")
    run_step(s, "run-1", "cms.orders", failing)
    assert not any("load_state" in q[0] for q in c.queries)
