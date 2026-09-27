"""Summarise dbt's target/run_results.json for the run's single status message and ops.run_log (spec §10).

Pure: reads one file, never raises. A missing or unreadable file (dbt crashed before writing it, or never ran)
yields a summary whose `error` says so."""
from __future__ import annotations

import json
from dataclasses import dataclass, field

MAX_LISTED = 10
_FAILED = {"error", "fail", "runtime error"}


@dataclass(frozen=True)
class DbtSummary:
    models_ok: int = 0
    tests_ok: int = 0
    warned: int = 0
    failed_nodes: list[str] = field(default_factory=list)
    skipped: int = 0
    nodes: int = 0
    error: str | None = None     # set when run_results.json is missing or unreadable

    @property
    def ok(self) -> bool:
        return self.error is None and not self.failed_nodes

    def line(self) -> str:
        """One line for the Slack message: `dbt N models, M tests` plus warnings, skips and up to 10 failures."""
        if self.error:
            return f"dbt: no run results ({self.error})"
        text = f"dbt {self.models_ok} models, {self.tests_ok} tests"
        if self.warned:
            text += f", {self.warned} warn"
        if self.skipped:
            text += f", {self.skipped} skipped"
        if self.failed_nodes:
            shown = ", ".join(self.failed_nodes[:MAX_LISTED])
            more = f" (+{len(self.failed_nodes) - MAX_LISTED} more)" if len(self.failed_nodes) > MAX_LISTED else ""
            text += f"; {len(self.failed_nodes)} failed: {shown}{more}"
        return text


def _name(unique_id: str) -> str:
    """`model.sns_analytics.core_orders` -> `core_orders`; generic tests keep their name without the hash."""
    parts = unique_id.split(".")
    return ".".join(parts[2:3] if parts[0] == "test" else parts[2:]) or unique_id


def summarise_run_results(path) -> DbtSummary:
    try:
        with open(path, encoding="utf-8") as f:
            results = json.load(f)["results"]
    except FileNotFoundError:
        return DbtSummary(error=f"{path} not found")
    except (OSError, ValueError, KeyError, TypeError) as e:
        return DbtSummary(error=f"{path} unreadable: {type(e).__name__}")
    models_ok = tests_ok = warned = skipped = 0
    failed: list[str] = []
    for r in results if isinstance(results, list) else []:
        uid, status = str(r.get("unique_id", "?")), str(r.get("status", "")).lower()
        kind = uid.split(".", 1)[0]
        if status in _FAILED:
            failed.append(_name(uid))
        elif status == "warn":
            warned += 1
        elif status == "skipped":
            skipped += 1
        elif kind in ("model", "seed", "snapshot") and status == "success":
            models_ok += 1
        elif kind in ("test", "unit_test") and status == "pass":
            tests_ok += 1
    return DbtSummary(models_ok, tests_ok, warned, failed, skipped, nodes=len(results) if isinstance(results, list) else 0)
