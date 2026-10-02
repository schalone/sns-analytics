"""Tests for brief.warehouse: warehouse-backed data for the morning brief.

Reference structure (documented in .superpowers/sdd/2026-09-26-analytics-pipeline/brief-ref/ga_report.py,
function `report_data(key_file=None, today=None)`), which `brief.warehouse.report_data(bq, today)` must match
key by key:

    {
        "text": str,                                   # build_text(y, wk, channels, landing, when)
        "fields": [(label: str, value: str), ...],      # headline_fields(*y) -- exactly 5 pairs, in order:
                                                         # Sessions, Orders, Revenue, Conversion rate, Avg order
        "flags": [str, ...],                            # flags(*y) -- zero or more warning lines
        "series": [(date, sessions: int, orders: int), ...],  # daily_series(ga, today) -- 28 days ending yesterday
        "when": date,                                   # yesterday's date
    }

Where `y = (cur, prev)` compares yesterday with the same weekday last week, and the "Last 7 days vs prior 7"
text line (folded into "text") compares the 7 days ending yesterday with the preceding 7 days.

Every query against the warehouse takes `business_date`/`session_date` bounds as bind parameters (never
interpolated date literals), per the brief's date-window rules; this file checks both the shapes and that
parameterisation.
"""
from __future__ import annotations

import datetime as dt
import re

import brief.warehouse as w
from tests.fakes import FakeBqClient


class _Job:
    def __init__(self, rows):
        self._rows = rows

    def result(self):
        return self._rows


class ScriptedBq:
    """Fake BigQuery client that dispatches canned rows by inspecting each query's shape and its bound date
    parameters, rather than by call order -- report_data() issues several differently-shaped queries and this
    keeps the test independent of the order they're issued in."""

    def __init__(self, windows=None, channel_rows=None, landing_rows=None, series_rows=None):
        self.windows = windows or {}          # {(start, end): [row_dict]} for the single-row headline query
        self.channel_rows = channel_rows or []
        self.landing_rows = landing_rows or []
        self.series_rows = series_rows or []
        self.queries: list[tuple[str, dict]] = []

    def query(self, sql, job_config=None):
        params = {p.name: p.value for p in (job_config.query_parameters if job_config else [])}
        self.queries.append((sql, params))
        if "landing_page_path" in sql:
            rows = self.landing_rows
        elif "channel_group" in sql:
            rows = self.channel_rows
        elif "business_date as d" in sql:
            rows = self.series_rows
        else:
            rows = self.windows.get((params.get("start_date"), params.get("end_date")), [])
        return _Job(rows)


ALL_CHANNELS = ["Organic Search", "Paid Search", "Paid Social", "Organic Social", "Direct", "Email", "Referral", "Other", "Unattributed"]

DATE_LITERAL = re.compile(r"\d{4}-\d{2}-\d{2}")


def _assert_no_date_literals(queries):
    for sql, params in queries:
        assert not DATE_LITERAL.search(sql), f"date literal leaked into SQL: {sql!r}"
        assert "@" in sql, f"query has no bind parameters: {sql!r}"


# --------------------------------------------------------------------------- headline_dict ---
def test_headline_dict_shape_and_keys():
    bq = FakeBqClient()
    bq.query_results.append([{"sessions": 1200, "purchases": 31, "revenue": 2790.5, "unreliable_ga4": False}])
    d = w.headline_dict(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    assert d == {"sessions": 1200, "users": 1200, "purchases": 31, "revenue": 2790.5, "ticket_revenue": 0, "unreliable_ga4": False}


def test_headline_dict_treats_missing_row_as_zero():
    bq = FakeBqClient()
    bq.query_results.append([{"sessions": None, "purchases": None, "revenue": None, "unreliable_ga4": None}])
    d = w.headline_dict(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    assert d == {"sessions": 0, "users": 0, "purchases": 0, "revenue": 0, "ticket_revenue": 0, "unreliable_ga4": False}


def test_headline_dict_returns_unreliable_ga4_true_when_flagged():
    bq = FakeBqClient()
    bq.query_results.append([{"sessions": 100, "purchases": 5, "revenue": 300.0, "unreliable_ga4": True}])
    d = w.headline_dict(bq, dt.date(2026, 6, 19), dt.date(2026, 6, 22))
    assert d["unreliable_ga4"] is True


def test_headline_dict_query_rolls_up_unreliable_ga4_with_logical_or():
    bq = FakeBqClient()
    w.headline_dict(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    sql, _ = bq.queries[0]
    assert "logical_or(unreliable_ga4)" in sql


def test_headline_dict_queries_mart_daily_kpis_without_metro_filter():
    """Session rows always carry metro_key IS NULL and metro rows carry orders/revenue only, so summing every
    row of the day (not just metro_key IS NULL rows) gives the day's true totals without dropping
    metro-attributed orders. Filtering to metro_key IS NULL here would silently undercount orders/revenue."""
    bq = FakeBqClient()
    bq.query_results.append([{"sessions": 10, "purchases": 1, "revenue": 65.0}])
    w.headline_dict(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    sql, params = bq.queries[0]
    assert "mart.mart_daily_kpis" in sql
    assert "metro_key" not in sql
    assert "pre_launch" not in sql
    assert params == {"start_date": dt.date(2026, 9, 24), "end_date": dt.date(2026, 9, 24)}


def test_headline_dict_sums_ticket_orders_and_net_revenue():
    bq = FakeBqClient()
    w.headline_dict(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    sql, _ = bq.queries[0]
    assert "ticket_orders" in sql and "net_revenue" in sql


# --------------------------------------------------------------------------- channels ---
def test_channels_shape_includes_every_fixed_channel_even_if_zero():
    bq = FakeBqClient()
    bq.query_results.append([{"channel_group": "Paid Search", "sessions": 10, "purchases": 1, "revenue": 65.0}])
    ch = w.channels(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    assert set(ch) == set(ALL_CHANNELS)
    assert ch["Paid Search"] == (10, 1, 65.0)
    assert ch["Email"] == (0, 0, 0.0)


def test_channels_include_other_and_unattributed_and_ignore_unknown_groups():
    bq = FakeBqClient()
    bq.query_results.append([
        {"channel_group": "Other", "sessions": 673, "purchases": 0, "revenue": 0.0},
        {"channel_group": "Unattributed", "sessions": 0, "purchases": 2, "revenue": 130.0},
        {"channel_group": "Direct", "sessions": 274, "purchases": 0, "revenue": 0.0},
        {"channel_group": "Something New", "sessions": 5, "purchases": 0, "revenue": 0.0},
    ])
    ch = w.channels(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    assert set(ch) == set(ALL_CHANNELS)
    assert ch["Other"] == (673, 0, 0.0) and ch["Unattributed"] == (0, 2, 130.0) and ch["Direct"] == (274, 0, 0.0)


def test_headline_dict_sums_ticket_net_revenue_for_aov():
    bq = FakeBqClient()
    bq.query_results.append([{"sessions": 100, "purchases": 4, "revenue": 500.0, "ticket_revenue": 300.0, "unreliable_ga4": False}])
    d = w.headline_dict(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    assert "sum(ticket_net_revenue)" in bq.queries[0][0]
    assert d["ticket_revenue"] == 300.0


def test_aov_divides_ticket_revenue_by_ticket_orders():
    """Revenue includes gift-card orders; AOV must use the ticket-only numerator so it matches the ticket-order
    denominator."""
    cur = {"sessions": 100, "purchases": 4, "revenue": 500.0, "ticket_revenue": 300.0, "unreliable_ga4": False}
    prev = {"sessions": 100, "purchases": 0, "revenue": 50.0, "ticket_revenue": 0, "unreliable_ga4": False}
    fields = dict(w._headline_fields(cur, prev))
    assert fields["Avg order"] == "$75 (was $0)"


def test_channels_groups_by_channel_group_without_metro_filter():
    bq = FakeBqClient()
    w.channels(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    sql, params = bq.queries[0]
    assert "mart.mart_daily_kpis" in sql and "channel_group" in sql and "metro_key" not in sql
    assert params == {"start_date": dt.date(2026, 9, 24), "end_date": dt.date(2026, 9, 24)}


# --------------------------------------------------------------------------- landing ---
def test_landing_shape_is_page_sessions_purchases_tuples():
    bq = FakeBqClient()
    bq.query_results.append([
        {"page": "/metros/boston/", "sessions": 40, "purchases": 2},
        {"page": "/", "sessions": 900, "purchases": 5},
    ])
    lp = w.landing(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24), limit=8)
    assert lp == [("/metros/boston/", 40, 2), ("/", 900, 5)]


def test_landing_queries_core_sessions_and_binds_limit():
    bq = FakeBqClient()
    w.landing(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24), limit=8)
    sql, params = bq.queries[0]
    assert "core.core_sessions" in sql and "core.core_session_orders" in sql and "core.core_orders" in sql
    assert "order_type" in sql and "ticket" in sql
    assert params["limit_n"] == 8
    assert params["start_date"] == dt.date(2026, 9, 24) and params["end_date"] == dt.date(2026, 9, 24)


def test_landing_uses_distinct_counts_not_row_counts_to_avoid_join_fanout():
    """core_session_orders holds one row per ORDER (not per session), so a session that produced more than
    one order joins to more than one row here; count(*) would count that single session once per order it
    produced. A fake result can't prove real join-fanout semantics either way (it just returns whatever rows
    it's told to), so this checks the SQL shape directly -- both measures must be count(distinct ...), and
    plain count(*) must not appear at all. Verified against real join-fanout behaviour separately, against
    the live warehouse (see task-15-report.md's fix-round-1 section)."""
    bq = FakeBqClient()
    w.landing(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    sql, _ = bq.queries[0]
    assert sql.count("count(distinct") == 2
    assert "count(*)" not in sql


def test_landing_excludes_noise_pages():
    bq = FakeBqClient()
    w.landing(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    sql, _ = bq.queries[0]
    assert "'(not set)'" in sql and "'/order-confirmation'" in sql


def test_landing_default_limit_is_10():
    bq = FakeBqClient()
    w.landing(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    _, params = bq.queries[0]
    assert params["limit_n"] == 10


# --------------------------------------------------------------------------- daily_series ---
def test_daily_series_fills_missing_days_with_zero():
    bq = FakeBqClient()
    bq.query_results.append([{"d": dt.date(2026, 9, 24), "sessions": 5, "orders": 1}])
    s = w.daily_series(bq, dt.date(2026, 9, 26), days=3)
    assert [(x[0].isoformat(), x[1], x[2]) for x in s] == [
        ("2026-09-23", 0, 0),
        ("2026-09-24", 5, 1),
        ("2026-09-25", 0, 0),
    ]


def test_daily_series_window_ends_yesterday():
    bq = FakeBqClient()
    w.daily_series(bq, dt.date(2026, 9, 26), days=28)
    _, params = bq.queries[0]
    assert params == {"start_date": dt.date(2026, 8, 29), "end_date": dt.date(2026, 9, 25)}


def test_daily_series_default_days_is_28():
    bq = FakeBqClient()
    s = w.daily_series(bq, dt.date(2026, 9, 26))
    assert len(s) == 28
    assert s[0][0] == dt.date(2026, 8, 29) and s[-1][0] == dt.date(2026, 9, 25)


# --------------------------------------------------------------------------- report_data ---
def test_report_data_matches_ga_report_structure_key_by_key():
    today = dt.date(2026, 9, 26)          # yesterday = 09-25 (Fri); same weekday last week = 09-18
    y_cur, y_prev = dt.date(2026, 9, 25), dt.date(2026, 9, 18)
    wk_cur = (dt.date(2026, 9, 19), dt.date(2026, 9, 25))
    wk_prev = (dt.date(2026, 9, 12), dt.date(2026, 9, 18))
    bq = ScriptedBq(
        windows={
            (y_cur, y_cur): [{"sessions": 1000, "purchases": 20, "revenue": 1300.0, "unreliable_ga4": False}],
            (y_prev, y_prev): [{"sessions": 1200, "purchases": 30, "revenue": 1950.0, "unreliable_ga4": False}],
            (wk_cur[0], wk_cur[1]): [{"sessions": 7000, "purchases": 140, "revenue": 9100.0, "unreliable_ga4": False}],
            (wk_prev[0], wk_prev[1]): [{"sessions": 8400, "purchases": 210, "revenue": 13650.0, "unreliable_ga4": False}],
        },
        channel_rows=[{"channel_group": "Paid Search", "sessions": 10, "purchases": 1, "revenue": 65.0}],
        landing_rows=[{"page": "/metros/boston/", "sessions": 40, "purchases": 2}],
        series_rows=[{"d": y_cur, "sessions": 1000, "orders": 20}],
    )
    data = w.report_data(bq, today)

    assert set(data) == {"text", "fields", "flags", "series", "when"}
    assert data["when"] == y_cur
    assert isinstance(data["text"], str) and data["text"]
    assert isinstance(data["fields"], list) and len(data["fields"]) == 5
    assert [label for label, _ in data["fields"]] == ["Sessions", "Orders", "Revenue", "Conversion rate", "Avg order"]
    assert all(isinstance(label, str) and isinstance(value, str) for label, value in data["fields"])
    assert isinstance(data["flags"], list) and all(isinstance(f, str) for f in data["flags"])
    assert isinstance(data["series"], list) and len(data["series"]) == 28
    for d, sessions, orders in data["series"]:
        assert isinstance(d, dt.date) and isinstance(sessions, int) and isinstance(orders, int)

    # date windows: yesterday vs same weekday last week, last 7 days vs prior 7
    assert "1,000 sessions" in data["text"]          # yesterday's sessions
    assert "-17%" in data["text"]                    # 1000 vs 1200 => pct(1000, 1200)
    assert "Paid Search" in data["text"]
    assert "/metros/boston/" in data["text"]


def test_report_data_flags_zero_orders_despite_traffic():
    today = dt.date(2026, 9, 26)
    y_cur, y_prev = dt.date(2026, 9, 25), dt.date(2026, 9, 18)
    bq = ScriptedBq(windows={
        (y_cur, y_cur): [{"sessions": 500, "purchases": 0, "revenue": 0.0}],
        (y_prev, y_prev): [{"sessions": 480, "purchases": 10, "revenue": 650.0}],
        (dt.date(2026, 9, 19), dt.date(2026, 9, 25)): [{"sessions": 3000, "purchases": 10, "revenue": 650.0}],
        (dt.date(2026, 9, 12), dt.date(2026, 9, 18)): [{"sessions": 3000, "purchases": 10, "revenue": 650.0}],
    })
    data = w.report_data(bq, today)
    assert any("zero orders despite traffic" in f for f in data["flags"])


def test_report_data_flags_and_hides_cvr_when_window_has_unreliable_ga4():
    today = dt.date(2026, 9, 26)
    y_cur, y_prev = dt.date(2026, 9, 25), dt.date(2026, 9, 18)
    wk_cur = (dt.date(2026, 9, 19), dt.date(2026, 9, 25))
    wk_prev = (dt.date(2026, 9, 12), dt.date(2026, 9, 18))
    bq = ScriptedBq(windows={
        (y_cur, y_cur): [{"sessions": 1000, "purchases": 20, "revenue": 1300.0, "unreliable_ga4": True}],
        (y_prev, y_prev): [{"sessions": 1200, "purchases": 30, "revenue": 1950.0, "unreliable_ga4": False}],
        (wk_cur[0], wk_cur[1]): [{"sessions": 7000, "purchases": 140, "revenue": 9100.0, "unreliable_ga4": False}],
        (wk_prev[0], wk_prev[1]): [{"sessions": 8400, "purchases": 210, "revenue": 13650.0, "unreliable_ga4": False}],
    })
    data = w.report_data(bq, today)
    assert any("unreliable GA4 tracking" in f for f in data["flags"])
    fields = dict(data["fields"])
    assert fields["Conversion rate"] == "n/a (was 2.50%)"
    assert "CVR n/a (was 2.50%)" in data["text"]
    # sessions/orders/revenue must still be real numbers, not suppressed by the flag
    assert "1,000 sessions" in data["text"] and "20 orders" in data["text"] and "$1,300" in data["text"]


def test_report_data_no_unreliable_flag_or_na_cvr_when_window_is_clean():
    today = dt.date(2026, 9, 26)
    y_cur, y_prev = dt.date(2026, 9, 25), dt.date(2026, 9, 18)
    wk_cur = (dt.date(2026, 9, 19), dt.date(2026, 9, 25))
    wk_prev = (dt.date(2026, 9, 12), dt.date(2026, 9, 18))
    bq = ScriptedBq(windows={
        (y_cur, y_cur): [{"sessions": 1000, "purchases": 20, "revenue": 1300.0, "unreliable_ga4": False}],
        (y_prev, y_prev): [{"sessions": 1200, "purchases": 30, "revenue": 1950.0, "unreliable_ga4": False}],
        (wk_cur[0], wk_cur[1]): [{"sessions": 7000, "purchases": 140, "revenue": 9100.0, "unreliable_ga4": False}],
        (wk_prev[0], wk_prev[1]): [{"sessions": 8400, "purchases": 210, "revenue": 13650.0, "unreliable_ga4": False}],
    })
    data = w.report_data(bq, today)
    assert not any("unreliable GA4 tracking" in f for f in data["flags"])
    fields = dict(data["fields"])
    assert fields["Conversion rate"] == "2.00% (was 2.50%)"
    assert "n/a" not in data["text"]


def test_report_data_windows_are_bound_parameters_not_string_literals():
    today = dt.date(2026, 9, 26)
    bq = ScriptedBq()
    w.report_data(bq, today)
    _assert_no_date_literals(bq.queries)
    # every date bound passed to a query is a real date object, not a formatted string
    for _, params in bq.queries:
        for k, v in params.items():
            if k in ("start_date", "end_date"):
                assert isinstance(v, dt.date)


def test_report_data_when_is_today_minus_one_day():
    bq = ScriptedBq()
    result = w.report_data(bq, dt.date(2026, 9, 27))
    assert result["when"] == dt.date(2026, 9, 26)


def test_report_data_today_defaults_to_now_in_new_york_when_omitted():
    # No real-time/network dependency required elsewhere in this suite -- this only proves the `today=None`
    # branch (matching ga_report.report_data's own default) resolves to *some* date and doesn't raise, without
    # asserting an exact value that would make the test flaky near a US/Eastern midnight rollover.
    bq = ScriptedBq()
    result = w.report_data(bq, None)
    assert isinstance(result["when"], dt.date)


# --------------------------------------------------------------------------- parameterisation, across the board ---
def test_all_functions_parameterise_every_query():
    bq = FakeBqClient()
    bq.query_results.extend([[], [], [], []])
    w.headline_dict(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    w.channels(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    w.landing(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    w.daily_series(bq, dt.date(2026, 9, 26), days=3)
    _assert_no_date_literals(bq.queries)


# --------------------------------------------------------------------------- ruling 4: no pre_launch, ever ---
def test_no_query_or_function_body_references_pre_launch():
    """The module docstring is allowed to *talk about* pre_launch (explaining why it's avoided, for the
    column's future rename to platform_era) -- but no function body, and in particular no SQL text, may
    actually reference it."""
    import inspect

    for fn in (w.headline_dict, w.channels, w.landing, w.daily_series, w.report_data, w._rows,
               w._pct, w._money, w._cvr_str, w._headline, w._headline_fields, w._flags, w._build_text):
        assert "pre_launch" not in inspect.getsource(fn), f"{fn.__name__} references pre_launch"
