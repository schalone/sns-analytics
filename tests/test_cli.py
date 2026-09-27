from loaders.__main__ import parse_args, summarise
from loaders.common.slack import post_status
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
