"""Stripe: balance transactions (expanded source), refunds, disputes, payouts. Every object is sanitised before it is stored."""
from __future__ import annotations

import datetime as dt
from collections.abc import Mapping

from loaders.common.bq import RawRow, RawWriter
from loaders.common.config import RAW_STRIPE, Settings
from loaders.common.state import LoadState, StepResult, run_step
from loaders.stripe_sanitize import sanitize

STRIPE_ENTITIES = ("balance_transactions", "refunds", "disputes", "payouts")
RESOURCE = {"balance_transactions": "BalanceTransaction", "refunds": "Refund", "disputes": "Dispute", "payouts": "Payout"}
EXPAND = {"balance_transactions": ["data.source"]}
OVERLAP = dt.timedelta(days=1)
SOURCE = "stripe"


def _plain(value):
    """Recursively convert a Stripe SDK object (or any nested value) to plain JSON-ready Python.

    Real stripe-python StripeObjects are not Mapping/dict instances in this SDK version, so they
    are converted via their public `to_dict()` (which itself recurses), then walked again here to
    normalise any remaining Mapping/list wrapping. No private SDK method (`_to_dict_recursive`) is
    ever called.
    """
    if isinstance(value, Mapping):
        return {str(k): _plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    to_dict = getattr(value, "to_dict", None)
    if callable(to_dict):
        return _plain(to_dict())
    return value


def load_stripe(settings: Settings, writer: RawWriter, state: LoadState, full: bool = False, api=None) -> list[StepResult]:
    results: list[StepResult] = []
    for entity in STRIPE_ENTITIES:
        def step(entity=entity) -> int:
            if not settings.stripe_key:
                raise RuntimeError("STRIPE_RESTRICTED_KEY is not set")
            wm = None if full else state.get(SOURCE, entity)
            if not full and not wm:
                # Without a watermark an incremental run would page the whole account history. Refuse:
                # the history load is a deliberate one-off (`python -m loaders run --sources stripe --full`).
                raise RuntimeError(f"no Stripe watermark for {entity}: run once with --full to load history")
            sdk = api
            if sdk is None:
                import stripe as sdk  # type: ignore
                sdk.api_key = settings.stripe_key
            kw = {"limit": 100}
            if wm:   # --full has no watermark: page the whole account history
                kw["created"] = {"gte": int((wm.updated_at - OVERLAP).timestamp())}
            if entity in EXPAND:
                kw["expand"] = EXPAND[entity]
            resource = getattr(sdk, RESOURCE[entity])
            batch, total, newest = [], 0, None
            for obj in resource.list(**kw).auto_paging_iter():
                created = dt.datetime.fromtimestamp(int(obj["created"]), tz=dt.timezone.utc)
                batch.append(RawRow(obj["id"], created, sanitize(entity, _plain(obj))))
                newest = created if newest is None or created > newest else newest
                if len(batch) >= 5000:
                    total += writer.append(RAW_STRIPE, entity, batch); batch = []
            total += writer.append(RAW_STRIPE, entity, batch)
            if newest is not None:
                state.set(SOURCE, entity, newest)
            return total
        results.append(run_step(state, settings.run_id, f"{SOURCE}.{entity}", step))
    return results
