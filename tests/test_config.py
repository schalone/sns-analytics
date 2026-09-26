from loaders.common.config import Settings, RAW_CMS, OPS


def test_from_env_defaults_and_overrides():
    s = Settings.from_env({"CMS_BASE_URL": "https://www.sipandscript.com", "CMS_EXPORT_TOKEN": "t", "CLOUD_RUN_EXECUTION": "sns-analytics-abc12"})
    assert s.project == "sipandscript" and s.location == "US" and s.region == "us-east1"
    assert s.cms_base_url == "https://www.sipandscript.com"
    assert s.cms_token == "t"
    assert s.run_id == "sns-analytics-abc12"
    assert RAW_CMS == "raw_cms" and OPS == "ops"


def test_run_id_falls_back_to_local_timestamp():
    s = Settings.from_env({"CMS_BASE_URL": "x"})
    assert s.run_id.startswith("local-") and len(s.run_id) > 10


def test_cms_base_url_required():
    import pytest
    with pytest.raises(ValueError, match="CMS_BASE_URL"):
        Settings.from_env({})
