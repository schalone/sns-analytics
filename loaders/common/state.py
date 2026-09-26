"""ops.load_state (one row per source+entity) and ops.run_log (one row per step per run)."""
from __future__ import annotations

import datetime as dt
import traceback
from dataclasses import dataclass
from typing import Callable

from google.cloud import bigquery


@dataclass(frozen=True)
class Watermark:
    updated_at: dt.datetime
    cursor: str | None = None


@dataclass(frozen=True)
class StepResult:
    step: str
    status: str   # ok | error
    rows: int
    message: str = ""


class LoadState:
    def __init__(self, client: bigquery.Client, project: str):
        self.client, self.project = client, project

    def ensure(self) -> None:
        self._q(f"""
            CREATE TABLE IF NOT EXISTS `{self.project}.ops.load_state`
              (source STRING NOT NULL, entity STRING NOT NULL, watermark TIMESTAMP NOT NULL, cursor STRING, updated_at TIMESTAMP NOT NULL)""")
        self._q(f"""
            CREATE TABLE IF NOT EXISTS `{self.project}.ops.run_log`
              (run_id STRING NOT NULL, logged_at TIMESTAMP NOT NULL, step STRING NOT NULL, status STRING NOT NULL, rows INT64, message STRING)
            PARTITION BY DATE(logged_at)""")

    def get(self, source: str, entity: str) -> Watermark | None:
        rows = list(self._q(
            f"SELECT watermark, cursor FROM `{self.project}.ops.load_state` WHERE source = @source AND entity = @entity",
            source=source, entity=entity))
        if not rows:
            return None
        r = rows[0]
        return Watermark(r["watermark"], r["cursor"])

    def set(self, source: str, entity: str, updated_at: dt.datetime, cursor: str | None = None) -> None:
        self._q(f"""
            MERGE `{self.project}.ops.load_state` t
            USING (SELECT @source AS source, @entity AS entity, @watermark AS watermark, @cursor AS cursor) s
            ON t.source = s.source AND t.entity = s.entity
            WHEN MATCHED THEN UPDATE SET watermark = s.watermark, cursor = s.cursor, updated_at = CURRENT_TIMESTAMP()
            WHEN NOT MATCHED THEN INSERT (source, entity, watermark, cursor, updated_at) VALUES (s.source, s.entity, s.watermark, s.cursor, CURRENT_TIMESTAMP())""",
            source=source, entity=entity, watermark=updated_at, cursor=cursor)

    def log(self, run_id: str, step: str, status: str, rows: int, message: str = "") -> None:
        self._q(f"INSERT `{self.project}.ops.run_log` (run_id, logged_at, step, status, rows, message) VALUES (@run_id, CURRENT_TIMESTAMP(), @step, @status, @rows, @message)",
                run_id=run_id, step=step, status=status, rows=rows, message=message[:2000])

    def _q(self, sql: str, **params):
        cfg = bigquery.QueryJobConfig(query_parameters=[_param(k, v) for k, v in params.items()])
        return self.client.query(sql, job_config=cfg).result()


def _param(name, value):
    if isinstance(value, dt.datetime):
        return bigquery.ScalarQueryParameter(name, "TIMESTAMP", value)
    if isinstance(value, int):
        return bigquery.ScalarQueryParameter(name, "INT64", value)
    return bigquery.ScalarQueryParameter(name, "STRING", value)


def run_step(state: LoadState, run_id: str, step: str, fn: Callable[[], int]) -> StepResult:
    try:
        rows = int(fn() or 0)
        result = StepResult(step, "ok", rows)
    except Exception as e:  # noqa: BLE001 - a loader failure must never stop the run
        result = StepResult(step, "error", 0, f"{type(e).__name__}: {e}\n{traceback.format_exc()[-1500:]}")
    try:
        state.log(run_id, step, result.status, result.rows, result.message)
    except Exception:  # noqa: BLE001
        pass
    return result
