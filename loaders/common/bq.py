"""Append-only raw tables with the fixed contract from the spec (§4)."""
from __future__ import annotations

import datetime as dt
import json
from dataclasses import dataclass
from typing import Any, Sequence

from google.api_core import exceptions
from google.cloud import bigquery

RAW_SCHEMA = [
    bigquery.SchemaField("key", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("updated_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("payload", "JSON"),
    bigquery.SchemaField("_loaded_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("_run_id", "STRING", mode="REQUIRED"),
]


@dataclass(frozen=True)
class RawRow:
    key: str
    updated_at: dt.datetime
    payload: dict[str, Any]


class RawWriter:
    def __init__(self, client: bigquery.Client, project: str, run_id: str, location: str = "US"):
        self.client, self.project, self.run_id, self.location = client, project, run_id, location

    def ensure_dataset(self, dataset: str) -> None:
        ref = bigquery.Dataset(f"{self.project}.{dataset}"); ref.location = self.location
        try:
            self.client.get_dataset(ref)
        except exceptions.NotFound:
            self.client.create_dataset(ref, exists_ok=True)

    def ensure_table(self, dataset: str, entity: str) -> None:
        table_id = f"{self.project}.{dataset}.{entity}"
        try:
            self.client.get_table(table_id)
            return
        except exceptions.NotFound:
            pass
        table = bigquery.Table(table_id, schema=RAW_SCHEMA)
        table.time_partitioning = bigquery.TimePartitioning(type_=bigquery.TimePartitioningType.DAY, field="_loaded_at")
        table.clustering_fields = ["key"]
        self.client.create_table(table, exists_ok=True)

    def append(self, dataset: str, entity: str, rows: Sequence[RawRow]) -> int:
        if not rows:
            return 0
        self.ensure_table(dataset, entity)
        loaded_at = dt.datetime.now(dt.timezone.utc).isoformat()
        payload = [
            {"key": r.key, "updated_at": _iso(r.updated_at), "payload": json.dumps(r.payload, default=str),
             "_loaded_at": loaded_at, "_run_id": self.run_id}
            for r in rows
        ]
        cfg = bigquery.LoadJobConfig(schema=RAW_SCHEMA, source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
                                     write_disposition=bigquery.WriteDisposition.WRITE_APPEND)
        self.client.load_table_from_json(payload, f"{self.project}.{dataset}.{entity}", job_config=cfg).result()
        return len(payload)


def _iso(t: dt.datetime) -> str:
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return t.isoformat()
