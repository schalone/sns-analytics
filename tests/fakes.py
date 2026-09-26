"""In-memory stand-ins for the Google clients. Loaders only use the surface reproduced here."""
from __future__ import annotations

import collections


class _Job:
    def __init__(self, rows): self.rows = rows
    def result(self): return self.rows


class FakeBqClient:
    def __init__(self, project="sipandscript"):
        self.project = project
        self.created_datasets, self.created_tables = [], []
        self.loads: list[tuple[str, list[dict]]] = []
        self.queries: list[tuple[str, dict]] = []
        self.query_results = collections.deque()

    # datasets / tables
    def get_dataset(self, ref): raise _NotFound(ref)
    def create_dataset(self, ds, exists_ok=False): self.created_datasets.append((ds.dataset_id, ds.location)); return ds
    def get_table(self, ref): raise _NotFound(ref)
    def create_table(self, table, exists_ok=False): self.created_tables.append(table); return table

    # loads
    def load_table_from_json(self, rows, destination, job_config=None):
        rows = list(rows); self.loads.append((destination, rows)); return _Job(rows)

    # queries
    def query(self, sql, job_config=None):
        params = {p.name: p.value for p in (job_config.query_parameters if job_config else [])}
        self.queries.append((sql, params))
        return _Job(self.query_results.popleft() if self.query_results else [])


class _NotFound(Exception):
    pass


class FakeBucketBlob:
    def __init__(self, name, generation, text): self.name, self.generation, self._text = name, generation, text
    def download_as_text(self): return self._text


class FakeStorageClient:
    def __init__(self, blobs): self._blobs = blobs
    def list_blobs(self, bucket, prefix=""): return [b for b in self._blobs if b.name.startswith(prefix)]
