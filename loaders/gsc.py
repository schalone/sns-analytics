"""Search Console Search Analytics API, both properties, per-day queries, 25k-row paging.
Key = sha1(property|dims|values); updated_at = the load day so restated days supersede older loads."""
from __future__ import annotations

import datetime as dt
import hashlib

from loaders.common.bq import RawRow, RawWriter
from loaders.common.config import RAW_GSC, Settings
from loaders.common.state import LoadState, StepResult, run_step

DIMENSION_SETS = {"page_query": ["date", "page", "query"], "page_device_country": ["date", "page", "device", "country"]}
BACKFILL_DAYS = 480
OVERLAP_DAYS = 3
FINAL_LAG_DAYS = 2
ROW_LIMIT = 25000
SOURCE = "gsc"


def row_key(prop: str, dims: list[str], values: list[str]) -> str:
    return hashlib.sha1("|".join([prop, ",".join(dims), *values]).encode()).hexdigest()


def _service():
    import google.auth
    from googleapiclient.discovery import build
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/webmasters.readonly"])
    return build("searchconsole", "v1", credentials=creds, cache_discovery=False)


def load_gsc(settings: Settings, writer: RawWriter, state: LoadState, full: bool = False, service=None, today: dt.date | None = None) -> list[StepResult]:
    today = today or dt.datetime.now(dt.timezone.utc).date()
    end = today - dt.timedelta(days=FINAL_LAG_DAYS)
    results: list[StepResult] = []
    for prop in settings.gsc_properties:
        for name, dims in DIMENSION_SETS.items():
            entity = name
            step_name = f"{SOURCE}.{name}.{'www' if '//www.' in prop else 'apex'}"
            def step(prop=prop, dims=dims, entity=entity, step_name=step_name) -> int:
                svc = service or _service()
                wm = None if full else state.get(SOURCE, step_name)
                start = (wm.updated_at.date() - dt.timedelta(days=OVERLAP_DAYS)) if wm else (today - dt.timedelta(days=BACKFILL_DAYS))
                loaded_at = dt.datetime.combine(today, dt.time(), tzinfo=dt.timezone.utc)   # load day; same-day reruns tie-break on _loaded_at
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
                    day += dt.timedelta(days=1)
                state.set(SOURCE, step_name, dt.datetime.combine(end, dt.time(), tzinfo=dt.timezone.utc))
                return total
            results.append(run_step(state, settings.run_id, step_name, step))
    return results
