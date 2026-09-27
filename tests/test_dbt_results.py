from pathlib import Path

from loaders.common.dbt_results import DbtSummary, summarise_run_results
from loaders.common.slack import compose_run_status, should_post

FIX = Path(__file__).parent / "fixtures" / "dbt"


def test_success_counts_models_tests_and_warnings():
    s = summarise_run_results(FIX / "run_results_success.json")
    assert (s.models_ok, s.tests_ok, s.warned, s.failed_nodes, s.skipped, s.nodes) == (3, 2, 1, [], 0, 6)
    assert s.ok and s.line() == "dbt 3 models, 2 tests, 1 warn"


def test_failure_lists_failing_node_names_and_skips():
    s = summarise_run_results(FIX / "run_results_failure.json")
    assert s.failed_nodes == ["accepted_values_stg_cms__orders_status__Paid", "core_ad_spend"]
    assert (s.models_ok, s.tests_ok, s.skipped, s.nodes) == (1, 0, 2, 5) and not s.ok
    assert s.line() == "dbt 1 models, 0 tests, 2 skipped; 2 failed: accepted_values_stg_cms__orders_status__Paid, core_ad_spend"


def test_missing_file_is_a_summary_not_an_exception(tmp_path):
    s = summarise_run_results(tmp_path / "nope.json")
    assert s.error and "not found" in s.error and not s.ok and s.nodes == 0
    assert s.line().startswith("dbt: no run results")


def test_unreadable_file_is_a_summary_not_an_exception(tmp_path):
    p = tmp_path / "run_results.json"; p.write_text("{not json")
    s = summarise_run_results(p)
    assert s.error and "unreadable" in s.error


def test_line_caps_failures_at_ten():
    s = DbtSummary(failed_nodes=[f"n{i}" for i in range(13)])
    assert s.line().endswith("n9 (+3 more)") and "n10" not in s.line()


def test_compose_run_status_includes_dbt_line_when_given():
    text = compose_run_status("daily", 0, 1, "run-1", "sns-analytics loaders: cms 3", dbt_line="dbt 3 models, 2 tests")
    assert text.splitlines() == ["sns-analytics daily PROBLEMS — loaders rc=0, dbt rc=1, run run-1",
                                 "dbt 3 models, 2 tests", "sns-analytics loaders: cms 3"]


def test_should_post_hourly_only_on_problems():
    assert not should_post("hourly", 0, 0)
    assert should_post("hourly", 2, 0) and should_post("hourly", 0, 1)
    assert should_post("daily", 0, 0)
