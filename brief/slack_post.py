"""Slack delivery for the morning brief. With SLACK_BOT_TOKEN: Block Kit parent message, full detail as a thread
reply, PNG charts uploaded into the thread. Without it: falls back to the incoming webhook (text only, no thread)."""
import json, os, urllib.request

CHANNEL = os.environ.get("SLACK_CHANNEL_ID", "C0C459A46ET")   # #analytics


def _api(method, token, payload=None, data=None, headers=None):
    h = {"Authorization": f"Bearer {token}"}; h.update(headers or {})
    if payload is not None:
        data = json.dumps(payload).encode(); h["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(f"https://slack.com/api/{method}", data=data, headers=h)
    with urllib.request.urlopen(req, timeout=60) as r: out = json.load(r)
    if not out.get("ok"): raise RuntimeError(f"slack {method}: {out.get('error')}")
    return out


def _upload(token, name, png, thread_ts, title):
    up = _api("files.getUploadURLExternal", token, data=f"filename={name}&length={len(png)}".encode(),
              headers={"Content-Type": "application/x-www-form-urlencoded"})
    req = urllib.request.Request(up["upload_url"], data=png, headers={"Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(req, timeout=120) as r: r.read()
    _api("files.completeUploadExternal", token, payload={"files": [{"id": up["file_id"], "title": title}],
                                                          "channel_id": CHANNEL, "thread_ts": thread_ts})


def post_brief(blocks, fallback_text, thread_text=None, images=()):
    """images: [(filename, png_bytes, title)]. Returns 'bot' or 'webhook'."""
    token = os.environ.get("SLACK_BOT_TOKEN")
    if token:
        parent = _api("chat.postMessage", token, payload={"channel": CHANNEL, "blocks": blocks, "text": fallback_text, "unfurl_links": False})
        ts = parent["ts"]
        if thread_text:
            for chunk in _chunks(thread_text, 3800):
                _api("chat.postMessage", token, payload={"channel": CHANNEL, "thread_ts": ts, "text": chunk})
        for name, png, title in images: _upload(token, name, png, ts, title)
        return "bot"
    url = os.environ.get("SLACK_WEBHOOK_URL")
    if not url: print("(no SLACK_BOT_TOKEN / SLACK_WEBHOOK_URL; not posted)"); return "none"
    req = urllib.request.Request(url, data=json.dumps({"text": fallback_text}).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r: r.read()
    return "webhook"


def _chunks(text, n):
    out, cur = [], ""
    for line in text.split("\n"):
        if len(cur) + len(line) + 1 > n and cur: out.append(cur); cur = ""
        cur += line + "\n"
    if cur: out.append(cur)
    return out


# ------------------------------------------------------------ Block Kit ---
def brief_blocks(date_label, story, ga_headline_fields, ads_headline, flags, movers):
    """ga_headline_fields: [(label, value)] shown as a 2-col grid; movers: [str] short lines."""
    blocks = [{"type": "header", "text": {"type": "plain_text", "text": f"Morning brief — {date_label}"}}]
    if story: blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": story}})
    blocks.append({"type": "divider"})
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "*Website (GA4, yesterday vs same weekday last week)*"},
                   "fields": [{"type": "mrkdwn", "text": f"*{l}*\n{v}"} for l, v in ga_headline_fields[:10]]})
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "*Google Ads (yesterday)*\n" + ads_headline}})
    if movers: blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": "*Biggest movers / flagged*\n" + "\n".join("• " + m for m in movers)}})
    if flags: blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": " · ".join(flags)}]})
    blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": "Full campaign table, channels, landing pages and charts are in the thread ↓"}]})
    return blocks
