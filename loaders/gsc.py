"""Search Console Search Analytics API, both properties, per-day queries, 25k-row paging.
Key = sha1(property|dims|values); updated_at = the load day so restated days supersede older loads.

Dimension sets (final-review I18). The API drops anonymised / low-volume rows whenever `page` is combined
with another dimension, and whenever `query` is requested at all (measured for 2026-09-10, www: [date] 150
clicks, [date, page] 153, [date, device, country] 150, but [date, page, query] 61). So:

* `totals`         [date]                   complete property totals -- use for every click/impression total
* `page`           [date, page]             complete page totals
* `device_country` [date, device, country]  complete device / country split
* `page_query`     [date, page, query]      PARTIAL: only non-anonymised queries; search-term analysis only,
                                            never summed to a total

The watermark is written after every successfully loaded day (days ascend), so an interrupted backfill resumes
from the last complete day (minus the overlap) instead of starting again."""
from __future__ import annotations

import datetime as dt
import hashlib
from typing import Iterable

from loaders.common.bq import RawRow, RawWriter
from loaders.common.config import RAW_GSC, Settings
from loaders.common.state import LoadState, StepResult, run_step

DIMENSION_SETS = {
    "totals": ["date"],
    "page": ["date", "page"],
    "device_country": ["date", "device", "country"],
    "page_query": ["date", "page", "query"],
}
BACKFILL_DAYS = 480
OVERLAP_DAYS = 3
FINAL_LAG_DAYS = 2
ROW_LIMIT = 25000
SOURCE = "gsc"


def row_key(prop: str, dims: list[str], values: list[str]) -> str:
    return hashlib.sha1("|".join([prop, ",".join(dims), *values]).encode()).hexdigest()


def step_name_for(set_name: str, prop: str) -> str:
    return f"{SOURCE}.{set_name}.{'www' if '//www.' in prop else 'apex'}"


def _service():
    import google.auth
    from googleapiclient.discovery import build
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/webmasters.readonly"])
    return build("searchconsole", "v1", credentials=creds, cache_discovery=False)


def _midnight(day: dt.date) -> dt.datetime:
    return dt.datetime.combine(day, dt.time(), tzinfo=dt.timezone.utc)


def load_gsc(settings: Settings, writer: RawWriter, state: LoadState, full: bool = False, service=None,
             today: dt.date | None = None, sets: Iterable[str] | None = None) -> list[StepResult]:
    """Load every dimension set (or only `sets`, by name) for both properties. `full` ignores the watermark and
    starts BACKFILL_DAYS back; otherwise a step starts OVERLAP_DAYS before its watermark (the last day it loaded
    completely), or BACKFILL_DAYS back when it has none."""
    today = today or dt.datetime.now(dt.timezone.utc).date()
    end = today - dt.timedelta(days=FINAL_LAG_DAYS)
    names = list(sets) if sets is not None else list(DIMENSION_SETS)
    unknown = [n for n in names if n not in DIMENSION_SETS]
    if unknown:
        raise ValueError(f"unknown Search Console dimension sets: {unknown}")
    results: list[StepResult] = []
    for prop in settings.gsc_properties:
        for name in names:
            dims = DIMENSION_SETS[name]
            step_name = step_name_for(name, prop)
            def step(prop=prop, dims=dims, entity=name, step_name=step_name) -> int:
                svc = service or _service()
                wm = None if full else state.get(SOURCE, step_name)
                start = (wm.updated_at.date() - dt.timedelta(days=OVERLAP_DAYS)) if wm else (today - dt.timedelta(days=BACKFILL_DAYS))
                loaded_at = _midnight(today)   # load day; same-day reruns tie-break on _loaded_at
                total = 0
                day = start
                while day <= end:
                    d = day.isoformat(); start_row = 0
                    while True:
                        body = {"startDate": d, "endDate": d, "dimensions": dims, "rowLimit": ROW_LIMIT, "startRow": start_row, "dataState": "final"}
                        rows = svc.searchanalytics().query(siteUrl=prop, body=body).execute().get("rows", [])
                        if not rows:
                            break
                        total += writer.append(RAW_GSC, entity, [
                            RawRow(row_key(prop, dims, r["keys"]), loaded_at, {"property": prop, **dict(zip(dims, r["keys"])),
                                   "clicks": r.get("clicks", 0), "impressions": r.get("impressions", 0), "ctr": r.get("ctr", 0), "position": r.get("position", 0)})
                            for r in rows])
                        if len(rows) < ROW_LIMIT:
                            break
                        start_row += ROW_LIMIT
                    # I15: this day is complete -> advance the watermark now, so an interruption resumes here.
                    state.set(SOURCE, step_name, _midnight(day))
                    day += dt.timedelta(days=1)
                return total
            results.append(run_step(state, settings.run_id, step_name, step))
    return results
