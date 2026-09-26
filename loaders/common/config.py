"""Runtime settings. Everything comes from env vars so the same code runs locally (ADC) and in Cloud Run."""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from typing import Mapping

RAW_CMS, RAW_STRIPE, RAW_GSC, RAW_SPEND, OPS = "raw_cms", "raw_stripe", "raw_gsc", "raw_spend", "ops"


@dataclass(frozen=True)
class Settings:
    cms_base_url: str
    run_id: str
    project: str = "sipandscript"
    location: str = "US"
    region: str = "us-east1"
    cms_token: str | None = None
    stripe_key: str | None = None
    slack_bot_token: str | None = None
    slack_channel: str = "C0C459A46ET"
    spend_bucket: str = "sns-analytics-drop"
    gsc_properties: tuple[str, ...] = ("https://sipandscript.com/", "https://www.sipandscript.com/")
    ga4_dataset: str = "analytics_313669961"

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "Settings":
        base = env.get("CMS_BASE_URL", "").rstrip("/")
        if not base:
            raise ValueError("CMS_BASE_URL is required")
        run_id = env.get("CLOUD_RUN_EXECUTION") or f"local-{dt.datetime.now(dt.timezone.utc):%Y%m%dT%H%M%SZ}"
        return cls(
            cms_base_url=base,
            run_id=run_id,
            project=env.get("GCP_PROJECT", "sipandscript"),
            cms_token=env.get("CMS_EXPORT_TOKEN") or None,
            stripe_key=env.get("STRIPE_RESTRICTED_KEY") or None,
            slack_bot_token=env.get("SLACK_BOT_TOKEN") or None,
            slack_channel=env.get("SLACK_CHANNEL", "C0C459A46ET"),
            spend_bucket=env.get("SPEND_BUCKET", "sns-analytics-drop"),
        )
