import datetime as dt
import json
from decimal import Decimal

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
    # The value sent for a JSON-typed BigQuery column must be a JSON object, not a pre-serialised
    # string -- a string value loads as a JSON scalar string (json_type = 'string'), not an object,
    # and defeats every downstream json_value(payload, '$.field') read. See loaders/common/bq.py.
    assert rows[0]["payload"] == {"a": 1} and not isinstance(rows[0]["payload"], str)
    assert rows[0]["_run_id"] == "run-1"


def test_append_payload_datetime_and_nested_dict_become_json_native():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    nested_payload = {
        "when": dt.datetime(2026, 9, 27, 12, 0, tzinfo=UTC),
        "nested": {"city": "Dallas", "tags": ["a", "b"], "count": 3, "ok": True, "missing": None},
    }
    w.append("raw_cms", "orders", [RawRow("k1", dt.datetime(2026, 9, 26, tzinfo=UTC), nested_payload)])
    _dest, rows = c.loads[0]
    payload = rows[0]["payload"]
    assert not isinstance(payload, str)
    assert payload["when"] == str(dt.datetime(2026, 9, 27, 12, 0, tzinfo=UTC))   # datetime -> plain string via default=str, not left as a datetime
    assert payload["nested"] == {"city": "Dallas", "tags": ["a", "b"], "count": 3, "ok": True, "missing": None}
    # The whole row list must be plain-JSON-dumpable without `default=` -- proves nothing non-native
    # (e.g. a datetime) leaked through into the value handed to the BigQuery client.
    json.dumps(rows)


def test_append_payload_non_finite_floats_become_null():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    payload = {
        "nan": float("nan"), "inf": float("inf"), "neg_inf": float("-inf"),
        "list": [float("nan"), 1, float("inf")],
        "nested": {"bad": float("-inf"), "ok": 2.5},
    }
    w.append("raw_cms", "orders", [RawRow("k1", dt.datetime(2026, 9, 26, tzinfo=UTC), payload)])
    _dest, rows = c.loads[0]
    stored = rows[0]["payload"]
    # json.dumps(..., default=str) does not route non-finite floats through `default` -- it emits
    # the bare tokens NaN/Infinity/-Infinity, which are not valid JSON and would make BigQuery
    # reject the whole batch over one bad field. They must come out the other side as JSON null.
    assert stored["nan"] is None and stored["inf"] is None and stored["neg_inf"] is None
    assert stored["list"] == [None, 1, None]
    assert stored["nested"] == {"bad": None, "ok": 2.5}
    # The whole row list must be valid, finite JSON -- allow_nan=False mirrors what BigQuery's own
    # JSON parser requires, so this proves a single bad numeric field can no longer poison the batch.
    json.dumps(rows, allow_nan=False)


def test_append_payload_decimal_and_date_become_strings():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    payload = {"amount": Decimal("12.50"), "day": dt.date(2026, 9, 27)}
    w.append("raw_cms", "orders", [RawRow("k1", dt.datetime(2026, 9, 26, tzinfo=UTC), payload)])
    _dest, rows = c.loads[0]
    stored = rows[0]["payload"]
    assert stored == {"amount": "12.50", "day": "2026-09-27"}
    assert isinstance(stored["amount"], str) and isinstance(stored["day"], str)


def test_append_empty_is_noop():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    assert w.append("raw_cms", "orders", []) == 0 and c.loads == []


def test_ensure_table_propagates_non_notfound_errors():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    c.get_table = lambda ref: (_ for _ in ()).throw(exceptions.Forbidden("nope"))
    with pytest.raises(exceptions.Forbidden, match="nope"):
        w.ensure_table("raw_cms", "orders")
    assert c.created_tables == []
