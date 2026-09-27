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
