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
    run_log_queries = [q for q in c.queries if "ops.run_log" in q[0]]
    assert len(run_log_queries) == 2
    # Verify column is named row_count, not rows (rows is a reserved keyword in GoogleSQL)
    for sql, _ in run_log_queries:
        assert "row_count" in sql and "status, row_count," in sql


def test_ensure_creates_tables_with_row_count():
    c = FakeBqClient(); s = LoadState(c, "sipandscript")
    s.ensure()
    # Verify DDL uses row_count INT64, not rows INT64
    run_log_ddl = [q[0] for q in c.queries if "ops.run_log" in q[0]][0]
    assert "row_count INT64" in run_log_ddl


def test_watermark_not_advanced_on_failure():
    c = FakeBqClient(); s = LoadState(c, "sipandscript")
    def failing():
        raise RuntimeError("append failed")
    run_step(s, "run-1", "cms.orders", failing)
    assert not any("load_state" in q[0] for q in c.queries)
