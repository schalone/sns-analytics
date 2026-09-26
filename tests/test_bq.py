import datetime as dt
import json

import pytest
from google.api_core import exceptions

from loaders.common.bq import RawRow, RawWriter, RAW_SCHEMA
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


def test_schema_matches_contract():
    assert [f.name for f in RAW_SCHEMA] == ["key", "updated_at", "payload", "_loaded_at", "_run_id"]
    assert [f.field_type for f in RAW_SCHEMA] == ["STRING", "TIMESTAMP", "JSON", "TIMESTAMP", "STRING"]


def test_ensure_table_is_partitioned_and_clustered():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    w.ensure_table("raw_cms", "orders")
    t = c.created_tables[0]
    assert t.table_id == "orders" and t.time_partitioning.field == "_loaded_at" and t.clustering_fields == ["key"]


def test_append_serialises_rows_and_returns_count():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    n = w.append("raw_cms", "orders", [RawRow("k1", dt.datetime(2026, 9, 26, 1, 2, 3, tzinfo=UTC), {"a": 1})])
    assert n == 1
    dest, rows = c.loads[0]
    assert dest == "sipandscript.raw_cms.orders"
    assert rows[0]["key"] == "k1" and rows[0]["updated_at"] == "2026-09-26T01:02:03+00:00"
    assert json.loads(rows[0]["payload"]) == {"a": 1} and rows[0]["_run_id"] == "run-1"


def test_append_empty_is_noop():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    assert w.append("raw_cms", "orders", []) == 0 and c.loads == []


def test_ensure_table_propagates_non_notfound_errors():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    c.get_table = lambda ref: (_ for _ in ()).throw(exceptions.Forbidden("nope"))
    with pytest.raises(exceptions.Forbidden, match="nope"):
        w.ensure_table("raw_cms", "orders")
    assert c.created_tables == []
