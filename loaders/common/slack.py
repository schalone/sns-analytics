from __future__ import annotations

import requests

from loaders.common.config import Settings


def post_status(settings: Settings, text: str) -> None:
    if not settings.slack_bot_token:
        print(text); return
    r = requests.post("https://slack.com/api/chat.postMessage", headers={"Authorization": f"Bearer {settings.slack_bot_token}"},
                      json={"channel": settings.slack_channel, "text": text}, timeout=20)
    if not r.ok or not r.json().get("ok"):
        print(f"slack post failed: {r.text[:200]}")
