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
