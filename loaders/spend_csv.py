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


_US_NUMBER = re.compile(r"-?(?:\d{1,3}(?:,\d{3})+|\d*)(?:\.\d+)?")
_DATE_FORMATS = (
    (re.compile(r"\d{4}-\d{1,2}-\d{1,2}"), "%Y-%m-%d"),
    (re.compile(r"\d{1,2}/\d{1,2}/\d{4}"), "%m/%d/%Y"),     # M/D/YYYY and MM/DD/YYYY (US exports)
    (re.compile(r"\d{4}/\d{1,2}/\d{1,2}"), "%Y/%m/%d"),
)


def _num(s: str) -> float:
    """Numeric parse tolerant of currency symbols/codes, whitespace and US thousands separators
    ("$1,234.56", "12,000", "USD 5"); empty parses as 0.0. Raises ValueError for anything whose meaning is
    ambiguous rather than guess: a decimal comma ("12,5", "1.234,56") or an accounting negative ("(12.00)")."""
    raw = s or ""
    if "(" in raw or ")" in raw:
        raise ValueError(f"accounting-style negative {raw!r} is not accepted; export plain numbers")
    cleaned = re.sub(r"[^0-9.,\-]", "", raw)
    if cleaned in ("", "-", ".", "-."):
        return 0.0
    if not _US_NUMBER.fullmatch(cleaned) or not re.search(r"\d", cleaned):
        raise ValueError(f"number {raw!r} is not in US format (decimal comma or misplaced separator)")
    return float(cleaned.replace(",", ""))


def normalise_date(value: str) -> str:
    """ISO YYYY-MM-DD from YYYY-MM-DD, M/D/YYYY, MM/DD/YYYY or YYYY/MM/DD; ValueError otherwise."""
    v = (value or "").strip()
    for pattern, fmt in _DATE_FORMATS:
        if pattern.fullmatch(v):
            try:
                return dt.datetime.strptime(v, fmt).date().isoformat()
            except ValueError:
                break
    raise ValueError(f"unrecognised date {value!r}")


def parse_csv_counted(platform: str, object_name: str, text: str, generation: int) -> tuple[list[RawRow], int]:
    """(rows, skipped): rows with an empty campaign name (Ads Manager summary/total rows) are skipped and
    counted. Any row whose date or number cannot be parsed rejects the WHOLE file with a ValueError naming
    the file, the CSV line number and the value -- a partly loaded file would silently undercount spend."""
    text = text.replace(BOM, "")   # Excel/Ads-Manager exports are often UTF-8-with-BOM
    reader = csv.DictReader(io.StringIO(text))
    headers = [normalise_header(h) for h in reader.fieldnames or []]
    missing = REQUIRED - set(headers)
    if missing:
        raise ValueError(f"{object_name}: missing columns {sorted(missing)}")
    updated_at = dt.datetime.fromtimestamp(0, tz=dt.timezone.utc) + dt.timedelta(microseconds=generation)  # monotonic per generation
    rows, skipped = [], 0
    for raw in reader:
        rec = {normalise_header(k): (v or "").strip() for k, v in raw.items() if k is not None}
        if not rec.get("campaign_name"):
            skipped += 1
            continue
        line = reader.line_num
        try:
            date = normalise_date(rec.get("date", ""))
            spend, impressions, clicks = _num(rec["spend"]), int(_num(rec["impressions"])), int(_num(rec["clicks"]))
        except ValueError as e:
            raise ValueError(f"{object_name}: row {line}: {e}") from None
        rows.append(RawRow(
            hashlib.sha1(f"{platform}|{date}|{rec['campaign_name']}".encode()).hexdigest(), updated_at,
            {"platform": platform, "file": object_name, "date": date, "campaign_name": rec["campaign_name"],
             "spend": spend, "impressions": impressions, "clicks": clicks}))
    return rows, skipped


def parse_csv(platform: str, object_name: str, text: str, generation: int) -> list[RawRow]:
    return parse_csv_counted(platform, object_name, text, generation)[0]


def load_spend_csv(settings: Settings, writer: RawWriter, state: LoadState, storage=None) -> list[StepResult]:
    """One `spend.list.<platform>` step per platform (client creation + bucket listing, so a missing bucket or a
    denied permission is a step error, never an exception into main()), then one step per CSV object."""
    client: list = [storage]
    results: list[StepResult] = []
    for platform in PLATFORMS:
        blobs: list = []
        def list_step(platform=platform, blobs=blobs) -> int:
            if client[0] is None:
                from google.cloud import storage as gcs
                client[0] = gcs.Client(project=settings.project)
            blobs.extend(b for b in client[0].list_blobs(settings.spend_bucket, prefix=f"spend/{platform}/")
                         if b.name.lower().endswith(".csv"))
            return len(blobs)
        listed = run_step(state, settings.run_id, f"{SOURCE}.list.{platform}", list_step)
        results.append(listed)
        for blob in blobs:
            def step(blob=blob, platform=platform):
                prior = state.get(SOURCE, blob.name)
                if prior and prior.cursor == str(blob.generation):
                    return 0
                rows, skipped = parse_csv_counted(platform, blob.name, blob.download_as_text(), int(blob.generation))
                n = writer.append(RAW_SPEND, platform, rows)
                state.set(SOURCE, blob.name, dt.datetime.now(dt.timezone.utc), cursor=str(blob.generation))
                return (n, f"skipped {skipped} row(s) with an empty campaign name") if skipped else n
            results.append(run_step(state, settings.run_id, f"{SOURCE}.{blob.name}", step))
    return results
