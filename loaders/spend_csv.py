"""Meta / Pinterest Ads Manager CSV drops in gs://<bucket>/spend/<platform>/*.csv. Stopgap until the Ads APIs (phase two)."""
from __future__ import annotations

import csv
import datetime as dt
import hashlib
import io
import re

from loaders.common.bq import RawRow, RawWriter
from loaders.common.config import RAW_SPEND, Settings
from loaders.common.state import LoadState, StepResult, run_step

PLATFORMS = ("meta", "pinterest")
REQUIRED = {"date", "campaign_name", "spend", "impressions", "clicks"}
HEADER_MAP = {
    "day": "date", "date": "date", "reporting starts": "date",
    "campaign name": "campaign_name", "campaign": "campaign_name",
    "amount spent (usd)": "spend", "amount spent": "spend", "spend": "spend", "spend (usd)": "spend",
    "impressions": "impressions",
    "link clicks": "clicks", "clicks (all)": "clicks", "pin clicks": "clicks", "clicks": "clicks",
}
SOURCE = "spend"
BOM = "﻿"


def normalise_header(h: str) -> str:
    h = h.replace(BOM, "").strip().lower()
    return HEADER_MAP.get(h, h.replace(" ", "_"))


def _num(s: str) -> float:
    """Tolerant numeric parse: strip everything but digits, '.' and a leading '-' (currency
    symbols, thousands separators, stray text); empty result parses as 0.0."""
    cleaned = re.sub(r"[^0-9.\-]", "", s or "")
    if cleaned in ("", "-", ".", "-."):
        return 0.0
    return float(cleaned)


def parse_csv(platform: str, object_name: str, text: str, generation: int) -> list[RawRow]:
    text = text.replace(BOM, "")   # Excel/Ads-Manager exports are often UTF-8-with-BOM
    reader = csv.DictReader(io.StringIO(text))
    headers = [normalise_header(h) for h in reader.fieldnames or []]
    missing = REQUIRED - set(headers)
    if missing:
        raise ValueError(f"{object_name}: missing columns {sorted(missing)}")
    updated_at = dt.datetime.fromtimestamp(0, tz=dt.timezone.utc) + dt.timedelta(microseconds=generation)  # monotonic per generation
    rows = []
    for raw in reader:
        rec = {normalise_header(k): (v or "").strip() for k, v in raw.items() if k is not None}
        if not rec.get("date"):
            continue
        rows.append(RawRow(
            hashlib.sha1(f"{platform}|{rec['date']}|{rec['campaign_name']}".encode()).hexdigest(), updated_at,
            {"platform": platform, "file": object_name, "date": rec["date"], "campaign_name": rec["campaign_name"],
             "spend": _num(rec["spend"]), "impressions": int(_num(rec["impressions"])),
             "clicks": int(_num(rec["clicks"]))}))
    return rows


def load_spend_csv(settings: Settings, writer: RawWriter, state: LoadState, storage=None) -> list[StepResult]:
    if storage is None:
        from google.cloud import storage as gcs
        storage = gcs.Client(project=settings.project)
    results: list[StepResult] = []
    for platform in PLATFORMS:
        for blob in storage.list_blobs(settings.spend_bucket, prefix=f"spend/{platform}/"):
            if not blob.name.lower().endswith(".csv"):
                continue
            def step(blob=blob, platform=platform) -> int:
                prior = state.get(SOURCE, blob.name)
                if prior and prior.cursor == str(blob.generation):
                    return 0
                rows = parse_csv(platform, blob.name, blob.download_as_text(), int(blob.generation))
                n = writer.append(RAW_SPEND, platform, rows)
                state.set(SOURCE, blob.name, dt.datetime.now(dt.timezone.utc), cursor=str(blob.generation))
                return n
            results.append(run_step(state, settings.run_id, f"{SOURCE}.{blob.name}", step))
    return results
