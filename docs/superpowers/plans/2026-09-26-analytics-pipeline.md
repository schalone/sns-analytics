# Analytics Pipeline (sns-analytics) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Stripe, the CMS export, Search Console and ad-spend CSVs in BigQuery on a schedule, model them with dbt alongside the existing GA4 export and WooCommerce archive, and publish three phase-one marts (`daily_kpis`, `paid_performance`, `orders_reconciliation`) that the Slack brief, Looker Studio and Claude read.

**Architecture:** One Python package `loaders` (a module per source, a shared BigQuery raw writer and watermark state) and one dbt-core project `dbt/` (staging views → core tables → marts), run sequentially by a single Cloud Run job in us-east1 on two Cloud Scheduler triggers. Raw tables are append-only with a fixed shape; staging picks the latest row per key; every known data correction lives in exactly one dbt model with a test.

**Tech Stack:** Python 3.12, `google-cloud-bigquery` 3.45, `google-cloud-storage`, `google-cloud-secret-manager`, `stripe` 15.x, `google-api-python-client` 2.x, `requests`, pytest, ruff; dbt-core 1.12 + dbt-bigquery 1.12, `dbt_utils`; Cloud Run jobs, Cloud Scheduler, Secret Manager, BigQuery Data Transfer (Google Ads).

**Spec:** `docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md`. The CMS side is a separate plan: `docs/superpowers/plans/2026-09-26-cms-analytics-export-api.md`; Task 4 here builds against that contract with recorded fixtures and does not need the CMS change deployed.

## Global Constraints

- GCP project `sipandscript`; every new dataset in the **US multi-region**; Cloud Run and Scheduler in **us-east1**.
- Raw table contract (spec §4): columns `key STRING, updated_at TIMESTAMP, payload JSON, _loaded_at TIMESTAMP, _run_id STRING`; partitioned by `DATE(_loaded_at)`, clustered by `key`; append-only.
- Datasets: `raw_cms`, `raw_stripe`, `raw_gsc`, `raw_spend`, `google_ads`, `ops`, `staging`, `core`, `mart`. Existing `analytics_313669961` and `sipandscript_new_ds` are read-only sources.
- Watermarks advance only after a successful append. Loaders are independent: one failing must not stop the others or `dbt build`.
- No PII in the warehouse. Money in dollars from staging onward (`cents / 100`), cents in raw only.
- Business dates in `America/New_York`; timestamps UTC.
- Local runs use Application Default Credentials. The gcloud CLI on Stephen's laptop is broken (old SDK); `infra/setup.sh` is written for Cloud Shell, and `infra/bq_admin.py` covers dataset creation over REST from the laptop.
- Slack posts go to `#analytics` (channel `C0C459A46ET`) with the existing bot token secret `slack-ads-sync-bot-token`.

## Review Focus

1. **A CMS row updated twice within the 2-hour overlap** (e.g. an order paid then refunded) — the raw table gets two rows with different `updated_at`; staging must keep the later one. Test: Task 10 `assert_latest_raw_picks_newest.sql`.
2. **A loader crash after appending but before the watermark write** — the next run re-appends the same rows; staging dedups by `(key, updated_at)`. Test: Task 3 `test_watermark_not_advanced_on_failure`, Task 10 dedup test.
3. **GA4 `purchase` fired twice with the same `transaction_id` on different days** (late reload) — `core_session_orders` must keep the earliest, and `mart_daily_kpis` must count the order once on the order's business date, not the event date. Test: Task 12 `unique(order_key)` plus singular test `assert_orders_counted_once`.
4. **Search Console restating a day** — the same `(property,date,page,query)` key arrives again with a different click count; the later load must win. Covered by the raw contract with `updated_at = load date`, test in Task 6 `test_gsc_key_and_updated_at`.
5. **Spend CSV uploaded twice, or re-exported with corrected numbers** — same file name, new generation: must reload and supersede; same generation: must skip. Test: Task 7 `test_spend_skip_same_generation_reload_new_generation`.

---

### Task 1: Repository scaffold and settings

**Files:**
- Create: `pyproject.toml`, `.gitignore`, `README.md`, `loaders/__init__.py`, `loaders/common/__init__.py`, `loaders/common/config.py`, `tests/__init__.py`, `tests/test_config.py`

**Interfaces:**
- Produces: `@dataclass(frozen=True) Settings` with fields `project: str = "sipandscript"`, `location: str = "US"`, `region: str = "us-east1"`, `cms_base_url: str`, `cms_token: str | None`, `stripe_key: str | None`, `slack_bot_token: str | None`, `slack_channel: str = "C0C459A46ET"`, `spend_bucket: str = "sns-analytics-drop"`, `gsc_properties: tuple[str, ...] = ("https://sipandscript.com/", "https://www.sipandscript.com/")`, `ga4_dataset: str = "analytics_313669961"`, `run_id: str`; `Settings.from_env(env: Mapping[str,str]) -> Settings`; dataset name constants `RAW_CMS = "raw_cms"`, `RAW_STRIPE`, `RAW_GSC`, `RAW_SPEND`, `OPS = "ops"`.

- [ ] **Step 1: Write the failing test**

`tests/test_config.py`:

```python
from loaders.common.config import Settings, RAW_CMS, OPS


def test_from_env_defaults_and_overrides():
    s = Settings.from_env({"CMS_BASE_URL": "https://www.sipandscript.com", "CMS_EXPORT_TOKEN": "t", "CLOUD_RUN_EXECUTION": "sns-analytics-abc12"})
    assert s.project == "sipandscript" and s.location == "US" and s.region == "us-east1"
    assert s.cms_base_url == "https://www.sipandscript.com"
    assert s.cms_token == "t"
    assert s.run_id == "sns-analytics-abc12"
    assert RAW_CMS == "raw_cms" and OPS == "ops"


def test_run_id_falls_back_to_local_timestamp():
    s = Settings.from_env({"CMS_BASE_URL": "x"})
    assert s.run_id.startswith("local-") and len(s.run_id) > 10


def test_cms_base_url_required():
    import pytest
    with pytest.raises(ValueError, match="CMS_BASE_URL"):
        Settings.from_env({})
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/stephenchaloner/sns-analytics && python3.11 -m venv .venv && . .venv/bin/activate && pip install -q -e ".[dev]" 2>/dev/null; pytest -q tests/test_config.py
```
Expected: `ModuleNotFoundError: No module named 'loaders'` (or pip fails because pyproject is missing — create it in Step 3 and rerun).

- [ ] **Step 3: Create the scaffold**

`pyproject.toml`:

```toml
[project]
name = "sns-analytics"
version = "0.1.0"
description = "Sip & Script analytics pipeline: loaders + dbt on BigQuery"
requires-python = ">=3.12"
dependencies = [
  "google-cloud-bigquery>=3.45,<4",
  "google-cloud-storage>=2.18,<3",
  "google-cloud-secret-manager>=2.20,<3",
  "google-api-python-client>=2.150,<3",
  "google-auth>=2.35,<3",
  "stripe>=15,<16",
  "requests>=2.32,<3",
]

[project.optional-dependencies]
dev = ["pytest>=8", "ruff>=0.6", "dbt-bigquery>=1.12,<2"]

[tool.setuptools.packages.find]
include = ["loaders*"]

[tool.ruff]
line-length = 120

[tool.pytest.ini_options]
testpaths = ["tests"]
```

`.gitignore`:

```
.venv/
__pycache__/
*.pyc
dbt/target/
dbt/dbt_packages/
dbt/logs/
.pytest_cache/
.ruff_cache/
*.egg-info/
```

`loaders/common/config.py`:

```python
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
```

`loaders/__init__.py` and `loaders/common/__init__.py` and `tests/__init__.py`: empty files.

`README.md`:

```markdown
# sns-analytics

BigQuery analytics pipeline for Sip & Script. Design: `docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md`.

    python3.12 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]"
    pytest
    CMS_BASE_URL=https://www.sipandscript.com CMS_EXPORT_TOKEN=... python -m loaders run --sources cms
    cd dbt && dbt build

Cloud Run job `sns-analytics` (us-east1) runs `jobs/entrypoint.sh` on the schedules in `infra/setup.sh`.
```

- [ ] **Step 4: Run to verify pass**

```bash
pip install -q -e ".[dev]" && pytest -q tests/test_config.py
```
Expected: `3 passed`.

- [ ] **Step 5: Commit**

```bash
git add pyproject.toml .gitignore README.md loaders tests && git commit -m "chore: scaffold loaders package and settings"
```

---

### Task 2: Raw table writer

**Files:**
- Create: `loaders/common/bq.py`, `tests/test_bq.py`, `tests/fakes.py`

**Interfaces:**
- Produces: `@dataclass RawRow(key: str, updated_at: dt.datetime, payload: dict)`; `class RawWriter(client, project, run_id)` with `ensure_dataset(dataset)`, `ensure_table(dataset, entity)`, `append(dataset, entity, rows: Sequence[RawRow]) -> int` (batch load via `load_table_from_json`, JSON payload serialised as a string), and `RAW_SCHEMA` (list of `bigquery.SchemaField`). `tests/fakes.py` provides `FakeBqClient` recording `created_datasets`, `created_tables`, `loads: list[(table_id, rows)]`, and `queries: list[(sql, params)]` with a `query_results` queue, used by every loader test.

- [ ] **Step 1: Write the fake and the failing tests**

`tests/fakes.py`:

```python
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
```

`tests/test_bq.py`:

```python
import datetime as dt
import json

from loaders.common.bq import RawRow, RawWriter, RAW_SCHEMA
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


def test_schema_matches_contract():
    assert [f.name for f in RAW_SCHEMA] == ["key", "updated_at", "payload", "_loaded_at", "_run_id"]
    assert [f.field_type for f in RAW_SCHEMA] == ["STRING", "TIMESTAMP", "JSON", "TIMESTAMP", "STRING"]


def test_ensure_table_is_partitioned_and_clustered():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    w.ensure_table("raw_cms", "orders")
    t = c.created_tables[0]
    assert t.table_id == "orders" and t.time_partitioning.field == "_loaded_at" and t.clustering_fields == ["key"]


def test_append_serialises_rows_and_returns_count():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    n = w.append("raw_cms", "orders", [RawRow("k1", dt.datetime(2026, 9, 26, 1, 2, 3, tzinfo=UTC), {"a": 1})])
    assert n == 1
    dest, rows = c.loads[0]
    assert dest == "sipandscript.raw_cms.orders"
    assert rows[0]["key"] == "k1" and rows[0]["updated_at"] == "2026-09-26T01:02:03+00:00"
    assert json.loads(rows[0]["payload"]) == {"a": 1} and rows[0]["_run_id"] == "run-1"


def test_append_empty_is_noop():
    c = FakeBqClient(); w = RawWriter(c, "sipandscript", "run-1")
    assert w.append("raw_cms", "orders", []) == 0 and c.loads == []
```

- [ ] **Step 2: Run to verify failure** — `pytest -q tests/test_bq.py` → `ModuleNotFoundError: loaders.common.bq`.

- [ ] **Step 3: Implement**

`loaders/common/bq.py`:

```python
"""Append-only raw tables with the fixed contract from the spec (§4)."""
from __future__ import annotations

import datetime as dt
import json
from dataclasses import dataclass
from typing import Any, Sequence

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
        except Exception:
            self.client.create_dataset(ref, exists_ok=True)

    def ensure_table(self, dataset: str, entity: str) -> None:
        table_id = f"{self.project}.{dataset}.{entity}"
        try:
            self.client.get_table(table_id)
            return
        except Exception:
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
```

- [ ] **Step 4: Run to verify pass** — `pytest -q tests/test_bq.py` → `4 passed`.

- [ ] **Step 5: Commit** — `git add loaders/common/bq.py tests/fakes.py tests/test_bq.py && git commit -m "feat: raw table writer with fixed contract"`

---

### Task 3: Watermark state and run log

**Files:**
- Create: `loaders/common/state.py`, `tests/test_state.py`

**Interfaces:**
- Consumes: `FakeBqClient.query` / `query_results`.
- Produces: `class LoadState(client, project)` with `ensure()` (creates `ops.load_state` and `ops.run_log` if missing), `get(source, entity) -> Watermark | None` where `@dataclass Watermark(updated_at: dt.datetime, cursor: str | None)`, `set(source, entity, updated_at, cursor=None)` (MERGE), and `log(run_id, step, status, rows, message="")`. Also `run_step(state, run_id, step, fn) -> StepResult(step, status, rows, message)` which runs `fn()` returning a row count, catches every exception, logs, and never raises.

- [ ] **Step 1: Write the failing tests**

```python
import datetime as dt

from loaders.common.state import LoadState, Watermark, run_step
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


def test_get_returns_none_when_missing():
    c = FakeBqClient(); c.query_results.append([])
    assert LoadState(c, "sipandscript").get("cms", "orders") is None


def test_get_parses_row():
    c = FakeBqClient(); c.query_results.append([{"watermark": dt.datetime(2026, 9, 25, tzinfo=UTC), "cursor": "abc"}])
    assert LoadState(c, "sipandscript").get("cms", "orders") == Watermark(dt.datetime(2026, 9, 25, tzinfo=UTC), "abc")


def test_set_uses_merge_with_params():
    c = FakeBqClient(); LoadState(c, "sipandscript").set("cms", "orders", dt.datetime(2026, 9, 25, tzinfo=UTC), "abc")
    sql, params = c.queries[-1]
    assert "MERGE `sipandscript.ops.load_state`" in sql and params == {"source": "cms", "entity": "orders", "watermark": dt.datetime(2026, 9, 25, tzinfo=UTC), "cursor": "abc"}


def test_run_step_logs_success_and_failure():
    c = FakeBqClient(); s = LoadState(c, "sipandscript")
    ok = run_step(s, "run-1", "cms.orders", lambda: 12)
    bad = run_step(s, "run-1", "stripe.refunds", lambda: (_ for _ in ()).throw(RuntimeError("boom")))
    assert (ok.status, ok.rows) == ("ok", 12)
    assert (bad.status, bad.rows) == ("error", 0) and "boom" in bad.message
    assert len([q for q in c.queries if "ops.run_log" in q[0]]) == 2


def test_watermark_not_advanced_on_failure():
    c = FakeBqClient(); s = LoadState(c, "sipandscript")
    def failing():
        raise RuntimeError("append failed")
    run_step(s, "run-1", "cms.orders", failing)
    assert not any("load_state" in q[0] for q in c.queries)
```

- [ ] **Step 2: Run to verify failure** — `pytest -q tests/test_state.py` → import error.

- [ ] **Step 3: Implement**

`loaders/common/state.py`:

```python
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
              (run_id STRING NOT NULL, logged_at TIMESTAMP NOT NULL, step STRING NOT NULL, status STRING NOT NULL, row_count INT64, message STRING)
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
        self._q(f"INSERT `{self.project}.ops.run_log` (run_id, logged_at, step, status, row_count, message) VALUES (@run_id, CURRENT_TIMESTAMP(), @step, @status, @rows, @message)",
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
```

- [ ] **Step 4: Run to verify pass** — `5 passed`.

- [ ] **Step 5: Commit** — `git add loaders/common/state.py tests/test_state.py && git commit -m "feat: watermark state and run log"`

---

### Task 4: CMS export loader

**Files:**
- Create: `loaders/cms.py`, `tests/test_cms.py`, `tests/fixtures/cms_orders_page1.json`, `tests/fixtures/cms_orders_page2.json`

**Interfaces:**
- Consumes: `RawWriter.append`, `LoadState.get/set`, `run_step`, `Settings`.
- Produces: `FACT_ENTITIES = ("orders","order_items","tickets","refunds","promo_redemptions","gift_cards","gift_card_transactions","checkout_sessions")`, `DIM_ENTITIES = ("events","venues","metros","instructors")`, `KEY_FIELD: dict[str,str]` (entity → key property, e.g. `"orders": "orderKey"`), `class CmsClient(base_url, token, http=requests.Session())` with `iter_pages(entity, since, full, page_size=1000) -> Iterator[dict]`, and `load_cms(settings, writer, state, entities=None, full=False, mode="daily") -> list[StepResult]` where `mode="daily"` reloads dims in full and `mode="hourly"` loads everything incrementally. Overlap constant `OVERLAP = timedelta(hours=2)`.

- [ ] **Step 1: Write fixtures and failing tests**

`tests/fixtures/cms_orders_page1.json`:

```json
{"entity": "orders", "generatedAt": "2026-09-26T12:00:00Z", "nextCursor": "c2",
 "items": [
  {"orderKey": "11111111-1111-1111-1111-111111111111", "orderNumber": "SNS-26-000001", "status": "Paid", "createdAt": "2026-09-25T10:00:00Z", "paidAt": "2026-09-25T10:01:00Z", "updatedAt": "2026-09-25T10:01:00Z", "currency": "USD", "subtotalCents": 13000, "discountCents": 0, "serviceFeeCents": 600, "giftCardAmountCents": 0, "totalCents": 13600, "promoCode": null, "affiliateKey": null, "memberKey": null, "customerHash": "ab12", "billingCity": "Dallas", "billingState": "TX", "billingZip": "75201", "checkoutSessionKey": "22222222-2222-2222-2222-222222222222", "stripeCheckoutSessionId": "cs_test_1", "source": "webapp", "wordpressOrderId": null},
  {"orderKey": "33333333-3333-3333-3333-333333333333", "orderNumber": "SNS-26-000002", "status": "Refunded", "createdAt": "2026-09-25T11:00:00Z", "paidAt": "2026-09-25T11:01:00Z", "updatedAt": "2026-09-25T12:30:00Z", "currency": "USD", "subtotalCents": 6500, "discountCents": 0, "serviceFeeCents": 300, "giftCardAmountCents": 0, "totalCents": 6800, "promoCode": null, "affiliateKey": null, "memberKey": null, "customerHash": "cd34", "billingCity": "Boston", "billingState": "MA", "billingZip": "02108", "checkoutSessionKey": "44444444-4444-4444-4444-444444444444", "stripeCheckoutSessionId": "cs_test_2", "source": "webapp", "wordpressOrderId": null}
 ]}
```

`tests/fixtures/cms_orders_page2.json`:

```json
{"entity": "orders", "generatedAt": "2026-09-26T12:00:01Z", "nextCursor": null,
 "items": [
  {"orderKey": "55555555-5555-5555-5555-555555555555", "orderNumber": "SNS-26-000003", "status": "Paid", "createdAt": "2026-09-25T13:00:00Z", "paidAt": "2026-09-25T13:01:00Z", "updatedAt": "2026-09-25T13:01:00Z", "currency": "USD", "subtotalCents": 6500, "discountCents": 500, "serviceFeeCents": 300, "giftCardAmountCents": 0, "totalCents": 6300, "promoCode": "FALL5", "affiliateKey": null, "memberKey": null, "customerHash": "ef56", "billingCity": "Austin", "billingState": "TX", "billingZip": "78701", "checkoutSessionKey": "66666666-6666-6666-6666-666666666666", "stripeCheckoutSessionId": "cs_test_3", "source": "webapp", "wordpressOrderId": null}
 ]}
```

`tests/test_cms.py`:

```python
import datetime as dt
import json
import pathlib

from loaders.cms import CmsClient, KEY_FIELD, OVERLAP, load_cms
from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from tests.fakes import FakeBqClient

FIX = pathlib.Path(__file__).parent / "fixtures"
UTC = dt.timezone.utc


class FakeHttp:
    """Maps (path, query) -> response body. Records every request."""
    def __init__(self, responses): self.responses, self.calls = responses, []
    def get(self, url, headers=None, params=None, timeout=None):
        self.calls.append((url, headers, dict(params or {})))
        key = (url.rsplit("/", 1)[-1], (params or {}).get("cursor"))
        body = self.responses[key]
        return _Resp(body)


class _Resp:
    def __init__(self, body): self._body, self.status_code = body, 200
    def raise_for_status(self): pass
    def json(self): return self._body


def _http_for_orders():
    p1 = json.loads((FIX / "cms_orders_page1.json").read_text()); p2 = json.loads((FIX / "cms_orders_page2.json").read_text())
    empty = {"entity": "x", "generatedAt": "2026-09-26T12:00:00Z", "items": [], "nextCursor": None}
    responses = {("orders", None): p1, ("orders", "c2"): p2}
    for e in ["order_items", "tickets", "refunds", "promo_redemptions", "gift_cards", "gift_card_transactions", "checkout_sessions", "events", "venues", "metros", "instructors"]:
        responses[(e, None)] = dict(empty, entity=e)
    return FakeHttp(responses)


def test_iter_pages_follows_cursor_and_sends_bearer():
    http = _http_for_orders(); c = CmsClient("https://cms.test", "tok", http=http)
    pages = list(c.iter_pages("orders", since=None, full=True))
    assert [len(p["items"]) for p in pages] == [2, 1]
    url, headers, params = http.calls[0]
    assert url == "https://cms.test/api/export/orders" and headers["Authorization"] == "Bearer tok"
    assert params == {"pageSize": 1000, "full": 1}
    assert http.calls[1][2]["cursor"] == "c2"


def test_load_cms_appends_rows_and_sets_watermark_with_overlap():
    http = _http_for_orders(); bq = FakeBqClient()
    settings = Settings.from_env({"CMS_BASE_URL": "https://cms.test", "CMS_EXPORT_TOKEN": "tok"})
    state = LoadState(bq, "sipandscript"); bq.query_results.extend([[]] * 12)     # no watermarks yet
    results = load_cms(settings, RawWriter(bq, "sipandscript", "run-1"), state, http=http, full=True)
    orders = [r for r in results if r.step == "cms.orders"][0]
    assert orders.status == "ok" and orders.rows == 3
    dest, rows = [l for l in bq.loads if l[0].endswith(".raw_cms.orders")][0]
    assert rows[0]["key"] == "11111111-1111-1111-1111-111111111111" and rows[1]["updated_at"] == "2026-09-25T12:30:00+00:00"
    merge = [q for q in bq.queries if "load_state" in q[0] and q[1].get("entity") == "orders"][0]
    assert merge[1]["watermark"] == dt.datetime(2026, 9, 25, 13, 1, tzinfo=UTC) - OVERLAP


def test_incremental_uses_since_from_watermark():
    http = _http_for_orders(); bq = FakeBqClient()
    settings = Settings.from_env({"CMS_BASE_URL": "https://cms.test", "CMS_EXPORT_TOKEN": "tok"})
    state = LoadState(bq, "sipandscript")
    wm = dt.datetime(2026, 9, 25, 8, 0, tzinfo=UTC)
    bq.query_results.extend([[{"watermark": wm, "cursor": None}]] + [[]] * 11)
    load_cms(settings, RawWriter(bq, "sipandscript", "run-1"), state, http=http, mode="hourly")
    first_orders_call = [c for c in http.calls if c[0].endswith("/orders")][0]
    assert first_orders_call[2]["since"] == "2026-09-25T08:00:00Z" and "full" not in first_orders_call[2]


def test_key_field_covers_every_entity():
    assert set(KEY_FIELD) == {"orders", "order_items", "tickets", "refunds", "promo_redemptions", "gift_cards", "gift_card_transactions", "checkout_sessions", "events", "venues", "metros", "instructors"}


def test_missing_token_is_a_step_error_not_a_crash():
    bq = FakeBqClient(); settings = Settings.from_env({"CMS_BASE_URL": "https://cms.test"})
    results = load_cms(settings, RawWriter(bq, "sipandscript", "run-1"), LoadState(bq, "sipandscript"), http=FakeHttp({}))
    assert all(r.status == "error" and "CMS_EXPORT_TOKEN" in r.message for r in results)
```

- [ ] **Step 2: Run to verify failure** — `pytest -q tests/test_cms.py` → import error.

- [ ] **Step 3: Implement**

`loaders/cms.py`:

```python
"""CMS export API loader (contract: spec §6). Facts are incremental by updatedAt; dims reload in full daily."""
from __future__ import annotations

import datetime as dt
from typing import Iterator

import requests

from loaders.common.bq import RawRow, RawWriter
from loaders.common.config import RAW_CMS, Settings
from loaders.common.state import LoadState, StepResult, run_step

FACT_ENTITIES = ("orders", "order_items", "tickets", "refunds", "promo_redemptions", "gift_cards", "gift_card_transactions", "checkout_sessions")
DIM_ENTITIES = ("events", "venues", "metros", "instructors")
KEY_FIELD = {
    "orders": "orderKey", "order_items": "orderItemKey", "tickets": "ticketKey", "refunds": "refundKey",
    "promo_redemptions": "redemptionKey", "gift_cards": "giftCardKey", "gift_card_transactions": "transactionKey",
    "checkout_sessions": "checkoutSessionKey", "events": "eventKey", "venues": "venueKey", "metros": "metroKey", "instructors": "instructorKey",
}
OVERLAP = dt.timedelta(hours=2)
SOURCE = "cms"


class CmsClient:
    def __init__(self, base_url: str, token: str, http=None, timeout: int = 60):
        self.base_url, self.token, self.http, self.timeout = base_url.rstrip("/"), token, http or requests.Session(), timeout

    def iter_pages(self, entity: str, since: dt.datetime | None, full: bool, page_size: int = 1000) -> Iterator[dict]:
        params: dict = {"pageSize": page_size}
        if full:
            params["full"] = 1
        elif since is not None:
            params["since"] = since.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        cursor = None
        while True:
            if cursor:
                params["cursor"] = cursor
            resp = self.http.get(f"{self.base_url}/api/export/{entity}", headers={"Authorization": f"Bearer {self.token}"}, params=dict(params), timeout=self.timeout)
            resp.raise_for_status()
            body = resp.json()
            yield body
            cursor = body.get("nextCursor")
            if not cursor:
                return


def _parse_ts(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def load_cms(settings: Settings, writer: RawWriter, state: LoadState, entities: tuple[str, ...] | None = None,
             full: bool = False, mode: str = "daily", http=None) -> list[StepResult]:
    entities = entities or (FACT_ENTITIES + DIM_ENTITIES)
    results: list[StepResult] = []
    for entity in entities:
        def step(entity=entity) -> int:
            if not settings.cms_token:
                raise RuntimeError("CMS_EXPORT_TOKEN is not set")
            client = CmsClient(settings.cms_base_url, settings.cms_token, http=http)
            reload_full = full or (mode == "daily" and entity in DIM_ENTITIES)
            wm = None if reload_full else state.get(SOURCE, entity)
            since = wm.updated_at if wm else None
            key_field = KEY_FIELD[entity]
            total, newest = 0, None
            for page in client.iter_pages(entity, since=since, full=reload_full):
                rows = [RawRow(str(item[key_field]), _parse_ts(item["updatedAt"]), item) for item in page["items"]]
                total += writer.append(RAW_CMS, entity, rows)
                for r in rows:
                    newest = r.updated_at if newest is None or r.updated_at > newest else newest
            if newest is not None:
                state.set(SOURCE, entity, newest - OVERLAP)
            return total
        results.append(run_step(state, settings.run_id, f"{SOURCE}.{entity}", step))
    return results
```

- [ ] **Step 4: Run to verify pass** — `pytest -q tests/test_cms.py` → `5 passed`.

- [ ] **Step 5: Commit** — `git add loaders/cms.py tests/test_cms.py tests/fixtures && git commit -m "feat: CMS export loader with cursor paging and overlap watermark"`

---

### Task 5: Stripe loader

**Files:**
- Create: `loaders/stripe_loader.py`, `tests/test_stripe.py`

**Interfaces:**
- Consumes: `RawWriter`, `LoadState`, `run_step`, `Settings.stripe_key`.
- Produces: `STRIPE_ENTITIES = ("balance_transactions", "refunds", "disputes", "payouts")`, `BACKFILL_FROM = 2026-06-19T00:00:00Z`, `OVERLAP = timedelta(days=1)`, `load_stripe(settings, writer, state, full=False, api=None) -> list[StepResult]`. `api` is an object exposing `BalanceTransaction`, `Refund`, `Dispute`, `Payout` with `.list(**kw).auto_paging_iter()` (the `stripe` module by default).

- [ ] **Step 1: Write the failing tests**

```python
import datetime as dt

from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from loaders.stripe_loader import BACKFILL_FROM, OVERLAP, load_stripe
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


class _Obj(dict):
    """Stripe objects behave like dicts with .id and to_dict()."""
    @property
    def id(self): return self["id"]
    def to_dict_recursive(self): return dict(self)


class _Resource:
    def __init__(self, items): self.items, self.calls = items, []
    def list(self, **kw):
        self.calls.append(kw)
        items = self.items
        class _L:
            def auto_paging_iter(_self): return iter(items)
        return _L()


class FakeStripe:
    def __init__(self):
        self.BalanceTransaction = _Resource([_Obj(id="txn_1", created=1758800000, type="charge", amount=13600, fee=425, net=13175, source=_Obj(id="ch_1", metadata={"OrderGuid": "1111"}))])
        self.Refund = _Resource([_Obj(id="re_1", created=1758803600, amount=6800, status="succeeded")])
        self.Dispute = _Resource([]); self.Payout = _Resource([])


def _settings(): return Settings.from_env({"CMS_BASE_URL": "x", "STRIPE_RESTRICTED_KEY": "rk_test"})


def test_full_backfill_starts_at_launch_and_expands_source():
    bq = FakeBqClient(); api = FakeStripe()
    res = load_stripe(_settings(), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), full=True, api=api)
    assert [r.status for r in res] == ["ok"] * 4
    assert api.BalanceTransaction.calls[0] == {"limit": 100, "created": {"gte": int(BACKFILL_FROM.timestamp())}, "expand": ["data.source"]}
    dest, rows = [l for l in bq.loads if l[0].endswith("raw_stripe.balance_transactions")][0]
    assert rows[0]["key"] == "txn_1" and rows[0]["updated_at"] == "2026-09-25T11:33:20+00:00"


def test_incremental_uses_watermark_minus_overlap():
    bq = FakeBqClient(); api = FakeStripe()
    wm = dt.datetime(2026, 9, 25, 0, 0, tzinfo=UTC)
    bq.query_results.extend([[{"watermark": wm, "cursor": None}]] * 8)
    load_stripe(_settings(), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), api=api)
    assert api.Refund.calls[0]["created"]["gte"] == int((wm - OVERLAP).timestamp())


def test_missing_key_is_step_error():
    bq = FakeBqClient(); s = Settings.from_env({"CMS_BASE_URL": "x"})
    res = load_stripe(s, RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), api=FakeStripe())
    assert all(r.status == "error" and "STRIPE_RESTRICTED_KEY" in r.message for r in res)
```

- [ ] **Step 2: Run to verify failure** — import error.

- [ ] **Step 3: Implement**

`loaders/stripe_loader.py`:

```python
"""Stripe: balance transactions (with expanded source for order metadata), refunds, disputes, payouts. Reconciliation only."""
from __future__ import annotations

import datetime as dt

from loaders.common.bq import RawRow, RawWriter
from loaders.common.config import RAW_STRIPE, Settings
from loaders.common.state import LoadState, StepResult, run_step

STRIPE_ENTITIES = ("balance_transactions", "refunds", "disputes", "payouts")
RESOURCE = {"balance_transactions": "BalanceTransaction", "refunds": "Refund", "disputes": "Dispute", "payouts": "Payout"}
EXPAND = {"balance_transactions": ["data.source"]}
BACKFILL_FROM = dt.datetime(2026, 6, 19, tzinfo=dt.timezone.utc)   # earlier history is WooCommerce, already archived
OVERLAP = dt.timedelta(days=1)
SOURCE = "stripe"


def load_stripe(settings: Settings, writer: RawWriter, state: LoadState, full: bool = False, api=None) -> list[StepResult]:
    results: list[StepResult] = []
    for entity in STRIPE_ENTITIES:
        def step(entity=entity) -> int:
            if not settings.stripe_key:
                raise RuntimeError("STRIPE_RESTRICTED_KEY is not set")
            sdk = api
            if sdk is None:
                import stripe as sdk  # type: ignore
                sdk.api_key = settings.stripe_key
            wm = None if full else state.get(SOURCE, entity)
            start = (wm.updated_at - OVERLAP) if wm else BACKFILL_FROM
            kw = {"limit": 100, "created": {"gte": int(start.timestamp())}}
            if entity in EXPAND:
                kw["expand"] = EXPAND[entity]
            resource = getattr(sdk, RESOURCE[entity])
            batch, total, newest = [], 0, None
            for obj in resource.list(**kw).auto_paging_iter():
                created = dt.datetime.fromtimestamp(int(obj["created"]), tz=dt.timezone.utc)
                batch.append(RawRow(obj["id"], created, obj.to_dict_recursive()))
                newest = created if newest is None or created > newest else newest
                if len(batch) >= 5000:
                    total += writer.append(RAW_STRIPE, entity, batch); batch = []
            total += writer.append(RAW_STRIPE, entity, batch)
            if newest is not None:
                state.set(SOURCE, entity, newest)
            return total
        results.append(run_step(state, settings.run_id, f"{SOURCE}.{entity}", step))
    return results
```

- [ ] **Step 4: Run to verify pass** — `3 passed`.

- [ ] **Step 5: Commit** — `git add loaders/stripe_loader.py tests/test_stripe.py && git commit -m "feat: Stripe reconciliation loader"`

---

### Task 6: Search Console loader

**Files:**
- Create: `loaders/gsc.py`, `tests/test_gsc.py`

**Interfaces:**
- Consumes: `RawWriter`, `LoadState`, `Settings.gsc_properties`.
- Produces: `DIMENSION_SETS = {"page_query": ["date","page","query"], "page_device_country": ["date","page","device","country"]}`, `BACKFILL_DAYS = 480`, `OVERLAP_DAYS = 3`, `row_key(property, dims: list[str], values: list[str]) -> str` (sha1 hex), `load_gsc(settings, writer, state, full=False, service=None, today=None) -> list[StepResult]`. `service` is a `searchconsole` v1 resource; default built with `googleapiclient.discovery.build("searchconsole","v1")` on ADC.

- [ ] **Step 1: Write the failing tests**

```python
import datetime as dt

from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from loaders.gsc import DIMENSION_SETS, load_gsc, row_key
from tests.fakes import FakeBqClient

UTC = dt.timezone.utc


class FakeGsc:
    def __init__(self): self.calls = []
    def searchanalytics(self): return self
    def query(self, siteUrl, body):
        self.calls.append((siteUrl, body))
        class _E:
            def execute(_self):
                if body["startRow"] > 0:
                    return {}
                return {"rows": [{"keys": [body["startDate"], "https://www.sipandscript.com/metros/dallas/", "calligraphy classes dallas"] if len(body["dimensions"]) == 3
                                  else [body["startDate"], "https://www.sipandscript.com/", "MOBILE", "usa"], "clicks": 3, "impressions": 40, "ctr": 0.075, "position": 4.2}]}
        return _E()


def test_row_key_is_stable_and_property_scoped():
    a = row_key("https://sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])
    b = row_key("https://www.sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])
    assert a != b and len(a) == 40 and a == row_key("https://sipandscript.com/", ["date", "page", "query"], ["2026-09-25", "/x", "q"])


def test_gsc_key_and_updated_at():
    bq = FakeBqClient(); svc = FakeGsc(); today = dt.date(2026, 9, 26)
    s = Settings.from_env({"CMS_BASE_URL": "x"})
    bq.query_results.extend([[{"watermark": dt.datetime(2026, 9, 24, tzinfo=UTC), "cursor": None}]] * 12)
    res = load_gsc(s, RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), service=svc, today=today)
    assert all(r.status == "ok" for r in res)
    # window = watermark - 3 days .. today - 2 (GSC data is final ~2 days later)
    dates = sorted({c[1]["startDate"] for c in svc.calls})
    assert dates[0] == "2026-09-21" and dates[-1] == "2026-09-24"
    dest, rows = [l for l in bq.loads if l[0].endswith("raw_gsc.page_query")][0]
    assert rows[0]["updated_at"].startswith("2026-09-26")           # updated_at = load day, so a restated day supersedes older loads
    assert rows[0]["key"] == row_key("https://sipandscript.com/", DIMENSION_SETS["page_query"], ["2026-09-21", "https://www.sipandscript.com/metros/dallas/", "calligraphy classes dallas"])


def test_full_backfills_480_days():
    bq = FakeBqClient(); svc = FakeGsc(); today = dt.date(2026, 9, 26)
    load_gsc(Settings.from_env({"CMS_BASE_URL": "x"}), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), full=True, service=svc, today=today)
    assert min(c[1]["startDate"] for c in svc.calls) == "2025-06-03"
```

- [ ] **Step 2: Run to verify failure** — import error.

- [ ] **Step 3: Implement**

`loaders/gsc.py`:

```python
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
```

- [ ] **Step 4: Run to verify pass** — `3 passed`.

- [ ] **Step 5: Commit** — `git add loaders/gsc.py tests/test_gsc.py && git commit -m "feat: Search Console loader for both properties"`

---

### Task 7: Spend CSV drop loader

**Files:**
- Create: `loaders/spend_csv.py`, `tests/test_spend_csv.py`

**Interfaces:**
- Consumes: `RawWriter`, `LoadState`, `Settings.spend_bucket`, `FakeStorageClient`.
- Produces: `PLATFORMS = ("meta", "pinterest")`, `normalise_header(h: str) -> str`, `REQUIRED = {"date","campaign_name","spend","impressions","clicks"}`, `parse_csv(platform, object_name, text) -> list[RawRow]` (key = sha1(platform|date|campaign_name); `updated_at` = file generation time), `load_spend_csv(settings, writer, state, storage=None) -> list[StepResult]`. State per file: `state.get("spend", object_name)` holds the generation as `cursor`.

- [ ] **Step 1: Write the failing tests**

```python
import datetime as dt

from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from loaders.spend_csv import load_spend_csv, normalise_header, parse_csv
from tests.fakes import FakeBqClient, FakeBucketBlob, FakeStorageClient

META = "Day,Campaign name,Amount spent (USD),Impressions,Link clicks\n2026-09-25,SNS | Paid Social | Dallas,42.10,5000,120\n"
PIN = "Date,Campaign,Spend,Impressions,Pin clicks\n2026-09-25,Fall Classes,10.00,800,15\n"


def test_normalise_header_maps_platform_variants():
    assert normalise_header("Amount spent (USD)") == "spend" and normalise_header("Link clicks") == "clicks"
    assert normalise_header("Day") == "date" and normalise_header("Campaign") == "campaign_name" and normalise_header("Pin clicks") == "clicks"


def test_parse_csv_builds_rows():
    rows = parse_csv("meta", "spend/meta/sep.csv", META, generation=17)
    assert len(rows) == 1 and rows[0].payload == {"platform": "meta", "file": "spend/meta/sep.csv", "date": "2026-09-25", "campaign_name": "SNS | Paid Social | Dallas", "spend": 42.1, "impressions": 5000, "clicks": 120}


def test_parse_csv_missing_column_raises():
    import pytest
    with pytest.raises(ValueError, match="clicks"):
        parse_csv("meta", "f.csv", "Day,Campaign name,Amount spent (USD),Impressions\n2026-09-25,x,1,2\n", generation=1)


def test_spend_skip_same_generation_reload_new_generation():
    bq = FakeBqClient(); s = Settings.from_env({"CMS_BASE_URL": "x"})
    blobs = [FakeBucketBlob("spend/meta/sep.csv", 17, META), FakeBucketBlob("spend/pinterest/sep.csv", 5, PIN)]
    # first file already loaded at generation 17; second never loaded
    bq.query_results.extend([[{"watermark": dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc), "cursor": "17"}], []])
    res = load_spend_csv(s, RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), storage=FakeStorageClient(blobs))
    assert [(r.step, r.rows) for r in res] == [("spend.spend/meta/sep.csv", 0), ("spend.spend/pinterest/sep.csv", 1)]
    # now meta file re-exported: new generation 18 -> reload
    bq2 = FakeBqClient(); bq2.query_results.extend([[{"watermark": dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc), "cursor": "17"}]])
    res2 = load_spend_csv(s, RawWriter(bq2, "sipandscript", "r"), LoadState(bq2, "sipandscript"), storage=FakeStorageClient([FakeBucketBlob("spend/meta/sep.csv", 18, META)]))
    assert res2[0].rows == 1
```

- [ ] **Step 2: Run to verify failure** — import error.

- [ ] **Step 3: Implement**

`loaders/spend_csv.py`:

```python
"""Meta / Pinterest Ads Manager CSV drops in gs://<bucket>/spend/<platform>/*.csv. Stopgap until the Ads APIs (phase two)."""
from __future__ import annotations

import csv
import datetime as dt
import hashlib
import io

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


def normalise_header(h: str) -> str:
    return HEADER_MAP.get(h.strip().lower(), h.strip().lower().replace(" ", "_"))


def parse_csv(platform: str, object_name: str, text: str, generation: int) -> list[RawRow]:
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
             "spend": float(rec["spend"].replace(",", "") or 0), "impressions": int(float(rec["impressions"].replace(",", "") or 0)),
             "clicks": int(float(rec["clicks"].replace(",", "") or 0))}))
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
```

- [ ] **Step 4: Run to verify pass** — `4 passed`.

- [ ] **Step 5: Commit** — `git add loaders/spend_csv.py tests/test_spend_csv.py && git commit -m "feat: ad spend CSV drop loader"`

---

### Task 8: CLI, Slack status, container entrypoint

**Files:**
- Create: `loaders/__main__.py`, `loaders/common/slack.py`, `Dockerfile` (repo root, so `gcloud run jobs deploy --source .` finds it), `jobs/entrypoint.sh`, `tests/test_cli.py`

**Interfaces:**
- Consumes: every `load_*` function, `LoadState.ensure`, `RawWriter.ensure_dataset`.
- Produces: `python -m loaders run --sources cms,stripe,gsc,spend [--full] [--mode daily|hourly]` exit code 0 when every step is ok, 2 when any step errored (dbt still runs; the entrypoint decides). `summarise(results: list[StepResult]) -> str` one-line Slack text. `post_status(settings, text) -> None` (no-op without a token).

- [ ] **Step 1: Write the failing tests**

```python
from loaders.__main__ import summarise, parse_args
from loaders.common.state import StepResult


def test_summarise_counts_rows_per_source_and_lists_errors():
    res = [StepResult("cms.orders", "ok", 412), StepResult("cms.tickets", "ok", 900), StepResult("stripe.refunds", "error", 0, "RuntimeError: boom"),
           StepResult("gsc.page_query.www", "ok", 21530)]
    text = summarise(res)
    assert text.startswith("sns-analytics loaders: ") and "cms 1,312" in text and "gsc 21,530" in text
    assert "⚠ stripe.refunds: RuntimeError: boom" in text


def test_parse_args_defaults():
    a = parse_args(["run"])
    assert a.sources == ["cms", "stripe", "gsc", "spend"] and a.mode == "daily" and not a.full
    assert parse_args(["run", "--sources", "cms", "--mode", "hourly"]).sources == ["cms"]
```

- [ ] **Step 2: Run to verify failure** — import error.

- [ ] **Step 3: Implement**

`loaders/common/slack.py`:

```python
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
```

`loaders/__main__.py`:

```python
"""python -m loaders run --sources cms,stripe,gsc,spend [--full] [--mode daily|hourly]"""
from __future__ import annotations

import argparse
import collections
import os
import sys

from google.cloud import bigquery

from loaders.common.bq import RawWriter
from loaders.common.config import OPS, RAW_CMS, RAW_GSC, RAW_SPEND, RAW_STRIPE, Settings
from loaders.common.slack import post_status
from loaders.common.state import LoadState, StepResult

ALL = ["cms", "stripe", "gsc", "spend"]


def parse_args(argv):
    p = argparse.ArgumentParser(prog="loaders")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--sources", default=",".join(ALL), type=lambda s: [x for x in s.split(",") if x])
    r.add_argument("--full", action="store_true")
    r.add_argument("--mode", choices=["daily", "hourly"], default="daily")
    return p.parse_args(argv)


def summarise(results: list[StepResult]) -> str:
    per = collections.OrderedDict()
    for r in results:
        per[r.step.split(".")[0]] = per.get(r.step.split(".")[0], 0) + r.rows
    parts = [f"{k} {v:,}" for k, v in per.items()]
    errors = [f"⚠ {r.step}: {r.message.splitlines()[0]}" for r in results if r.status == "error"]
    return "sns-analytics loaders: " + " · ".join(parts) + ("\n" + "\n".join(errors) if errors else "")


def main(argv=None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    settings = Settings.from_env(os.environ)
    client = bigquery.Client(project=settings.project, location=settings.location)
    writer = RawWriter(client, settings.project, settings.run_id, settings.location)
    for ds in (RAW_CMS, RAW_STRIPE, RAW_GSC, RAW_SPEND, OPS):
        writer.ensure_dataset(ds)
    state = LoadState(client, settings.project); state.ensure()

    results: list[StepResult] = []
    if "cms" in args.sources:
        from loaders.cms import load_cms
        results += load_cms(settings, writer, state, full=args.full, mode=args.mode)
    if "stripe" in args.sources:
        from loaders.stripe_loader import load_stripe
        results += load_stripe(settings, writer, state, full=args.full)
    if "gsc" in args.sources:
        from loaders.gsc import load_gsc
        results += load_gsc(settings, writer, state, full=args.full)
    if "spend" in args.sources:
        from loaders.spend_csv import load_spend_csv
        results += load_spend_csv(settings, writer, state)

    text = summarise(results)
    print(text)
    if any(r.status == "error" for r in results):
        post_status(settings, text)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

`Dockerfile` (repo root):

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml README.md ./
COPY loaders ./loaders
COPY dbt ./dbt
COPY jobs/entrypoint.sh ./entrypoint.sh
RUN pip install --no-cache-dir -e . "dbt-bigquery>=1.12,<2" && cd dbt && dbt deps
ENV DBT_PROFILES_DIR=/app/dbt
ENTRYPOINT ["/app/entrypoint.sh"]
```

`jobs/entrypoint.sh`:

```bash
#!/usr/bin/env bash
# MODE=daily|hourly (default daily). Loaders never abort the run; dbt builds on whatever loaded.
set -uo pipefail
MODE="${MODE:-daily}"
if [ "$MODE" = "hourly" ]; then
  python -m loaders run --sources cms --mode hourly; rc=$?
  ( cd /app/dbt && dbt build --select tag:hourly --target prod ); drc=$?
else
  python -m loaders run --mode daily; rc=$?
  ( cd /app/dbt && dbt build --target prod ); drc=$?
fi
python - <<'EOF' "$rc" "$drc" "$MODE"
import os, sys
from loaders.common.config import Settings
from loaders.common.slack import post_status
rc, drc, mode = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
s = Settings.from_env(os.environ)
status = "OK" if rc == 0 and drc == 0 else "PROBLEMS"
post_status(s, f"sns-analytics {mode} {status} — loaders rc={rc}, dbt rc={drc}, run {s.run_id}")
EOF
exit $(( rc != 0 || drc != 0 ))
```

`chmod +x jobs/entrypoint.sh`. The Dockerfile's `dbt deps` needs `dbt/packages.yml` from Task 10; build the image only after Task 10.

- [ ] **Step 4: Run to verify pass** — `pytest -q` → all tests pass (config 3, bq 4, state 5, cms 5, stripe 3, gsc 3, spend 4, cli 2).

- [ ] **Step 5: Commit** — `git add loaders/__main__.py loaders/common/slack.py Dockerfile jobs tests/test_cli.py && git commit -m "feat: loaders CLI, Slack status, container entrypoint"`


---

### Task 9: Infrastructure setup script

**Files:**
- Create: `infra/setup.sh`, `infra/bq_admin.py`, `infra/README.md`

**Interfaces:**
- Produces: `infra/setup.sh` (idempotent; run in Cloud Shell or any machine with a working gcloud ≥ 500) that creates datasets, the service account and IAM, secrets (empty placeholders), the drop bucket, the Google Ads transfer, the Cloud Run job and both schedulers. `infra/bq_admin.py` creates the datasets over REST with ADC for laptops where gcloud is broken (`python infra/bq_admin.py datasets`).

- [ ] **Step 1: Write `infra/bq_admin.py`**

```python
"""Dataset creation over the BigQuery REST API with ADC. For laptops where the gcloud SDK is broken.
Usage: python infra/bq_admin.py datasets"""
import sys
from google.cloud import bigquery

PROJECT, LOCATION = "sipandscript", "US"
DATASETS = ["raw_cms", "raw_stripe", "raw_gsc", "raw_spend", "google_ads", "ops", "staging", "core", "mart"]

if __name__ == "__main__":
    assert sys.argv[1:] == ["datasets"], __doc__
    c = bigquery.Client(project=PROJECT)
    for d in DATASETS:
        ds = bigquery.Dataset(f"{PROJECT}.{d}"); ds.location = LOCATION
        c.create_dataset(ds, exists_ok=True); print("ok", d)
```

- [ ] **Step 2: Write `infra/setup.sh`**

```bash
#!/usr/bin/env bash
# Idempotent GCP setup for the sns-analytics pipeline. Run in Cloud Shell: bash infra/setup.sh
set -euo pipefail
PROJECT=sipandscript; REGION=us-east1; LOCATION=US
SA=sns-analytics@${PROJECT}.iam.gserviceaccount.com
JOB=sns-analytics; BUCKET=sns-analytics-drop; ADS_CUSTOMER=1863952460
gcloud config set project $PROJECT >/dev/null

echo "## datasets"
for d in raw_cms raw_stripe raw_gsc raw_spend google_ads ops staging core mart; do
  bq --location=$LOCATION mk --dataset --quiet "$PROJECT:$d" 2>/dev/null || true
done

echo "## service account + IAM"
gcloud iam service-accounts describe $SA >/dev/null 2>&1 || gcloud iam service-accounts create sns-analytics --display-name "sns-analytics pipeline"
gcloud projects add-iam-policy-binding $PROJECT --member serviceAccount:$SA --role roles/bigquery.jobUser --quiet >/dev/null
for d in raw_cms raw_stripe raw_gsc raw_spend ops staging core mart; do
  bq add-iam-policy-binding --member serviceAccount:$SA --role roles/bigquery.dataEditor "$PROJECT:$d" >/dev/null
done
for d in analytics_313669961 sipandscript_new_ds google_ads; do
  bq add-iam-policy-binding --member serviceAccount:$SA --role roles/bigquery.dataViewer "$PROJECT:$d" >/dev/null
done
gcloud projects add-iam-policy-binding $PROJECT --member serviceAccount:$SA --role roles/secretmanager.secretAccessor --quiet >/dev/null

echo "## bucket"
gsutil ls -b gs://$BUCKET >/dev/null 2>&1 || gsutil mb -l $REGION gs://$BUCKET
gsutil iam ch serviceAccount:$SA:objectViewer gs://$BUCKET

echo "## secrets (placeholders; set real values with: printf '%s' VALUE | gcloud secrets versions add NAME --data-file=-)"
for s in stripe-restricted-key cms-export-token; do
  gcloud secrets describe $s >/dev/null 2>&1 || gcloud secrets create $s --replication-policy=automatic
done

echo "## Google Ads transfer"
if ! bq ls --transfer_config --transfer_location=$LOCATION --format=prettyjson | grep -q '"displayName": "sns-google-ads"'; then
  bq mk --transfer_config --transfer_location=$LOCATION --project_id=$PROJECT --data_source=google_ads \
     --display_name=sns-google-ads --target_dataset=google_ads --params="{\"customer_id\":\"$ADS_CUSTOMER\",\"include_pmax\":true}"
  echo "   -> authorise the transfer in the console (BigQuery > Data transfers > sns-google-ads) with a user who can read Ads customer $ADS_CUSTOMER, then schedule a backfill of 90 days."
fi

echo "## Cloud Run job"
gcloud run jobs deploy $JOB --source . --region $REGION --service-account $SA --memory 2Gi --task-timeout 3600 \
  --set-env-vars CMS_BASE_URL=https://www.sipandscript.com,GCP_PROJECT=$PROJECT,SLACK_CHANNEL=C0C459A46ET,MODE=daily \
  --set-secrets STRIPE_RESTRICTED_KEY=stripe-restricted-key:latest,CMS_EXPORT_TOKEN=cms-export-token:latest,SLACK_BOT_TOKEN=slack-ads-sync-bot-token:latest

echo "## schedulers"
RUN_URI="https://run.googleapis.com/v2/projects/$PROJECT/locations/$REGION/jobs/$JOB:run"
gcloud scheduler jobs describe sns-analytics-daily --location $REGION >/dev/null 2>&1 \
  || gcloud scheduler jobs create http sns-analytics-daily --location $REGION --schedule "0 11 * * *" --time-zone UTC --uri "$RUN_URI" --http-method POST \
       --oauth-service-account-email $SA --message-body '{"overrides":{"containerOverrides":[{"env":[{"name":"MODE","value":"daily"}]}]}}'
gcloud scheduler jobs describe sns-analytics-hourly --location $REGION >/dev/null 2>&1 \
  || gcloud scheduler jobs create http sns-analytics-hourly --location $REGION --schedule "30 * * * *" --time-zone UTC --uri "$RUN_URI" --http-method POST \
       --oauth-service-account-email $SA --message-body '{"overrides":{"containerOverrides":[{"env":[{"name":"MODE","value":"hourly"}]}]}}'
gcloud scheduler jobs pause sns-analytics-daily --location $REGION; gcloud scheduler jobs pause sns-analytics-hourly --location $REGION
echo "schedulers created PAUSED; resume after the first successful manual run (Task 16)."
```

The scheduler's OAuth service account needs `roles/run.invoker` on the job: `gcloud run jobs add-iam-policy-binding $JOB --region $REGION --member serviceAccount:$SA --role roles/run.invoker`. Add that line before the schedulers block. `--source .` uses the root `Dockerfile` from Task 8.

- [ ] **Step 3: Write `infra/README.md`**

```markdown
# Infra

`setup.sh` is idempotent. Run it from Cloud Shell (`gcloud` on the dev laptop is broken). Manual follow-ups it prints:
1. Set secret values: `printf '%s' "$STRIPE_KEY" | gcloud secrets versions add stripe-restricted-key --data-file=-` and the same for `cms-export-token` (value = `Analytics__ExportApiKey` in Doppler).
2. Authorise the Google Ads transfer in the console and backfill 90 days.
3. Add `sns-analytics@sipandscript.iam.gserviceaccount.com` as a Restricted user on both Search Console properties.
4. After the first clean manual run (`gcloud run jobs execute sns-analytics --region us-east1 --wait`), resume both schedulers.
Local datasets only: `python infra/bq_admin.py datasets`.
```

- [ ] **Step 4: Verify** — `bash -n infra/setup.sh` (syntax) and `python infra/bq_admin.py datasets` from the laptop creates the nine datasets (check with the REST listing script in the scratchpad or the BigQuery console).

- [ ] **Step 5: Commit** — `git add infra && git commit -m "infra: idempotent GCP setup and dataset admin"`

---

### Task 10: dbt project, sources, staging views, seeds

**Files:**
- Create: `dbt/dbt_project.yml`, `dbt/profiles.yml`, `dbt/packages.yml`, `dbt/models/sources.yml`, `dbt/macros/latest_raw.sql`, `dbt/macros/channel_group.sql`, `dbt/seeds/date_flags.csv`, `dbt/seeds/campaign_metro_map.csv`, `dbt/models/staging/cms/stg_cms__*.sql` (12 files), `dbt/models/staging/woo/stg_woo__*.sql` (5 files), `dbt/models/staging/stripe/stg_stripe__balance_transactions.sql`, `stg_stripe__refunds.sql`, `dbt/models/staging/gsc/stg_gsc__page_query.sql`, `dbt/models/staging/spend/stg_spend__csv.sql`, `dbt/models/staging/schema.yml`, `dbt/tests/staging/assert_latest_raw_picks_newest.sql`

**Interfaces:**
- Produces: macro `latest_raw(source_name, table)` → `SELECT key, updated_at, payload, _loaded_at` deduped to newest per key; macro `channel_group(source, medium, campaign, has_gclid)`; staging views named `staging.stg_<source>__<entity>` with typed, snake_case columns and money in dollars; seeds `date_flags(date, flag)` and `campaign_metro_map(campaign_name_pattern, metro_slug)`.

- [ ] **Step 1: Project files**

`dbt/dbt_project.yml`:

```yaml
name: sns_analytics
version: "1.0"
profile: sns_analytics
model-paths: ["models"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
test-paths: ["tests"]
target-path: target
clean-targets: [target, dbt_packages]
vars:
  ga4_dataset: analytics_313669961
  woo_dataset: sipandscript_new_ds
  ads_customer_id: "1863952460"
  launch_date: "2026-06-19"
  ga4_start_date: "2025-01-01"          # sessions model floor; widen for deeper history
models:
  sns_analytics:
    staging: {+materialized: view, +schema: staging}
    core: {+materialized: table, +schema: core}
    marts: {+materialized: table, +schema: mart}
seeds:
  sns_analytics: {+schema: ops}
```

`dbt/profiles.yml` (dataset names must not get the default `<target>_<schema>` prefix, so add the custom schema macro below):

```yaml
sns_analytics:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: oauth
      project: sipandscript
      dataset: staging
      location: US
      threads: 8
      job_execution_timeout_seconds: 600
    prod:
      type: bigquery
      method: oauth            # Cloud Run: the job's service-account identity via ADC
      project: sipandscript
      dataset: staging
      location: US
      threads: 8
      job_execution_timeout_seconds: 1800
```

`dbt/macros/generate_schema_name.sql`:

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ custom_schema_name if custom_schema_name is not none else target.schema }}
{%- endmacro %}
```

`dbt/packages.yml`:

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.3.0", "<2.0.0"]
```

- [ ] **Step 2: Sources**

`dbt/models/sources.yml`:

```yaml
version: 2
sources:
  - name: raw_cms
    tables: [orders, order_items, tickets, refunds, promo_redemptions, gift_cards, gift_card_transactions, checkout_sessions, events, venues, metros, instructors]
  - name: raw_stripe
    tables: [balance_transactions, refunds, disputes, payouts]
  - name: raw_gsc
    tables: [page_query, page_device_country]
  - name: raw_spend
    tables: [meta, pinterest]
  - name: ga4
    schema: "{{ var('ga4_dataset') }}"
    tables:
      - name: events
        identifier: events_*
  - name: woo
    schema: "{{ var('woo_dataset') }}"
    tables: [orders, order_line_items, products, events, venues, organizers, _staging_products]
  - name: google_ads
    tables:
      - name: campaign_stats
        identifier: "ads_CampaignBasicStats_{{ var('ads_customer_id') }}"
      - name: campaign
        identifier: "ads_Campaign_{{ var('ads_customer_id') }}"
      - name: click_stats
        identifier: "ads_ClickStats_{{ var('ads_customer_id') }}"
  - name: public_geo
    database: bigquery-public-data
    schema: geo_us_boundaries
    tables: [zip_codes]
```

After the first Google Ads transfer run, confirm the three table names with `SELECT table_name FROM google_ads.INFORMATION_SCHEMA.TABLES` and fix the identifiers if they differ.

- [ ] **Step 3: Macros**

`dbt/macros/latest_raw.sql`:

```sql
{% macro latest_raw(source_name, table_name) %}
select key, updated_at, payload, _loaded_at
from {{ source(source_name, table_name) }}
qualify row_number() over (partition by key order by updated_at desc, _loaded_at desc) = 1
{% endmacro %}
```

`dbt/macros/channel_group.sql` (GA4-style default channel grouping, simplified to what this site sees):

```sql
{% macro channel_group(source, medium, campaign, has_gclid) %}
case
  when {{ has_gclid }} or lower({{ medium }}) in ('cpc','ppc','paidsearch','paid_search') and lower({{ source }}) in ('google','bing','yahoo','duckduckgo') then 'Paid Search'
  when lower({{ medium }}) in ('cpc','ppc','paid','paidsocial','paid_social','paid-social','social_paid') then 'Paid Social'
  when lower({{ source }}) in ('facebook','instagram','fb','ig','m.facebook.com','l.facebook.com','l.instagram.com','pinterest','pinterest.com','tiktok','linkedin','twitter','t.co','youtube') then 'Organic Social'
  when lower({{ medium }}) = 'organic' or lower({{ source }}) in ('google','bing','yahoo','duckduckgo','ecosia') then 'Organic Search'
  when lower({{ medium }}) in ('email','e-mail','newsletter') or lower({{ source }}) like '%klaviyo%' then 'Email'
  when {{ source }} is null or {{ source }} = '(direct)' then 'Direct'
  when lower({{ medium }}) = 'referral' then 'Referral'
  else 'Other'
end
{% endmacro %}
```

- [ ] **Step 4: Seeds**

`dbt/seeds/date_flags.csv`:

```csv
date,flag,note
2026-06-19,unreliable_ga4,platform cutover; GA4 purchase tracking blackout
2026-06-20,unreliable_ga4,cutover blackout
2026-06-21,unreliable_ga4,cutover blackout
2026-06-22,unreliable_ga4,cutover blackout
```

`dbt/seeds/campaign_metro_map.csv` — one row per metro campaign; build it from `scripts/google-ads/metros.json` in the CMS repo (`jq -r '.[] | "\(.campaign_suffix // .name),\(.slug)"'`; open the file to see the exact field names) plus the near-me campaigns listed in `docs/superpowers/specs/2026-09-25-google-ads-search-launch.md`:

```csv
campaign_name_pattern,metro_slug
SNS | Search | Near Me | Boston,boston
SNS | Search | Near Me | Bay Area,bay-area
SNS | Search | Near Me | NYC,nyc
SNS | Search | Near Me | Washington DC,washington-dc
SNS | Search | Near Me | Dallas,dallas
SNS | Search | Near Me | Los Angeles,los-angeles
SNS | Search | Near Me | Chicago,chicago
SNS | Search | Near Me | Nashville,nashville
SNS | Search | Near Me | Tampa,tampa
SNS | Search | Near Me | Seattle,seattle
SNS | Search | Near Me | Raleigh-Durham,raleigh-durham
SNS | Search | Near Me | NH & Maine,nh-maine
SNS | Search | Near Me | San Antonio,san-antonio
SNS | Search | Near Me | Rhode Island,rhode-island
SNS | Search | Near Me | Atlanta,atlanta
SNS | Search | Near Me | Philadelphia,philadelphia
```

Verify each `metro_slug` exists in `raw_cms.metros` (`select json_value(payload,'$.slug') from raw_cms.metros`) once the CMS loader has run; fix any that differ.

- [ ] **Step 5: Staging views — CMS**

`dbt/models/staging/cms/stg_cms__orders.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'orders') }})
select
  key                                                       as order_key,
  json_value(payload, '$.orderNumber')                      as order_number,
  json_value(payload, '$.status')                           as status,
  timestamp(json_value(payload, '$.createdAt'))             as created_at,
  timestamp(json_value(payload, '$.paidAt'))                as paid_at,
  updated_at,
  json_value(payload, '$.currency')                         as currency,
  cast(json_value(payload, '$.subtotalCents') as int64) / 100      as subtotal,
  cast(json_value(payload, '$.discountCents') as int64) / 100      as discount,
  cast(json_value(payload, '$.serviceFeeCents') as int64) / 100    as service_fee,
  cast(json_value(payload, '$.giftCardAmountCents') as int64) / 100 as gift_card_applied,
  cast(json_value(payload, '$.totalCents') as int64) / 100         as total,
  json_value(payload, '$.promoCode')                        as promo_code,
  json_value(payload, '$.affiliateKey')                     as affiliate_key,
  json_value(payload, '$.memberKey')                        as member_key,
  json_value(payload, '$.customerHash')                     as customer_hash,
  json_value(payload, '$.billingCity')                      as billing_city,
  json_value(payload, '$.billingState')                     as billing_state,
  json_value(payload, '$.billingZip')                       as billing_zip,
  json_value(payload, '$.checkoutSessionKey')               as checkout_session_key,
  json_value(payload, '$.stripeCheckoutSessionId')          as stripe_checkout_session_id,
  json_value(payload, '$.source')                           as source,
  json_value(payload, '$.wordpressOrderId')                 as wordpress_order_id
from latest
```

`stg_cms__order_items.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'order_items') }})
select key as order_item_key, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.checkoutSessionKey') as checkout_session_key,
  json_value(payload, '$.itemType') as item_type, json_value(payload, '$.ticketKey') as ticket_key, json_value(payload, '$.giftCardKey') as gift_card_key,
  json_value(payload, '$.eventKey') as event_key, cast(json_value(payload, '$.quantity') as int64) as quantity,
  cast(json_value(payload, '$.unitPriceCents') as int64) / 100 as unit_price, cast(json_value(payload, '$.lineTotalCents') as int64) / 100 as line_total,
  json_value(payload, '$.status') as status, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
```

`stg_cms__tickets.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'tickets') }})
select key as ticket_key, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.orderItemKey') as order_item_key,
  json_value(payload, '$.eventKey') as event_key, json_value(payload, '$.status') as status,
  json_value(payload, '$.transferredFromTicketKey') as transferred_from_ticket_key,
  timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
```

`stg_cms__refunds.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'refunds') }})
select key as refund_key, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.ticketKey') as ticket_key,
  cast(json_value(payload, '$.amountCents') as int64) / 100 as amount, json_value(payload, '$.currency') as currency,
  json_value(payload, '$.reason') as reason, json_value(payload, '$.status') as status, json_value(payload, '$.stripeRefundId') as stripe_refund_id,
  timestamp(json_value(payload, '$.createdAt')) as created_at, timestamp(json_value(payload, '$.completedAt')) as completed_at, updated_at
from latest
```

`stg_cms__promo_redemptions.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'promo_redemptions') }})
select key as redemption_key, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.checkoutSessionKey') as checkout_session_key,
  json_value(payload, '$.promoCode') as promo_code, json_value(payload, '$.eventKey') as event_key,
  cast(json_value(payload, '$.discountCents') as int64) / 100 as discount, json_value(payload, '$.status') as status,
  timestamp(json_value(payload, '$.reservedAt')) as reserved_at, timestamp(json_value(payload, '$.redeemedAt')) as redeemed_at, updated_at
from latest
```

`stg_cms__gift_cards.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'gift_cards') }})
select key as gift_card_key, json_value(payload, '$.orderKey') as order_key,
  cast(json_value(payload, '$.initialCents') as int64) / 100 as initial_amount, cast(json_value(payload, '$.balanceCents') as int64) / 100 as balance,
  json_value(payload, '$.currency') as currency, json_value(payload, '$.status') as status,
  timestamp(json_value(payload, '$.issuedAt')) as issued_at, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
```

`stg_cms__gift_card_transactions.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'gift_card_transactions') }})
select key as transaction_key, json_value(payload, '$.giftCardKey') as gift_card_key, json_value(payload, '$.orderKey') as order_key,
  cast(json_value(payload, '$.amountCents') as int64) / 100 as amount, json_value(payload, '$.type') as type,
  timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
```

`stg_cms__checkout_sessions.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'checkout_sessions') }})
select key as checkout_session_key, json_value(payload, '$.status') as status, json_value(payload, '$.memberKey') as member_key,
  json_value(payload, '$.customerHash') as customer_hash, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.eventKey') as event_key,
  cast(json_value(payload, '$.guestCount') as int64) as guest_count, timestamp(json_value(payload, '$.createdAt')) as created_at,
  timestamp(json_value(payload, '$.holdExpiresAt')) as hold_expires_at, timestamp(json_value(payload, '$.lastActivityAt')) as last_activity_at, updated_at
from latest
```

`stg_cms__events.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'events') }})
select key as event_key, json_value(payload, '$.title') as title, json_value(payload, '$.urlPath') as url_path,
  date(timestamp(json_value(payload, '$.eventDate'))) as event_date,
  json_value(payload, '$.startTime') as start_time, json_value(payload, '$.endTime') as end_time, json_value(payload, '$.timeZone') as time_zone,
  json_value(payload, '$.venueKey') as venue_key, json_value(payload, '$.metroKey') as metro_key, json_value(payload, '$.instructorKey') as instructor_key,
  json_value(payload, '$.category') as category, json_value(payload, '$.eventType') as event_type, json_value(payload, '$.theme') as theme,
  json_value(payload, '$.status') as status, cast(json_value(payload, '$.capacity') as int64) as capacity,
  cast(json_value(payload, '$.ticketPriceCents') as int64) / 100 as ticket_price, cast(json_value(payload, '$.isVirtual') as bool) as is_virtual,
  cast(json_value(payload, '$.noTickets') as bool) as no_tickets, json_value(payload, '$.externalTicketUrl') as external_ticket_url,
  json_value(payload, '$.wordpressSourceId') as wordpress_source_id, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
```

`stg_cms__venues.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'venues') }})
select key as venue_key, json_value(payload, '$.name') as name, json_value(payload, '$.city') as city, json_value(payload, '$.state') as state,
  json_value(payload, '$.zip') as zip, cast(json_value(payload, '$.latitude') as float64) as latitude, cast(json_value(payload, '$.longitude') as float64) as longitude,
  json_value(payload, '$.metroKey') as metro_key, cast(json_value(payload, '$.capacity') as int64) as capacity, json_value(payload, '$.timeZone') as time_zone,
  json_value(payload, '$.wordpressSourceId') as wordpress_source_id, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
```

`stg_cms__metros.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'metros') }})
select key as metro_key, json_value(payload, '$.name') as name, json_value(payload, '$.slug') as slug, json_value(payload, '$.urlPath') as url_path,
  json_value(payload, '$.centerPlace') as center_place, cast(json_value(payload, '$.centerLatitude') as float64) as center_latitude,
  cast(json_value(payload, '$.centerLongitude') as float64) as center_longitude, cast(json_value(payload, '$.radiusMiles') as int64) as radius_miles,
  timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
```

`stg_cms__instructors.sql`:

```sql
with latest as ({{ latest_raw('raw_cms', 'instructors') }})
select key as instructor_key, json_value(payload, '$.name') as name, json_value(payload, '$.urlPath') as url_path, json_value(payload, '$.city') as city,
  json_value(payload, '$.state') as state, timestamp(json_value(payload, '$.startDate')) as start_date, cast(json_value(payload, '$.noLongerTeaches') as bool) as no_longer_teaches,
  json_value(payload, '$.wordpressSourceId') as wordpress_source_id, timestamp(json_value(payload, '$.createdAt')) as created_at, updated_at
from latest
```

- [ ] **Step 6: Staging views — WooCommerce archive**

`dbt/models/staging/woo/stg_woo__orders.sql`:

```sql
select
  concat('woo-', cast(id as string))                     as order_key,
  cast(id as string)                                     as woo_order_id,
  status,
  timestamp_seconds(cast(cast(date_created_gmt as float64) as int64))   as created_at,
  timestamp_seconds(cast(cast(date_paid_gmt as float64) as int64))      as paid_at,
  timestamp_seconds(cast(cast(date_updated_gmt as float64) as int64))   as updated_at,
  currency,
  cast(total as float64)                                 as total,
  cast(discount_total as float64)                        as discount,
  cast(customer_id as string)                            as woo_customer_id,
  billing_city, billing_state, billing_postcode as billing_zip
from {{ source('woo', 'orders') }}
```

`stg_woo__order_line_items.sql`:

```sql
select concat('woo-li-', cast(id as string)) as order_item_key, concat('woo-', cast(order_id as string)) as order_key,
  cast(product_id as string) as woo_product_id, name as item_name, cast(quantity as int64) as quantity,
  cast(total as float64) as line_total, safe_divide(cast(total as float64), nullif(cast(quantity as int64), 0)) as unit_price
from {{ source('woo', 'order_line_items') }}
```

`stg_woo__products.sql` — classify each product once. Run first: `select type, count(*) , countif(venue_id is not null) from sipandscript_new_ds.products group by 1` and adjust the CASE if ticket products carry a distinct `type` value.

```sql
select cast(id as string) as woo_product_id, name, type, cast(venue_id as string) as woo_venue_id,
  case
    when venue_id is not null then 'ticket'
    when lower(name) like '%gift card%' or lower(name) like '%gift certificate%' then 'gift_card'
    else 'materials'
  end as product_kind
from {{ source('woo', 'products') }}
```

`stg_woo__events.sql`:

```sql
select cast(id as string) as woo_event_id, title, status, url,
  timestamp_seconds(cast(cast(event_utc_start_date as float64) as int64)) as start_at,
  cast(event_cost as float64) as event_cost, cast(venue_id as string) as woo_venue_id, cast(organizer_id as string) as woo_organizer_id
from {{ source('woo', 'events') }}
```

`stg_woo__venues.sql`:

```sql
select cast(id as string) as woo_venue_id, name, city, state, zip_code as zip, cast(latitude as float64) as latitude, cast(longitude as float64) as longitude
from {{ source('woo', 'venues') }}
```

If any epoch column is already a TIMESTAMP rather than a float, drop the `timestamp_seconds(cast(cast(... )))` wrapper for that column; check with `select column_name, data_type from sipandscript_new_ds.INFORMATION_SCHEMA.COLUMNS where table_name='orders'`.

- [ ] **Step 7: Staging views — Stripe, GSC, spend**

`stg_stripe__balance_transactions.sql`:

```sql
with latest as ({{ latest_raw('raw_stripe', 'balance_transactions') }})
select key as txn_id, json_value(payload, '$.type') as type, timestamp_seconds(cast(json_value(payload, '$.created') as int64)) as created_at,
  cast(json_value(payload, '$.amount') as int64) / 100 as amount, cast(json_value(payload, '$.fee') as int64) / 100 as fee, cast(json_value(payload, '$.net') as int64) / 100 as net,
  json_value(payload, '$.currency') as currency, json_value(payload, '$.source.id') as source_id, json_value(payload, '$.source.object') as source_object,
  lower(coalesce(json_value(payload, '$.source.metadata.OrderGuid'), json_value(payload, '$.source.metadata.orderGuid'), json_value(payload, '$.source.metadata.order_guid'))) as order_key,
  json_value(payload, '$.source.payment_intent') as payment_intent_id, json_value(payload, '$.source.refund') as refund_id
from latest
```

Check the metadata key name on a real charge (`select json_query(payload, '$.source.metadata') from raw_stripe.balance_transactions limit 5`) and keep only the spelling that exists.

`stg_stripe__refunds.sql`:

```sql
with latest as ({{ latest_raw('raw_stripe', 'refunds') }})
select key as refund_id, timestamp_seconds(cast(json_value(payload, '$.created') as int64)) as created_at,
  cast(json_value(payload, '$.amount') as int64) / 100 as amount, json_value(payload, '$.currency') as currency, json_value(payload, '$.status') as status,
  json_value(payload, '$.charge') as charge_id, json_value(payload, '$.payment_intent') as payment_intent_id, json_value(payload, '$.reason') as reason
from latest
```

`stg_gsc__page_query.sql`:

```sql
with latest as ({{ latest_raw('raw_gsc', 'page_query') }})
select key, json_value(payload, '$.property') as property, date(json_value(payload, '$.date')) as date, json_value(payload, '$.page') as page,
  json_value(payload, '$.query') as query, cast(json_value(payload, '$.clicks') as int64) as clicks, cast(json_value(payload, '$.impressions') as int64) as impressions,
  cast(json_value(payload, '$.position') as float64) as position
from latest
```

`stg_spend__csv.sql`:

```sql
with latest_meta as ({{ latest_raw('raw_spend', 'meta') }}),
     latest_pinterest as ({{ latest_raw('raw_spend', 'pinterest') }})
select key, 'meta' as platform, date(json_value(payload, '$.date')) as date, json_value(payload, '$.campaign_name') as campaign_name,
  cast(json_value(payload, '$.spend') as float64) as spend, cast(json_value(payload, '$.impressions') as int64) as impressions, cast(json_value(payload, '$.clicks') as int64) as clicks
from latest_meta
union all
select key, 'pinterest' as platform, date(json_value(payload, '$.date')) as date, json_value(payload, '$.campaign_name') as campaign_name,
  cast(json_value(payload, '$.spend') as float64) as spend, cast(json_value(payload, '$.impressions') as int64) as impressions, cast(json_value(payload, '$.clicks') as int64) as clicks
from latest_pinterest
```

- [ ] **Step 8: Staging schema tests and the dedup data test**

`dbt/models/staging/schema.yml` — for every staging model: `unique` + `not_null` on its key column; `accepted_values` on `stg_cms__order_items.item_type: [ticket, giftCard, other]`; `not_null` on `stg_cms__orders.created_at`.

`dbt/tests/staging/assert_latest_raw_picks_newest.sql` (fails if any key in staging has an `updated_at` older than the newest raw row for that key):

```sql
select s.order_key
from {{ ref('stg_cms__orders') }} s
join (select key, max(updated_at) as max_updated from {{ source('raw_cms', 'orders') }} group by key) r on r.key = s.order_key
where s.updated_at < r.max_updated
```

- [ ] **Step 9: Build and test**

```bash
cd /Users/stephenchaloner/sns-analytics/dbt && dbt deps && dbt seed && dbt build --select staging
```
Expected: all views created, seeds loaded to `ops`, tests pass. Before the CMS export is live, `raw_cms.*` tables don't exist: run Task 4's loader once against dev1 (`CMS_BASE_URL=https://dev1.sipandscript.com CMS_EXPORT_TOKEN=… python -m loaders run --sources cms --full`) or, if the CMS MR isn't deployed yet, create the raw tables empty with `python - <<'EOF'` calling `RawWriter.ensure_table` for each entity so the views compile; staging tests on empty tables pass.

- [ ] **Step 10: Commit** — `git add dbt && git commit -m "feat(dbt): project, sources, staging views, seeds"`

---

### Task 11: Core commerce and dimension tables

**Files:**
- Create: `dbt/models/core/core_events.sql`, `core_venues.sql`, `core_metros.sql`, `core_instructors.sql`, `core_orders.sql`, `core_order_items.sql`, `core_tickets.sql`, `core_refunds.sql`, `dbt/models/core/schema.yml`, `dbt/tests/core/assert_post_launch_orders_pinned.sql`, `assert_post_launch_ticket_revenue_pinned.sql`, `assert_net_not_above_gross.sql`, `assert_woo_ticket_share_plausible.sql`

**Interfaces:**
- Consumes: staging views from Task 10.
- Produces: the `core` tables with the columns in spec §7. `core_orders.order_key` is the CMS order GUID for `source_system='webapp'` and `woo-<id>` for `'woocommerce'`; `pre_launch = business_date < '2026-06-19'`; `order_type in ('ticket','gift_card','materials','other')`; `net_revenue = gross_revenue - refunded_amount`.

- [ ] **Step 1: Dimensions**

`core_metros.sql`:

```sql
select metro_key, name, slug, url_path, center_latitude, center_longitude, radius_miles, updated_at,
  st_geogpoint(center_longitude, center_latitude) as center_geog
from {{ ref('stg_cms__metros') }}
```

`core_venues.sql`:

```sql
select v.venue_key, v.name, v.city, v.state, v.zip, v.latitude, v.longitude, v.metro_key as assigned_metro_key, v.capacity, v.time_zone, v.wordpress_source_id, v.updated_at,
  coalesce(v.metro_key, nearest.metro_key) as metro_key
from {{ ref('stg_cms__venues') }} v
left join (
  select v2.venue_key, m.metro_key
  from {{ ref('stg_cms__venues') }} v2
  join {{ ref('core_metros') }} m on st_dwithin(st_geogpoint(v2.longitude, v2.latitude), m.center_geog, m.radius_miles * 1609.344)
  qualify row_number() over (partition by v2.venue_key order by st_distance(st_geogpoint(v2.longitude, v2.latitude), m.center_geog)) = 1
) nearest using (venue_key)
```

`core_instructors.sql`:

```sql
select instructor_key, name, url_path, city, state, start_date, no_longer_teaches, wordpress_source_id, updated_at
from {{ ref('stg_cms__instructors') }}
```

`core_events.sql`:

```sql
with e as (select * from {{ ref('stg_cms__events') }}),
sold as (
  select event_key, countif(status in ('Paid','Used')) as seats_sold from {{ ref('stg_cms__tickets') }} group by event_key
)
select e.event_key, e.title, e.url_path, e.event_date,
  timestamp(datetime(e.event_date, coalesce(parse_time('%H:%M:%S', e.start_time), time '00:00:00')), coalesce(e.time_zone, 'America/New_York')) as start_at,
  timestamp(datetime(e.event_date, coalesce(parse_time('%H:%M:%S', e.end_time), time '00:00:00')), coalesce(e.time_zone, 'America/New_York')) as end_at,
  e.venue_key, coalesce(e.metro_key, v.metro_key) as metro_key, e.instructor_key, e.category, e.event_type, e.theme, e.status, e.capacity, e.ticket_price,
  e.is_virtual, e.no_tickets, e.external_ticket_url, e.wordpress_source_id, e.updated_at,
  coalesce(s.seats_sold, 0) as seats_sold, greatest(e.capacity - coalesce(s.seats_sold, 0), 0) as seats_available
from e
left join {{ ref('core_venues') }} v using (venue_key)
left join sold s using (event_key)
```

- [ ] **Step 2: Orders (union of both systems)**

`core_orders.sql`:

```sql
{{ config(tags=['hourly']) }}
with cms_items as (
  select order_key,
    countif(item_type = 'ticket') as ticket_items, countif(item_type = 'giftCard') as gift_items, count(*) as items
  from {{ ref('stg_cms__order_items') }} group by order_key
),
cms_refunds as (
  select order_key, sum(amount) as refunded_amount from {{ ref('stg_cms__refunds') }} where status in ('Completed', 'Succeeded', 'succeeded') group by order_key
),
cms as (
  select o.order_key, 'webapp' as source_system, o.order_number, o.status, o.created_at, o.paid_at,
    date(coalesce(o.paid_at, o.created_at), 'America/New_York') as business_date,
    case when i.ticket_items > 0 then 'ticket' when i.gift_items > 0 then 'gift_card' else 'other' end as order_type,
    o.total as gross_revenue, o.discount, o.service_fee, o.gift_card_applied, coalesce(r.refunded_amount, 0) as refunded_amount,
    coalesce(i.ticket_items, 0) as seats, o.promo_code, o.affiliate_key, o.member_key, o.customer_hash, o.billing_city, o.billing_state, o.billing_zip,
    o.stripe_checkout_session_id, o.updated_at
  from {{ ref('stg_cms__orders') }} o
  left join cms_items i using (order_key)
  left join cms_refunds r using (order_key)
  where o.source = 'webapp' and o.status in ('Paid', 'Partial Refund', 'Refunded')
),
woo_items as (
  select li.order_key,
    sum(case when p.product_kind = 'ticket' then li.quantity else 0 end) as seats,
    sum(case when p.product_kind = 'ticket' then li.line_total else 0 end) as ticket_amount,
    sum(case when p.product_kind = 'gift_card' then li.line_total else 0 end) as gift_amount,
    sum(case when p.product_kind = 'materials' then li.line_total else 0 end) as materials_amount
  from {{ ref('stg_woo__order_line_items') }} li left join {{ ref('stg_woo__products') }} p using (woo_product_id) group by li.order_key
),
woo as (
  select o.order_key, 'woocommerce' as source_system, o.woo_order_id as order_number, o.status, o.created_at, o.paid_at,
    date(coalesce(o.paid_at, o.created_at), 'America/New_York') as business_date,
    case when i.ticket_amount >= greatest(i.gift_amount, i.materials_amount) and i.seats > 0 then 'ticket'
         when i.gift_amount >= i.materials_amount and i.gift_amount > 0 then 'gift_card'
         when i.materials_amount > 0 then 'materials' else 'other' end as order_type,
    o.total as gross_revenue, o.discount, 0.0 as service_fee, 0.0 as gift_card_applied,
    case when o.status = 'refunded' then o.total else 0 end as refunded_amount,
    coalesce(i.seats, 0) as seats, cast(null as string) as promo_code, cast(null as string) as affiliate_key, cast(null as string) as member_key,
    o.woo_customer_id as customer_hash, o.billing_city, o.billing_state, o.billing_zip, cast(null as string) as stripe_checkout_session_id, o.updated_at
  from {{ ref('stg_woo__orders') }} o left join woo_items i using (order_key)
  where o.status in ('completed', 'refunded') and o.created_at < timestamp('{{ var("launch_date") }}', 'America/New_York')
),
unioned as (select * from cms union all select * from woo),
zip_geo as (
  select zip_code, st_geogpoint(internal_point_lon, internal_point_lat) as geog from {{ source('public_geo', 'zip_codes') }}
),
with_metro as (
  select u.*, (
    select m.metro_key from {{ ref('core_metros') }} m
    where st_dwithin(z.geog, m.center_geog, m.radius_miles * 1609.344)
    order by st_distance(z.geog, m.center_geog) limit 1
  ) as billing_metro_key
  from unioned u left join zip_geo z on z.zip_code = left(u.billing_zip, 5)
)
select *, gross_revenue - refunded_amount as net_revenue, business_date < date('{{ var("launch_date") }}') as pre_launch,
  row_number() over (partition by customer_hash order by created_at) = 1 and customer_hash is not null as is_first_order
from with_metro
```

Check `bigquery-public-data.geo_us_boundaries.zip_codes` column names first (`select column_name from bigquery-public-data.geo_us_boundaries.INFORMATION_SCHEMA.COLUMNS where table_name='zip_codes'`); the centroid columns are `internal_point_lat` / `internal_point_lon` at time of writing.

`core_order_items.sql`:

```sql
select order_item_key, order_key, item_type, ticket_key, gift_card_key, event_key, quantity, unit_price, line_total, status, created_at, updated_at
from {{ ref('stg_cms__order_items') }}
union all
select li.order_item_key, li.order_key, case p.product_kind when 'ticket' then 'ticket' when 'gift_card' then 'giftCard' else 'other' end, null, null,
  e.event_key, li.quantity, li.unit_price, li.line_total, 'completed', o.created_at, o.updated_at
from {{ ref('stg_woo__order_line_items') }} li
left join {{ ref('stg_woo__products') }} p using (woo_product_id)
left join {{ source('woo', '_staging_products') }} sp on cast(sp.id as string) = li.woo_product_id
left join {{ ref('core_events') }} e on e.wordpress_source_id = cast(sp.tribe_wooticket_for_event as string)
join {{ ref('stg_woo__orders') }} o using (order_key)
```

`core_tickets.sql`:

```sql
select t.ticket_key, t.order_key, t.order_item_key, t.event_key, t.status, t.transferred_from_ticket_key, t.created_at, t.updated_at, o.business_date
from {{ ref('stg_cms__tickets') }} t
left join {{ ref('core_orders') }} o using (order_key)
```

`core_refunds.sql`:

```sql
select refund_key, order_key, ticket_key, amount, currency, reason, status, stripe_refund_id, created_at, completed_at, updated_at,
  date(coalesce(completed_at, created_at), 'America/New_York') as business_date
from {{ ref('stg_cms__refunds') }}
```

- [ ] **Step 3: Tests**

`dbt/models/core/schema.yml`: `unique`/`not_null` on every `*_key`; `accepted_values` `order_type: [ticket, gift_card, materials, other]`, `source_system: [webapp, woocommerce]`; `relationships` `core_tickets.event_key → core_events.event_key` (config `severity: warn`, old events can be unpublished); `dbt_utils.accepted_range` `gross_revenue min_value: 0`.

`dbt/tests/core/assert_net_not_above_gross.sql`: `select order_key from {{ ref('core_orders') }} where net_revenue > gross_revenue or net_revenue < 0`.

`assert_post_launch_orders_pinned.sql` (spec §11: 5,328 ± 1% orders Jun 23–Sep 17 2026):

```sql
with n as (select count(*) as c from {{ ref('core_orders') }} where source_system = 'webapp' and business_date between '2026-06-23' and '2026-09-17' and status in ('Paid','Partial Refund','Refunded'))
select c from n where c not between 5275 and 5381
```

`assert_post_launch_ticket_revenue_pinned.sql` ($474.1k ± 1% gross ticket revenue, same window, `order_type='ticket'`): `select r from (select sum(gross_revenue) r from ... where order_type='ticket' ...) where r not between 469359 and 478841`.

`assert_woo_ticket_share_plausible.sql`: fails if ticket revenue share of 2025 WooCommerce revenue is outside 60–95% (the brief says materials were ~17–20%): `select share from (select safe_divide(sum(if(order_type='ticket', gross_revenue, 0)), sum(gross_revenue)) share from {{ ref('core_orders') }} where source_system='woocommerce' and extract(year from business_date)=2025) where share not between 0.6 and 0.95`.

- [ ] **Step 4: Build** — `dbt build --select core_metros core_venues core_instructors core_events core_orders core_order_items core_tickets core_refunds`. Expected: all pass. If the pinned-fact tests fail by more than 1%, investigate before loosening: the likely causes are refund status spellings in `cms_refunds` (check `select distinct status from staging.stg_cms__refunds`) or `wordpressImport` rows leaking in.

- [ ] **Step 5: Commit** — `git add dbt && git commit -m "feat(dbt): core orders across both systems, dimensions, pinned-fact tests"`

---

### Task 12: GA4 sessions and session-to-order bridge

**Files:**
- Create: `dbt/models/core/core_sessions.sql`, `core_session_orders.sql`, `dbt/tests/core/assert_no_phantom_sessions.sql`, `assert_orders_counted_once.sql`; extend `dbt/models/core/schema.yml`

**Interfaces:**
- Consumes: `source('ga4','events')`, `channel_group` macro, `core_orders`.
- Produces: `core_sessions` (grain: session_key; incremental, partition by `session_date`, 3-day lookback; tag `hourly`) and `core_session_orders` (grain: order_key).

- [ ] **Step 1: `core_sessions.sql`**

```sql
{{ config(materialized='incremental', incremental_strategy='insert_overwrite', partition_by={'field': 'session_date', 'data_type': 'date'}, tags=['hourly']) }}
{% set lookback = 3 %}
with ev as (
  select
    user_pseudo_id,
    (select value.int_value from unnest(event_params) where key = 'ga_session_id') as ga_session_id,
    event_name, event_timestamp, parse_date('%Y%m%d', event_date) as event_date,
    (select value.string_value from unnest(event_params) where key = 'page_location') as page_location,
    (select value.string_value from unnest(event_params) where key = 'source') as ep_source,
    (select value.string_value from unnest(event_params) where key = 'medium') as ep_medium,
    (select value.string_value from unnest(event_params) where key = 'campaign') as ep_campaign,
    (select coalesce(value.int_value, safe_cast(value.string_value as int64)) from unnest(event_params) where key = 'session_engaged') as session_engaged,
    session_traffic_source_last_click.manual_campaign.source as lc_source,
    session_traffic_source_last_click.manual_campaign.medium as lc_medium,
    session_traffic_source_last_click.manual_campaign.campaign_name as lc_campaign,
    session_traffic_source_last_click.google_ads_campaign.campaign_id as lc_google_ads_campaign_id,
    collected_traffic_source.gclid as gclid,
    device.category as device_category, geo.country, geo.region, geo.city
  from {{ source('ga4', 'events') }}
  where regexp_contains(_table_suffix, r'^\d{8}$')
  {% if is_incremental() %}
    and _table_suffix >= format_date('%Y%m%d', date_sub(current_date(), interval {{ lookback }} day))
  {% else %}
    and _table_suffix >= format_date('%Y%m%d', date('{{ var("ga4_start_date") }}'))
  {% endif %}
),
sess as (
  select
    concat(user_pseudo_id, '.', cast(ga_session_id as string)) as session_key, user_pseudo_id,
    timestamp_micros(min(event_timestamp)) as session_start_at, min(event_date) as session_date,
    array_agg(page_location ignore nulls order by event_timestamp limit 1)[safe_offset(0)] as landing_page,
    coalesce(max(lc_source), array_agg(ep_source ignore nulls order by event_timestamp limit 1)[safe_offset(0)]) as raw_source,
    coalesce(max(lc_medium), array_agg(ep_medium ignore nulls order by event_timestamp limit 1)[safe_offset(0)]) as raw_medium,
    coalesce(max(lc_campaign), array_agg(ep_campaign ignore nulls order by event_timestamp limit 1)[safe_offset(0)]) as campaign,
    max(lc_google_ads_campaign_id) as google_ads_campaign_id,
    max(gclid) as gclid,
    max(session_engaged) = 1 as engaged,
    countif(event_name = 'page_view') as page_views,
    any_value(device_category) as device_category, any_value(country) as country, any_value(region) as region, any_value(city) as city
  from ev where ga_session_id is not null
  group by 1, 2
),
fixed as (
  -- phantom accounts.google.com referral: inherit the same user's previous non-phantom session within 30 minutes, else direct
  select s.*,
    raw_source = 'accounts.google.com' as is_phantom_referral,
    lag(raw_source) over (partition by user_pseudo_id order by session_start_at) as prev_source,
    lag(raw_medium) over (partition by user_pseudo_id order by session_start_at) as prev_medium,
    lag(campaign) over (partition by user_pseudo_id order by session_start_at) as prev_campaign,
    lag(session_start_at) over (partition by user_pseudo_id order by session_start_at) as prev_start
  from sess s
),
final as (
  select session_key, user_pseudo_id, session_start_at, session_date, landing_page,
    regexp_extract(landing_page, r'^https?://[^/]+(/[^?#]*)') as landing_page_path,
    regexp_extract(landing_page, r'[?&]q=([^&#]+)') as landing_query_q,
    case when is_phantom_referral and prev_source is not null and prev_source != 'accounts.google.com' and timestamp_diff(session_start_at, prev_start, minute) <= 30 then prev_source
         when is_phantom_referral then '(direct)' else coalesce(raw_source, '(direct)') end as source,
    case when is_phantom_referral and prev_source is not null and prev_source != 'accounts.google.com' and timestamp_diff(session_start_at, prev_start, minute) <= 30 then prev_medium
         when is_phantom_referral then '(none)' else coalesce(raw_medium, '(none)') end as medium,
    case when is_phantom_referral and timestamp_diff(session_start_at, prev_start, minute) <= 30 then prev_campaign else campaign end as campaign,
    google_ads_campaign_id, gclid, gclid is not null as has_gclid, engaged, page_views, device_category, country, region, city, is_phantom_referral,
    session_date < date('{{ var("launch_date") }}') as pre_launch
  from fixed
)
select *, {{ channel_group('source', 'medium', 'campaign', 'has_gclid') }} as default_channel_group from final
```

- [ ] **Step 2: `core_session_orders.sql`**

```sql
{{ config(tags=['hourly']) }}
with purchases as (
  select
    concat(user_pseudo_id, '.', cast((select value.int_value from unnest(event_params) where key = 'ga_session_id') as string)) as session_key,
    coalesce(ecommerce.transaction_id, (select value.string_value from unnest(event_params) where key = 'transaction_id')) as transaction_id,
    timestamp_micros(event_timestamp) as purchase_event_at
  from {{ source('ga4', 'events') }}
  where event_name = 'purchase' and regexp_contains(_table_suffix, r'^\d{8}$') and _table_suffix >= format_date('%Y%m%d', date('{{ var("ga4_start_date") }}'))
),
keyed as (
  select session_key, purchase_event_at, transaction_id,
    case when regexp_contains(transaction_id, r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') then lower(transaction_id)
         when regexp_contains(transaction_id, r'^\d+$') then concat('woo-', transaction_id) end as order_key
  from purchases where transaction_id is not null and transaction_id not in ('(not set)', '')
)
select order_key, session_key, purchase_event_at
from keyed where order_key is not null
qualify row_number() over (partition by order_key order by purchase_event_at) = 1   -- correction: purchase double-fire
```

- [ ] **Step 3: Tests**

`assert_no_phantom_sessions.sql`: `select session_key from {{ ref('core_sessions') }} where source = 'accounts.google.com'`.
`assert_orders_counted_once.sql`: `select order_key from {{ ref('core_session_orders') }} group by order_key having count(*) > 1`.
`schema.yml`: `unique`/`not_null` `core_sessions.session_key`, `core_session_orders.order_key`; `accepted_values` `default_channel_group: [Paid Search, Paid Social, Organic Social, Organic Search, Email, Direct, Referral, Other]`.

- [ ] **Step 4: Build** — `dbt build --select core_sessions core_session_orders` (first run scans the GA4 export from `ga4_start_date`; expect a few minutes). Then sanity query: `select session_date, count(*) sessions, countif(is_phantom_referral) phantoms from core.core_sessions where session_date >= '2026-09-01' group by 1 order by 1` — phantoms should be a few hundred per day and no session's `source` should be `accounts.google.com`.

- [ ] **Step 5: Commit** — `git add dbt && git commit -m "feat(dbt): GA4 sessions with phantom-referral fix and deduped session-order bridge"`

---

### Task 13: Ad spend, search, and Stripe core tables

**Files:**
- Create: `dbt/models/core/core_ad_spend.sql`, `core_search_daily.sql`, `core_stripe_transactions.sql`; extend `schema.yml`

- [ ] **Step 1: `core_ad_spend.sql`**

```sql
with google as (
  select s.segments_date as date, 'google' as platform, cast(s.campaign_id as string) as campaign_id, c.campaign_name,
    s.metrics_cost_micros / 1e6 as spend, s.metrics_impressions as impressions, s.metrics_clicks as clicks
  from {{ source('google_ads', 'campaign_stats') }} s
  join (select campaign_id, campaign_name from {{ source('google_ads', 'campaign') }} qualify row_number() over (partition by campaign_id order by segments_date desc) = 1) c using (campaign_id)
),
csv as (
  select date, platform, cast(null as string) as campaign_id, campaign_name, spend, impressions, clicks from {{ ref('stg_spend__csv') }}
),
unioned as (select * from google union all select * from csv)
select u.*, m.metro_slug, mk.metro_key
from unioned u
left join {{ ref('campaign_metro_map') }} m on u.campaign_name like concat(m.campaign_name_pattern, '%')
left join {{ ref('core_metros') }} mk on mk.slug = m.metro_slug
```

Column names in the transfer tables (`segments_date`, `metrics_cost_micros`, `metrics_clicks`, `metrics_impressions`, `campaign_id`, `campaign_name`) are the Google Ads transfer's documented names; confirm against `google_ads.INFORMATION_SCHEMA.COLUMNS` after the first transfer.

- [ ] **Step 2: `core_search_daily.sql`**

```sql
select property, date, regexp_extract(page, r'^https?://[^/]+(/[^?#]*)') as page_path, page, query, clicks, impressions, position
from {{ ref('stg_gsc__page_query') }}
```

- [ ] **Step 3: `core_stripe_transactions.sql`**

```sql
select txn_id, type, created_at, date(created_at, 'America/New_York') as business_date, amount, fee, net, currency, source_id, source_object, order_key, payment_intent_id, refund_id
from {{ ref('stg_stripe__balance_transactions') }}
```

- [ ] **Step 4: Tests** — `unique` on `core_stripe_transactions.txn_id`; `dbt_utils.unique_combination_of_columns` on `core_ad_spend (date, platform, campaign_name)` and `core_search_daily (property, date, page, query)`; `not_null` on `core_ad_spend.spend`.

- [ ] **Step 5: Build and commit** — `dbt build --select core_ad_spend core_search_daily core_stripe_transactions`; `git add dbt && git commit -m "feat(dbt): ad spend, search, stripe core tables"`

---

### Task 14: Phase-one marts

**Files:**
- Create: `dbt/models/marts/mart_daily_kpis.sql`, `mart_paid_performance.sql`, `mart_orders_reconciliation.sql`, `dbt/models/marts/schema.yml`, `dbt/tests/marts/assert_daily_kpis_carries_pre_launch.sql`, `assert_reconciliation_variance_recent.sql`

**Interfaces:**
- Produces: the three tables with the columns in spec §8. `mart_daily_kpis` and `mart_orders_reconciliation` carry tag `hourly`.

- [ ] **Step 1: `mart_daily_kpis.sql`**

```sql
{{ config(tags=['hourly']) }}
with s as (
  select session_date as business_date, pre_launch, default_channel_group as channel_group, cast(null as string) as metro_key,
    count(*) as sessions, countif(engaged) as engaged_sessions
  from {{ ref('core_sessions') }} group by 1, 2, 3, 4
),
o as (
  select o.business_date, o.pre_launch, coalesce(cs.default_channel_group, 'Unattributed') as channel_group,
    coalesce(e.metro_key, o.billing_metro_key) as metro_key,
    count(*) as orders, countif(o.order_type = 'ticket') as ticket_orders, sum(o.seats) as seats,
    sum(o.gross_revenue) as gross_revenue, sum(o.net_revenue) as net_revenue, countif(o.is_first_order) as new_customers
  from {{ ref('core_orders') }} o
  left join {{ ref('core_session_orders') }} so using (order_key)
  left join {{ ref('core_sessions') }} cs using (session_key)
  left join (select order_key, any_value(event_key) as event_key from {{ ref('core_order_items') }} where item_type = 'ticket' group by order_key) oi using (order_key)
  left join {{ ref('core_events') }} e using (event_key)
  group by 1, 2, 3, 4
),
grid as (
  select business_date, pre_launch, channel_group, metro_key from s
  union distinct
  select business_date, pre_launch, channel_group, metro_key from o
)
select g.business_date, g.pre_launch, g.channel_group, g.metro_key,
  coalesce(s.sessions, 0) as sessions, coalesce(s.engaged_sessions, 0) as engaged_sessions,
  coalesce(o.orders, 0) as orders, coalesce(o.ticket_orders, 0) as ticket_orders, coalesce(o.seats, 0) as seats,
  coalesce(o.gross_revenue, 0) as gross_revenue, coalesce(o.net_revenue, 0) as net_revenue,
  case when coalesce(s.sessions, 0) > 0 and g.metro_key is null and f.flag is null then o.ticket_orders / s.sessions end as cvr,
  safe_divide(o.net_revenue, o.orders) as aov, coalesce(o.new_customers, 0) as new_customers,
  f.flag is not null as unreliable_ga4
from grid g
left join s using (business_date, pre_launch, channel_group, metro_key)
left join o using (business_date, pre_launch, channel_group, metro_key)
left join {{ ref('date_flags') }} f on f.date = g.business_date and f.flag = 'unreliable_ga4'
```

Sessions carry no metro (GA4 geo city is not a metro), so `cvr` is only defined on rows where `metro_key is null`; metro rows still carry orders and revenue. This is stated in `schema.yml` descriptions.

- [ ] **Step 2: `mart_paid_performance.sql`**

```sql
with google_sessions as (
  -- gclid -> campaign via the Ads ClickStats table; fallback to GA4's linked campaign id
  select s.session_key, s.session_date, coalesce(cast(cs.campaign_id as string), s.google_ads_campaign_id) as campaign_id
  from {{ ref('core_sessions') }} s
  left join {{ source('google_ads', 'click_stats') }} cs on cs.click_view_gclid = s.gclid
  where s.gclid is not null or s.google_ads_campaign_id is not null
),
social_sessions as (
  select session_key, session_date, campaign as campaign_name, case when lower(source) like '%pinterest%' then 'pinterest' else 'meta' end as platform
  from {{ ref('core_sessions') }} where default_channel_group = 'Paid Social'
),
orders_by_session as (
  select so.session_key, o.business_date, count(*) as orders, sum(o.seats) as seats, sum(o.net_revenue) as net_revenue
  from {{ ref('core_session_orders') }} so join {{ ref('core_orders') }} o using (order_key) group by 1, 2
),
google_agg as (
  select gs.session_date as date, 'google' as platform, gs.campaign_id, count(*) as sessions, sum(coalesce(ob.orders, 0)) as orders, sum(coalesce(ob.seats, 0)) as seats, sum(coalesce(ob.net_revenue, 0)) as net_revenue
  from google_sessions gs left join orders_by_session ob using (session_key) group by 1, 2, 3
),
social_agg as (
  select ss.session_date as date, ss.platform, ss.campaign_name, count(*) as sessions, sum(coalesce(ob.orders, 0)) as orders, sum(coalesce(ob.seats, 0)) as seats, sum(coalesce(ob.net_revenue, 0)) as net_revenue
  from social_sessions ss left join orders_by_session ob using (session_key) group by 1, 2, 3
)
select sp.date, sp.platform, sp.campaign_id, sp.campaign_name, sp.metro_key, sp.spend, sp.impressions, sp.clicks,
  coalesce(g.sessions, so.sessions, 0) as sessions, coalesce(g.orders, so.orders, 0) as orders, coalesce(g.seats, so.seats, 0) as seats,
  coalesce(g.net_revenue, so.net_revenue, 0) as net_revenue,
  safe_divide(coalesce(g.net_revenue, so.net_revenue, 0), nullif(sp.spend, 0)) as roas,
  safe_divide(sp.spend, nullif(coalesce(g.orders, so.orders, 0), 0)) as cpa
from {{ ref('core_ad_spend') }} sp
left join google_agg g on sp.platform = 'google' and g.date = sp.date and g.campaign_id = sp.campaign_id
left join social_agg so on sp.platform in ('meta', 'pinterest') and so.date = sp.date and so.platform = sp.platform and so.campaign_name = sp.campaign_name
```

- [ ] **Step 3: `mart_orders_reconciliation.sql`**

```sql
{{ config(tags=['hourly']) }}
with cms as (
  select business_date, count(*) as cms_orders, sum(net_revenue) as cms_net_revenue
  from {{ ref('core_orders') }} where source_system = 'webapp' group by 1
),
stripe as (
  select business_date, countif(type = 'charge') as stripe_charges, sum(net) as stripe_net, sum(fee) as stripe_fees,
    sum(case when type = 'charge' then amount else 0 end) + sum(case when type in ('refund', 'payment_refund') then amount else 0 end) as stripe_gross_less_refunds
  from {{ ref('core_stripe_transactions') }} group by 1
)
select coalesce(c.business_date, s.business_date) as business_date,
  coalesce(c.cms_orders, 0) as cms_orders, coalesce(c.cms_net_revenue, 0) as cms_net_revenue,
  coalesce(s.stripe_charges, 0) as stripe_charges, coalesce(s.stripe_net, 0) as stripe_net, coalesce(s.stripe_fees, 0) as stripe_fees,
  coalesce(s.stripe_gross_less_refunds, 0) as stripe_gross_less_refunds,
  coalesce(c.cms_net_revenue, 0) - coalesce(s.stripe_gross_less_refunds, 0) as variance_amount,
  safe_divide(coalesce(c.cms_net_revenue, 0) - coalesce(s.stripe_gross_less_refunds, 0), nullif(s.stripe_gross_less_refunds, 0)) as variance_pct,
  abs(safe_divide(coalesce(c.cms_net_revenue, 0) - coalesce(s.stripe_gross_less_refunds, 0), nullif(s.stripe_gross_less_refunds, 0))) > 0.01 as flagged
from cms c full outer join stripe s using (business_date)
where coalesce(c.business_date, s.business_date) >= date('{{ var("launch_date") }}')
```

Stripe gift-card purchases and ad-hoc charges also land in Stripe; if the daily variance is consistently the gift-card amount, add `order_type` filtering on the CMS side to match what Stripe actually charged (CMS `total` already excludes gift-card-applied amounts, so the two should agree).

- [ ] **Step 4: Tests**

`schema.yml`: `dbt_utils.unique_combination_of_columns` on `mart_daily_kpis (business_date, pre_launch, channel_group, metro_key)`, `mart_paid_performance (date, platform, campaign_id, campaign_name)`, `unique` on `mart_orders_reconciliation.business_date`; `not_null` on every measure.

`assert_daily_kpis_carries_pre_launch.sql`: `select 1 from (select count(distinct pre_launch) n from {{ ref('mart_daily_kpis') }}) where n < 2` (fails until both eras are present, which Task 11 guarantees).

`assert_reconciliation_variance_recent.sql` (warn severity; success criterion 1): `{{ config(severity='warn') }} select business_date, variance_pct from {{ ref('mart_orders_reconciliation') }} where flagged and business_date >= date_sub(current_date('America/New_York'), interval 30 day) and business_date < current_date('America/New_York')`.

- [ ] **Step 5: Build everything** — `dbt build` from clean. Expected: all models and tests pass, reconciliation warnings listed if any. Then run the acceptance query for success criterion 3: `select source_system, order_type, count(*) orders, round(sum(gross_revenue)) gross from core.core_orders where business_date between '2025-06-23' and '2025-09-17' or business_date between '2026-06-23' and '2026-09-17' group by 1,2 order by 1,2` and record the result in `docs/phase1-acceptance.md`.

- [ ] **Step 6: Commit** — `git add dbt docs/phase1-acceptance.md && git commit -m "feat(dbt): phase-one marts and acceptance tests"`

---

### Task 15: Repoint the Slack brief at the warehouse

**Files (CMS repo, branch `feat/brief-from-warehouse` from `develop`):**
- Create: `scripts/google-ads/warehouse.py`, `scripts/google-ads/test_warehouse.py`
- Modify: `scripts/google-ads/ga_report.py` (the function that assembles the report's `y`, `wk`, `channels`, `landing`, and the daily series), `scripts/google-ads/requirements.txt` (add `google-cloud-bigquery`)

**Interfaces:**
- Consumes: `mart.daily_kpis`, `core.core_sessions`, `core.core_session_orders`, `core.core_orders`.
- Produces: `warehouse.py` functions returning exactly the shapes `ga_report.py` already consumes: `headline_dict(bq, start, end) -> {"sessions","users","purchases","revenue"}`, `channels(bq, start, end) -> {name: (sessions, purchases, revenue)}`, `landing(bq, start, end, limit=10) -> [(page, sessions, purchases)]`, `daily_series(bq, today, days=28) -> [(date, sessions, orders)]`. Selected by env `BRIEF_SOURCE=warehouse` (default stays `ga4` until verified).

- [ ] **Step 1: Read the existing entry point** — open `scripts/google-ads/ga_report.py` lines 80–159 and note the function that calls `ga.run(...)` to build `y = (cur, prev)`, `wk = (cur, prev)`, `channels`, `landing` (it is the function `build_text` is called from). Its name is used in Step 3.

- [ ] **Step 2: Write the failing test**

`scripts/google-ads/test_warehouse.py`:

```python
import datetime as dt
import warehouse


class FakeBq:
    def __init__(self, rows): self.rows, self.sql = rows, []
    def query(self, sql, job_config=None):
        self.sql.append(sql)
        rows = self.rows
        class _J:
            def result(_self): return rows
        return _J()


def test_headline_dict_shape():
    bq = FakeBq([{"sessions": 1200, "users": 900, "purchases": 31, "revenue": 2790.5}])
    d = warehouse.headline_dict(bq, dt.date(2026, 9, 24), dt.date(2026, 9, 24))
    assert d == {"sessions": 1200, "users": 900, "purchases": 31, "revenue": 2790.5}
    assert "mart.mart_daily_kpis" in bq.sql[0] and "metro_key is null" in bq.sql[0]


def test_daily_series_fills_missing_days():
    bq = FakeBq([{"d": dt.date(2026, 9, 24), "sessions": 5, "orders": 1}])
    s = warehouse.daily_series(bq, dt.date(2026, 9, 26), days=3)
    assert [(x[0].isoformat(), x[1], x[2]) for x in s] == [("2026-09-23", 0, 0), ("2026-09-24", 5, 1), ("2026-09-25", 0, 0)]
```

- [ ] **Step 3: Implement `warehouse.py`**

```python
"""Warehouse-backed data for the morning brief. Same shapes as the GA4 Data API path in ga_report.py."""
import datetime as dt
from google.cloud import bigquery

P = "sipandscript"


def _rows(bq, sql, **params):
    cfg = bigquery.QueryJobConfig(query_parameters=[bigquery.ScalarQueryParameter(k, "DATE" if isinstance(v, dt.date) else "INT64", v) for k, v in params.items()])
    return [dict(r) for r in bq.query(sql, job_config=cfg).result()]


def headline_dict(bq, start, end):
    r = _rows(bq, f"""
      select sum(sessions) sessions, sum(sessions) users, sum(ticket_orders) purchases, sum(net_revenue) revenue
      from `{P}.mart.mart_daily_kpis` where metro_key is null and business_date between @s and @e""", s=start, e=end)[0]
    return {k: (r[k] or 0) for k in ("sessions", "users", "purchases", "revenue")}


def channels(bq, start, end):
    rows = _rows(bq, f"""
      select channel_group, sum(sessions) sessions, sum(ticket_orders) purchases, sum(net_revenue) revenue
      from `{P}.mart.mart_daily_kpis` where metro_key is null and business_date between @s and @e group by 1""", s=start, e=end)
    return {r["channel_group"]: (r["sessions"] or 0, r["purchases"] or 0, r["revenue"] or 0) for r in rows}


def landing(bq, start, end, limit=10):
    rows = _rows(bq, f"""
      select s.landing_page_path page, count(*) sessions, count(distinct so.order_key) purchases
      from `{P}.core.core_sessions` s left join `{P}.core.core_session_orders` so using (session_key)
      where s.session_date between @s and @e group by 1 order by sessions desc limit @l""", s=start, e=end, l=limit)
    return [(r["page"], r["sessions"], r["purchases"]) for r in rows]


def daily_series(bq, today, days=28):
    end = today - dt.timedelta(days=1); start = end - dt.timedelta(days=days - 1)
    rows = {r["d"]: r for r in _rows(bq, f"""
      select business_date d, sum(sessions) sessions, sum(ticket_orders) orders
      from `{P}.mart.mart_daily_kpis` where metro_key is null and business_date between @s and @e group by 1""", s=start, e=end)}
    return [(start + dt.timedelta(days=i), rows.get(start + dt.timedelta(days=i), {}).get("sessions", 0) or 0, rows.get(start + dt.timedelta(days=i), {}).get("orders", 0) or 0) for i in range(days)]
```

The `users` metric is not modelled in phase one (GA4 users are cross-session); the brief shows sessions in its place, and the "Users" label in `headline_fields` should read "Sessions (users n/a)" when `BRIEF_SOURCE=warehouse`. Make that one-word change in `ga_report.py`.

- [ ] **Step 4: Wire the switch** — at the top of the function found in Step 1, add:

```python
if os.environ.get("BRIEF_SOURCE") == "warehouse":
    import warehouse
    from google.cloud import bigquery as _bq
    bq = _bq.Client(project="sipandscript")
    y_cur, y_prev = today - dt.timedelta(days=1), today - dt.timedelta(days=8)
    wk_end, wk_start, pwk_end, pwk_start = today - dt.timedelta(days=1), today - dt.timedelta(days=7), today - dt.timedelta(days=8), today - dt.timedelta(days=14)
    y = (warehouse.headline_dict(bq, y_cur, y_cur), warehouse.headline_dict(bq, y_prev, y_prev))
    wk = (warehouse.headline_dict(bq, wk_start, wk_end), warehouse.headline_dict(bq, pwk_start, pwk_end))
    channels = warehouse.channels(bq, wk_start, wk_end)
    landing = warehouse.landing(bq, wk_start, wk_end)
    series = warehouse.daily_series(bq, today)
    return y, wk, channels, landing, series          # match the tuple the GA4 path returns
```

Adjust the returned tuple to exactly what the existing function returns (read it; if it returns fewer items or a dict, mirror that).

- [ ] **Step 5: Test and verify** — `cd scripts/google-ads && python -m unittest test_warehouse`; then a local dry run `BRIEF_SOURCE=warehouse GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/sns-ads-builder-key.json python sync_radii.py --brief --dry-run` (add `--dry-run` printing instead of posting if the flag doesn't exist yet: one `if` around `slack_post`). Compare yesterday's orders and revenue with the Stripe dashboard; they should match within refunds.

- [ ] **Step 6: Deploy** — grant `ads-builder@` `roles/bigquery.dataViewer` on `mart` and `core` plus `roles/bigquery.jobUser` (add to `infra/setup.sh`), redeploy the job with `--set-env-vars BRIEF_SOURCE=warehouse` added to the existing deploy command in `docs/superpowers/specs/2026-09-25-google-ads-search-launch.md`, and move `sns-ga-report-daily` to 12:15 UTC only if `sns-analytics-daily` (11:00 UTC) has finished reliably under an hour for a week; otherwise set it to 12:45 UTC.

- [ ] **Step 7: Commit (CMS repo)** — `git add scripts/google-ads && git commit -m "feat(brief): read KPIs from the analytics warehouse"`; open the MR.

---

### Task 16: First full run, Looker Studio, enable schedules

**Files:**
- Create: `docs/runbook.md`, `docs/looker-studio.md`
- Modify: `README.md`

- [ ] **Step 1: Backfill in order** (each from the laptop with ADC, or as one-off job executions):

```bash
cd /Users/stephenchaloner/sns-analytics && . .venv/bin/activate
export CMS_BASE_URL=https://www.sipandscript.com CMS_EXPORT_TOKEN=... STRIPE_RESTRICTED_KEY=...
python -m loaders run --sources cms --full           # ~4k events, ~6k orders: a few minutes
python -m loaders run --sources stripe --full        # from 2026-06-19
python -m loaders run --sources gsc --full           # 480 days × 2 properties × 2 dimension sets: ~30-60 min
cd dbt && dbt build
```

Expected: every loader step `ok`, `dbt build` green except at most `warn`-severity reconciliation rows, which you then explain in `docs/phase1-acceptance.md`.

- [ ] **Step 2: Job dry run** — `gcloud run jobs execute sns-analytics --region us-east1 --wait` (Cloud Shell). Expected: exit 0 and a Slack line `sns-analytics daily OK — loaders rc=0, dbt rc=0`.

- [ ] **Step 3: Resume schedulers** — `gcloud scheduler jobs resume sns-analytics-daily --location us-east1 && gcloud scheduler jobs resume sns-analytics-hourly --location us-east1`. Watch two hourly runs and one daily run in `ops.run_log`.

- [ ] **Step 4: Looker Studio** — `docs/looker-studio.md` records: new report "Sip & Script — Website & Sales" on data sources `mart.mart_daily_kpis` and `mart.mart_paid_performance` (BigQuery connector, viewer's credentials off, owner's credentials on); page 1 "Overview": date control, scorecards Sessions / Ticket orders / Net revenue / CVR (filter `metro_key is null`), time series by `business_date`, table by `channel_group`; page 2 "Paid": table by `platform, campaign_name` with spend, orders, ROAS, CPA, plus a metro bar chart of spend vs orders; share link to the team. Paste the report URL into the doc.

- [ ] **Step 5: Runbook** — `docs/runbook.md`: how to rerun a source (`python -m loaders run --sources gsc`), reset a watermark (`delete from ops.load_state where source='gsc'`), rebuild a model (`dbt build --select core_orders+`), rotate a secret (add a version, redeploy not needed), read failures (`select * from ops.run_log where status='error' order by logged_at desc limit 20`), and the acceptance checks from spec §11.

- [ ] **Step 6: Commit and push** — `git add docs README.md && git commit -m "docs: runbook, Looker Studio setup, phase-one acceptance" && git push`.
