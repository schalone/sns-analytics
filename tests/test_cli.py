from loaders.__main__ import main, parse_args, summarise
from loaders.common.slack import compose_run_status, post_status
from loaders.common.state import StepResult


def test_summarise_counts_rows_per_source_and_lists_errors():
    res = [StepResult("cms.orders", "ok", 412), StepResult("cms.tickets", "ok", 900), StepResult("stripe.refunds", "error", 0, "RuntimeError: boom"),
           StepResult("gsc.page_query.www", "ok", 21530)]
    text = summarise(res)
    assert text.startswith("sns-analytics loaders: ") and "cms 1,312" in text and "gsc 21,530" in text
    assert "⚠ stripe.refunds: RuntimeError: boom" in text


def test_parse_args_defaults():
    a = parse_args(["run"])
    assert a.sources == ["cms", "stripe", "gsc", "spend"] and a.mode == "daily" and not a.full
    assert parse_args(["run", "--sources", "cms", "--mode", "hourly"]).sources == ["cms"]


def test_post_status_without_token_prints_and_makes_no_http_call(monkeypatch, capsys):
    from loaders.common.config import Settings

    def _boom(*args, **kwargs):
        raise AssertionError("requests.post must not be called when there is no Slack token")

    monkeypatch.setattr("loaders.common.slack.requests.post", _boom)
    settings = Settings.from_env({"CMS_BASE_URL": "https://x"})
    assert settings.slack_bot_token is None

    post_status(settings, "sns-analytics daily OK — loaders rc=0, dbt rc=0, run local-abc")

    out = capsys.readouterr().out
    assert out.strip() == "sns-analytics daily OK — loaders rc=0, dbt rc=0, run local-abc"


def test_summarise_tolerates_empty_error_message():
    text = summarise([StepResult("x.y", "error", 0, "")])
    assert "⚠ x.y: " in text


def test_compose_run_status_ok_appends_summary_on_next_line():
    text = compose_run_status("daily", 0, 0, "run-1", "sns-analytics loaders: cms 3")
    assert text.startswith("sns-analytics daily OK — loaders rc=0, dbt rc=0, run run-1")
    lines = text.splitlines()
    assert lines[1] == "sns-analytics loaders: cms 3"


def test_compose_run_status_problems_when_any_rc_nonzero():
    text = compose_run_status("daily", 2, 0, "run-1", "")
    assert text.startswith("sns-analytics daily PROBLEMS — loaders rc=2, dbt rc=0, run run-1")


def test_compose_run_status_empty_summary_is_single_line():
    text = compose_run_status("hourly", 0, 0, "run-2", "")
    assert "\n" not in text
    assert text == "sns-analytics hourly OK — loaders rc=0, dbt rc=0, run run-2"


def test_main_guards_setup_failure_writes_summary_and_never_posts_slack(monkeypatch, tmp_path):
    summary_file = tmp_path / "summary.txt"
    monkeypatch.setenv("CMS_BASE_URL", "https://x")
    monkeypatch.setenv("LOADERS_SUMMARY_FILE", str(summary_file))
    monkeypatch.delenv("SLACK_BOT_TOKEN", raising=False)

    def _boom(*args, **kwargs):
        raise AssertionError("requests.post must not be called on a guarded setup failure")

    monkeypatch.setattr("loaders.common.slack.requests.post", _boom)

    def failing_client_factory():
        raise RuntimeError("no creds")

    rc = main(["run", "--sources", "cms"], client_factory=failing_client_factory)

    assert rc == 2
    content = summary_file.read_text(encoding="utf-8")
    assert "setup: RuntimeError: no creds" in content
