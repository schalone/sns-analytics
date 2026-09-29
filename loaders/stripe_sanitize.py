"""Allowlist sanitiser for Stripe objects.

Stripe charges carry the customer's name, email, phone, address and card details, and the WooCommerce
gateway also copies name and email into metadata. None of that may be stored. This module builds the
stored payload from an allowlist: a field that is not listed here is dropped, so a field Stripe adds
tomorrow is dropped too. The email is used once, to compute `customer_hash`, and is never returned.
"""
from __future__ import annotations

import hashlib
import re
from typing import Any

ENTITY_KIND = {"balance_transactions": "balance_transaction", "refunds": "refund", "disputes": "dispute", "payouts": "payout"}

FIELDS: dict[str, tuple[str, ...]] = {
    "balance_transaction": ("id", "object", "type", "reporting_category", "created", "available_on", "amount", "fee", "net", "currency"),
    "charge": ("id", "object", "amount", "amount_captured", "amount_refunded", "created", "currency", "status", "paid", "refunded", "disputed"),
    "refund": ("id", "object", "amount", "created", "currency", "status", "reason"),
    "dispute": ("id", "object", "amount", "created", "currency", "status", "reason"),
    "payout": ("id", "object", "amount", "created", "arrival_date", "currency", "status", "type", "method"),
}
# Fields that hold another object's id. Stripe returns a string, or the whole object when expanded.
ID_FIELDS: dict[str, tuple[str, ...]] = {
    "charge": ("payment_intent",),
    "refund": ("charge", "payment_intent"),
    "dispute": ("charge", "payment_intent"),
}
# The WooCommerce `order_key` is not kept: nothing reads it, and with the order id it opened the order on the
# legacy site, so it is a credential.
METADATA_KEYS = ("CheckoutSessionKey", "OrderNumber", "EventKey", "TicketCount", "AdHocChargeGuid", "Type", "order_id")
EMAIL_METADATA_KEYS = ("customer_email", "Customer Email")
ORDER_REF = re.compile(r"Order #?(\d+)")


def customer_hash(email: str | None) -> str | None:
    """Lower-case hex SHA-256 of the trimmed, lower-cased email; None for blank. Same rule as the CMS export."""
    if not isinstance(email, str):
        return None
    normalised = email.strip().lower()
    if not normalised:
        return None
    return hashlib.sha256(normalised.encode("utf-8")).hexdigest()


def _as_id(value: Any) -> str | None:
    if isinstance(value, dict):
        value = value.get("id")
    return value if isinstance(value, str) else None


def _metadata(raw: Any) -> dict[str, str]:
    if not isinstance(raw, dict):
        return {}
    return {k: str(raw[k]) for k in METADATA_KEYS if raw.get(k) is not None and "@" not in str(raw[k])}


def _email(obj: dict) -> str | None:
    billing = obj.get("billing_details") if isinstance(obj.get("billing_details"), dict) else {}
    meta = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
    for candidate in (billing.get("email"), obj.get("receipt_email"), *(meta.get(k) for k in EMAIL_METADATA_KEYS)):
        if isinstance(candidate, str) and candidate.strip():
            return candidate
    return None


def _order_ref(description: Any) -> str | None:
    if not isinstance(description, str):
        return None
    match = ORDER_REF.search(description)
    return match.group(1) if match else None


def _clean(kind: str, obj: dict) -> dict:
    out: dict[str, Any] = {f: obj[f] for f in FIELDS[kind] if f in obj}
    for f in ID_FIELDS.get(kind, ()):
        if f in obj:
            out[f] = _as_id(obj[f])
    if kind in ("charge", "refund"):
        out["metadata"] = _metadata(obj.get("metadata"))
    if kind == "charge":
        out["order_ref"] = _order_ref(obj.get("description"))
        out["customer_hash"] = customer_hash(_email(obj))
    if kind == "balance_transaction":
        out["fee_details"] = [{"type": d.get("type"), "amount": d.get("amount")}
                              for d in (obj.get("fee_details") or []) if isinstance(d, dict)]
        out["source"] = _source(obj.get("source"))
    return out


def _source(source: Any) -> Any:
    if source is None or isinstance(source, str):
        return source
    if not isinstance(source, dict):
        return None
    kind = source.get("object")
    if kind in ("charge", "refund", "dispute", "payout"):
        return _clean(kind, source)
    return {"id": source.get("id"), "object": kind}


def sanitize(entity: str, obj: dict) -> dict:
    """Return the payload to store for one Stripe object of the given loader entity."""
    return _clean(ENTITY_KIND[entity], obj)
