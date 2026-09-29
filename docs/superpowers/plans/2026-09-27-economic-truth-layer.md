# Economic Truth Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the warehouse able to reconstruct any Sip & Script event in either platform era: who, where, when, capacity, price, the booking curve, realized revenue, Stripe fees, the 60/40 split, allocated ad spend, S&S contribution and a comparison with peer events.

**Architecture:** The Stripe loader gains an allowlist sanitiser that hashes the billing email and drops all personal data before anything is written, and backfills the whole account history. dbt then matches every Stripe transaction to an order, resolves one `customer_hash` per order across both eras, and builds four new core tables (`core_bookings`, `core_event_daily`, `core_event_economics`, `core_customers`) plus `mart_event_performance`. `platform_era` replaces `pre_launch` everywhere.

**Tech Stack:** Python 3.12, `stripe` 15.x, pytest, ruff; dbt-core 1.12.5 + dbt-bigquery 1.12.1 (dbt unit tests and data tests), `dbt_utils`; BigQuery (US multi-region).

**Spec:** `docs/superpowers/specs/2026-09-27-economics-and-booking-curve-design.md` (the addendum). It extends `docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md` (the base spec). Executors read both. Where they disagree the addendum wins.

**Relationship to the base plan** (`docs/superpowers/plans/2026-09-26-analytics-pipeline.md`):

- Base tasks 1–9 are implemented and committed. Base tasks 10–14 (dbt staging, core, marts) are being built by another session at the time of writing.
- **Task 1 of this plan has no prerequisite and must be merged before any Stripe load runs against production**, which means before base task 16 ("first full run").
- **Tasks 2–10 of this plan require base tasks 10–14 to be committed.** Before starting Task 2, run `ls dbt/models/core/core_orders.sql dbt/models/marts/mart_daily_kpis.sql`. If either file is missing, stop and report; do not create them from this plan.
- Every "Modify" step names the expression to change rather than a line number, because the base files may differ slightly from the base plan text. Read the file first.
- The session building the base plan has agreed not to run the Stripe loader against production and not to touch `loaders/stripe_*.py` or `docs/`. It builds base tasks 11–14 to the base plan's names, including `pre_launch`; Tasks 3–5 here then amend them.

## Global Constraints

- GCP project `sipandscript`; datasets in the **US multi-region**. Existing `analytics_313669961` and `sipandscript_new_ds` are read-only.
- **No personal data at rest.** No email, name, phone, street address, card detail, or integer database id (`OrderId`, `CheckoutSessionId`) may be written to any dataset, log line, exception message, test fixture taken from production, or document. Customers are identified only by `customer_hash` = lower-case hex SHA-256 of the trimmed, lower-cased email.
- The Stripe key is read from the environment variable `STRIPE_RESTRICTED_KEY`. On Stephen's laptop it lives in `~/.config/sns-analytics/env` (mode 600). Never print it, echo it, or commit it. Load it with `set -a; . ~/.config/sns-analytics/env; set +a`.
- Economics, exact values: `sns_share_rate: 0.40`, `instructor_share_rate: 0.60`, `legacy_fee_rate: 0.029`, `legacy_fee_fixed: 0.30`, `materials_per_seat: 6.00`, `launch_date: "2026-06-19"`.
- Formulae: `realized_revenue = line value + allocated service fee − allocated discount`; `net_distributable = realized_revenue − refunded_amount − processing_fee`; `sns_share = 0.40 × net_distributable`; `instructor_share = 0.60 × net_distributable`; `sns_contribution = sns_share − allocated_ad_spend`. Materials are **never** subtracted from S&S figures.
- `platform_era` is `STRING NOT NULL` with exactly two values: `legacy_event_tickets`, `bronco`. The column `pre_launch` must not exist anywhere after Task 3.
- `fee_source` values: `actual`, `estimated`, `none`. `identity_source` values: `cms`, `stripe`, `cms_import`, `woo_propagated`, `woo_surrogate`, `unresolved`. `match_method` values: `checkout_session`, `order_number`, `woo_metadata`, `woo_description`, `adhoc`, `none`.
- Money in dollars as FLOAT64 from staging onward. Derived money columns in core are rounded to 6 decimal places with `round(x, 6)` so results are deterministic; tests compare within one cent.
- Business dates in `America/New_York`; timestamps UTC. Event dates are the event's local calendar date.
- dbt YAML in this repo uses the `data_tests:` key and nests test parameters under `arguments:` (see `dbt/models/staging/schema.yml`). Follow that form.
- All dbt commands run from `/Users/stephenchaloner/sns-analytics/dbt` with `../.venv/bin/dbt`. All Python commands run from the repo root with `.venv/bin/python` and `.venv/bin/pytest`.
- The `gcloud` and `bq` CLIs are broken on this machine. Do not use them. Ad hoc BigQuery queries go through dbt (`dbt show --inline "<sql>"`) or the Python client.
- Commit messages end with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- **Shared working tree.** Another session may be working in this checkout on the base plan. Stage files by explicit path only; never `git add -A`, `git add .` or `git add dbt`. Do not stage or revert a file this plan did not tell you to change. If `git status` shows unexpected changes in a file you need to edit, stop and report.
- When a step says to change a select list in a staging model, keep everything else in the file, including comments and any `qualify` or dedup clause the base work added.

## Review Focus

1. **A bronco order placed in the last few hours.** The CMS loads hourly and Stripe loads daily, so the order exists before its Stripe charge does. Expected: the booking carries `fee_source = 'estimated'` until Stripe arrives and the build does not fail. Test: Task 6 `assert_no_estimated_fee_on_settled_bronco.sql` only examines bookings older than two days.
2. **An order whose lines are all worth zero** (comp ticket, 100% promo; 163 legacy ticket lines are zero-value). Expected: no division by zero, no NaN, shares of 0, seats still counted. Test: Task 6 unit test `bookings_zero_value_order`.
3. **An event with null or zero capacity** (1,236 legacy ticket products). Expected: `pct_sold`, `utilisation` and the pace columns are null, `sold_out` is false, and the event is never reported as sold out. Test: Task 7 unit test `event_daily_no_capacity`, Task 8 unit test `event_economics_no_capacity`.
4. **A ticket bought after the event date** (142 legacy lines; late-recorded walk-ins). Expected: the sale is counted on the event date so the curve still closes on `seats_sold`. Test: Task 7 unit test `event_daily_late_sale_clamped`.
5. **A Stripe object that carries an email where none is expected**: an email inside an allowlisted metadata key, or a balance-transaction source of a type the sanitiser has never seen. Expected: the value or object is dropped, never passed through. Test: Task 1 `test_allowlisted_metadata_value_with_email_is_dropped`, `test_unknown_source_object_keeps_only_id_and_type`.

## File Structure

| File | Responsibility |
|---|---|
| `loaders/stripe_sanitize.py` (new) | Pure functions: `customer_hash`, `sanitize`. No I/O. The only place that ever sees an email. |
| `loaders/stripe_loader.py` (modify) | Calls `sanitize` on every object; full-history backfill. |
| `dbt/macros/platform_era.sql` (new) | The two era expressions. |
| `dbt/macros/season.sql` (new) | Month → season. |
| `dbt/models/staging/stripe/*.sql`, `dbt/models/staging/woo/*.sql` (modify, one new) | Expose the fields the sanitiser keeps and the archive columns the economics need. |
| `dbt/models/core/core_stripe_transactions.sql` (rewrite) | Every balance transaction with its resolved `order_key`. |
| `dbt/models/core/core_customer_identity.sql` (new) | One row per order → `customer_hash`. |
| `dbt/models/core/core_events.sql`, `core_venues.sql`, `core_instructors.sql` (rewrite) | CMS rows plus legacy-only rows. |
| `dbt/models/core/core_bookings.sql` (new) | Economics per ticket order item. |
| `dbt/models/core/core_ad_spend_allocation.sql` (new) | Spend split across events, with the unallocated remainder. |
| `dbt/models/core/core_event_daily.sql` (new) | The booking curve. |
| `dbt/models/core/core_event_economics.sql` (new) | One row per event with outcomes and pace. |
| `dbt/models/core/core_customers.sql` (new) | One row per customer. |
| `dbt/models/ops/ops_unallocated_ad_spend.sql` (new) | Spend no event could absorb. |
| `dbt/models/marts/mart_event_performance.sql` (new) | Event economics plus peer benchmarks. |
| `dbt/models/core/unit_tests.yml`, `dbt/models/marts/unit_tests.yml` (new) | dbt unit tests with hand-built inputs. |
| `dbt/tests/core/*.sql`, `dbt/tests/marts/*.sql` (new) | Data tests over real rows. |
| `docs/econ-001-validation.md` (new) | Hand-checked order and event, coverage numbers. |

---

### Task 1: Stripe sanitiser and full-history backfill

**Files:**
- Create: `loaders/stripe_sanitize.py`
- Create: `tests/test_stripe_sanitize.py`
- Modify: `loaders/stripe_loader.py`
- Modify: `tests/test_stripe.py`

**Interfaces:**
- Consumes: `RawRow(key: str, updated_at: datetime, payload: dict)` and `RawWriter.append(dataset, entity, rows)` from `loaders/common/bq.py`; `LoadState`, `StepResult`, `run_step` from `loaders/common/state.py`.
- Produces:
  - `loaders.stripe_sanitize.customer_hash(email: str | None) -> str | None`
  - `loaders.stripe_sanitize.sanitize(entity: str, obj: dict) -> dict` where `entity` is one of `balance_transactions`, `refunds`, `disputes`, `payouts`.
  - Stored payload shape for a balance transaction, which Task 2's staging SQL reads: top-level `id, object, type, reporting_category, created, available_on, amount, fee, net, currency, fee_details[{type, amount}], source`. `source` is either a string id or an object. A charge source has `id, object, amount, amount_captured, amount_refunded, created, currency, status, paid, refunded, disputed, payment_intent, metadata{...allowlisted keys}, order_ref, customer_hash`. A refund or dispute source has `id, object, amount, created, currency, status, reason, charge, payment_intent`.

- [ ] **Step 1: Write the failing sanitiser tests**

Create `tests/test_stripe_sanitize.py`:

```python
import json

from loaders.stripe_sanitize import customer_hash, sanitize

# Every one of these strings is planted in the fixture below and must never survive sanitising.
SENTINELS = [
    "jane@example.com", "Jane@Example.com", "Jane Q Public", "+16175550100", "12 Elm Street", "02108",
    "4242", "fp_secret", "pm_card_secret", "cus_secret", "sig_secret", "Calligraphy at The Pub", "receipts/secret",
    "99887", "55443",
]


def _charge(**over):
    charge = {
        "id": "ch_1", "object": "charge", "amount": 13600, "amount_captured": 13600, "amount_refunded": 0,
        "created": 1790336000, "currency": "usd", "status": "succeeded", "paid": True, "refunded": False,
        "disputed": False, "payment_intent": "pi_1",
        "description": "Sip & Script - Order 70123",
        "receipt_email": "jane@example.com", "receipt_url": "https://pay.stripe.com/receipts/secret",
        "customer": "cus_secret", "payment_method": "pm_card_secret",
        "billing_details": {"email": " Jane@Example.com ", "name": "Jane Q Public", "phone": "+16175550100",
                            "address": {"line1": "12 Elm Street", "postal_code": "02108"}},
        "payment_method_details": {"card": {"last4": "4242", "brand": "visa", "fingerprint": "fp_secret"}},
        "shipping": {"name": "Jane Q Public", "address": {"line1": "12 Elm Street"}},
        "metadata": {
            "customer_email": "jane@example.com", "customer_name": "Jane Q Public", "signature": "sig_secret",
            "order_id": "70123", "order_key": "wc_order_abc", "site_url": "https://sipandscript.com",
            "CheckoutSessionKey": "22222222-2222-2222-2222-222222222222", "OrderNumber": "SNS-26-000001",
            "EventKey": "77777777-7777-7777-7777-777777777777", "TicketCount": "2",
            "OrderId": "99887", "CheckoutSessionId": "55443",
            "EventName": "Calligraphy at The Pub", "Venue": "Calligraphy at The Pub", "Summary": "Calligraphy at The Pub",
        },
    }
    charge.update(over)
    return charge


def _txn(source):
    return {"id": "txn_1", "object": "balance_transaction", "type": "charge", "reporting_category": "charge",
            "created": 1790336000, "available_on": 1790500000, "amount": 13600, "fee": 425, "net": 13175, "currency": "usd",
            "description": "Jane Q Public", "fee_details": [{"type": "stripe_fee", "amount": 425, "description": "Stripe processing fees", "currency": "usd"}],
            "source": source}


def test_customer_hash_normalises_and_matches_cms_rule():
    # The CMS computes lower-case hex SHA-256 of the trimmed, lower-cased email. Fixed vector:
    # printf 'test@example.com' | shasum -a 256
    expected = "973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b"
    assert customer_hash("test@example.com") == expected
    assert customer_hash("  Test@Example.COM ") == expected


def test_customer_hash_is_none_for_blank():
    assert customer_hash(None) is None
    assert customer_hash("") is None
    assert customer_hash("   ") is None


def test_no_sentinel_survives_in_a_balance_transaction():
    out = json.dumps(sanitize("balance_transactions", _txn(_charge())))
    for s in SENTINELS:
        assert s not in out, f"leaked: {s}"
    assert "@" not in out


def test_charge_keeps_allowlisted_fields_and_derived_values():
    out = sanitize("balance_transactions", _txn(_charge()))
    assert out["fee"] == 425 and out["net"] == 13175 and out["type"] == "charge"
    assert out["fee_details"] == [{"type": "stripe_fee", "amount": 425}]
    src = out["source"]
    assert src["id"] == "ch_1" and src["object"] == "charge" and src["payment_intent"] == "pi_1"
    assert src["metadata"] == {
        "order_id": "70123", "order_key": "wc_order_abc",
        "CheckoutSessionKey": "22222222-2222-2222-2222-222222222222", "OrderNumber": "SNS-26-000001",
        "EventKey": "77777777-7777-7777-7777-777777777777", "TicketCount": "2",
    }
    assert src["order_ref"] == "70123"
    assert src["customer_hash"] == customer_hash("jane@example.com")
    assert "description" not in src and "billing_details" not in src and "receipt_email" not in src


def test_email_falls_back_through_all_four_sources():
    h = customer_hash("jane@example.com")
    blank = {"email": None}
    assert sanitize("balance_transactions", _txn(_charge()))["source"]["customer_hash"] == h
    c = _charge(billing_details=blank)
    assert sanitize("balance_transactions", _txn(c))["source"]["customer_hash"] == h          # receipt_email
    c = _charge(billing_details=blank, receipt_email=None)
    assert sanitize("balance_transactions", _txn(c))["source"]["customer_hash"] == h          # metadata customer_email
    c = _charge(billing_details=blank, receipt_email=None, metadata={"Customer Email": "JANE@example.com", "Customer Name": "Jane Q Public"})
    assert sanitize("balance_transactions", _txn(c))["source"]["customer_hash"] == h          # 2016-2018 metadata spelling
    c = _charge(billing_details=None, receipt_email=None, metadata={})
    assert sanitize("balance_transactions", _txn(c))["source"]["customer_hash"] is None


def test_order_ref_parsed_from_both_description_forms():
    assert sanitize("balance_transactions", _txn(_charge(description="Sip &amp; Script - Order 1234")))["source"]["order_ref"] == "1234"
    assert sanitize("balance_transactions", _txn(_charge(description="Sip & Script - Order #987")))["source"]["order_ref"] == "987"
    assert sanitize("balance_transactions", _txn(_charge(description="2 tickets | Modern Calligraphy")))["source"]["order_ref"] is None
    assert sanitize("balance_transactions", _txn(_charge(description=None)))["source"]["order_ref"] is None


def test_allowlisted_metadata_value_with_email_is_dropped():
    c = _charge(metadata={"order_id": "jane@example.com", "OrderNumber": "SNS-26-000001"})
    src = sanitize("balance_transactions", _txn(c))["source"]
    assert src["metadata"] == {"OrderNumber": "SNS-26-000001"}


def test_unknown_source_object_keeps_only_id_and_type():
    out = sanitize("balance_transactions", _txn({"id": "tr_1", "object": "transfer", "destination": "acct_x", "description": "jane@example.com"}))
    assert out["source"] == {"id": "tr_1", "object": "transfer"}


def test_unexpanded_source_string_is_kept():
    assert sanitize("balance_transactions", _txn("fee_123"))["source"] == "fee_123"
    assert sanitize("balance_transactions", _txn(None))["source"] is None


def test_refund_dispute_payout_allowlists():
    refund = {"id": "re_1", "object": "refund", "amount": 6800, "created": 1, "currency": "usd", "status": "succeeded",
              "reason": "requested_by_customer", "charge": "ch_1", "payment_intent": "pi_1", "receipt_number": "jane@example.com",
              "metadata": {"customer_email": "jane@example.com", "order_id": "70123"}}
    out = sanitize("refunds", refund)
    assert out == {"id": "re_1", "object": "refund", "amount": 6800, "created": 1, "currency": "usd", "status": "succeeded",
                   "reason": "requested_by_customer", "charge": "ch_1", "payment_intent": "pi_1", "metadata": {"order_id": "70123"}}

    dispute = {"id": "dp_1", "object": "dispute", "amount": 6800, "created": 1, "currency": "usd", "status": "lost", "reason": "fraudulent",
               "charge": {"id": "ch_1", "object": "charge", "receipt_email": "jane@example.com"}, "payment_intent": "pi_1",
               "evidence": {"customer_name": "Jane Q Public", "customer_email_address": "jane@example.com"}}
    out = sanitize("disputes", dispute)
    assert out["charge"] == "ch_1" and "evidence" not in out and "@" not in json.dumps(out)

    payout = {"id": "po_1", "object": "payout", "amount": 100, "created": 1, "arrival_date": 2, "currency": "usd", "status": "paid",
              "type": "bank_account", "method": "standard", "destination": "ba_secret", "statement_descriptor": "SIP SCRIPT"}
    assert sanitize("payouts", payout) == {"id": "po_1", "object": "payout", "amount": 100, "created": 1, "arrival_date": 2,
                                           "currency": "usd", "status": "paid", "type": "bank_account", "method": "standard"}


def test_refund_as_balance_transaction_source():
    refund = {"id": "re_1", "object": "refund", "amount": 6800, "created": 1, "currency": "usd", "status": "succeeded",
              "reason": None, "charge": "ch_1", "payment_intent": "pi_1", "metadata": {}}
    out = sanitize("balance_transactions", _txn(refund))
    assert out["source"]["object"] == "refund" and out["source"]["charge"] == "ch_1"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/pytest tests/test_stripe_sanitize.py -q`
Expected: collection error, `ModuleNotFoundError: No module named 'loaders.stripe_sanitize'`.

- [ ] **Step 3: Write the sanitiser**

Create `loaders/stripe_sanitize.py`:

```python
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
METADATA_KEYS = ("CheckoutSessionKey", "OrderNumber", "EventKey", "TicketCount", "AdHocChargeGuid", "Type", "order_id", "order_key")
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
```

- [ ] **Step 4: Run the sanitiser tests**

Run: `.venv/bin/pytest tests/test_stripe_sanitize.py -q`
Expected: `11 passed`.

- [ ] **Step 5: Update the loader tests to the new behaviour (they fail first)**

In `tests/test_stripe.py`:

1. Change the import line `from loaders.stripe_loader import BACKFILL_FROM, OVERLAP, load_stripe` to `from loaders.stripe_loader import OVERLAP, load_stripe`.
2. In `FakeStripe.__init__`, replace the `txn = stripe.BalanceTransaction.construct_from({...})` block with:

```python
        txn = stripe.BalanceTransaction.construct_from({
            "id": "txn_1", "object": "balance_transaction", "created": 1790336000, "type": "charge", "amount": 13600, "fee": 425, "net": 13175,
            "source": {"id": "ch_1", "object": "charge", "description": "Sip & Script - Order 70123",
                       "receipt_email": "jane@example.com", "billing_details": {"email": "jane@example.com", "name": "Jane Q Public"},
                       "metadata": {"CheckoutSessionKey": "22222222-2222-2222-2222-222222222222", "OrderId": "99887", "customer_name": "Jane Q Public"}},
        }, "sk_test_x")
```

3. Replace the whole function `test_full_backfill_starts_at_launch_and_expands_source` with:

```python
def test_full_backfill_has_no_created_filter_and_stores_sanitised_payload():
    bq = FakeBqClient(); api = FakeStripe()
    res = load_stripe(_settings(), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), full=True, api=api)
    assert [r.status for r in res] == ["ok"] * 4
    assert api.BalanceTransaction.calls[0] == {"limit": 100, "expand": ["data.source"]}
    assert api.Refund.calls[0] == {"limit": 100}
    dest, rows = [l for l in bq.loads if l[0].endswith("raw_stripe.balance_transactions")][0]
    assert rows[0]["key"] == "txn_1" and rows[0]["updated_at"] == "2026-09-25T11:33:20+00:00"
    raw = rows[0]["payload"]
    for leaked in ("jane@example.com", "Jane Q Public", "99887", "Order 70123"):
        assert leaked not in raw
    payload = json.loads(raw)
    assert payload["source"]["metadata"] == {"CheckoutSessionKey": "22222222-2222-2222-2222-222222222222"}
    assert payload["source"]["order_ref"] == "70123"
    assert len(payload["source"]["customer_hash"]) == 64


def test_first_incremental_run_without_watermark_loads_full_history():
    bq = FakeBqClient(); api = FakeStripe()
    load_stripe(_settings(), RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), api=api)
    assert "created" not in api.BalanceTransaction.calls[0]
```

Leave `test_incremental_uses_watermark_minus_overlap` and `test_missing_key_is_step_error` unchanged.

- [ ] **Step 6: Run the loader tests to verify they fail**

Run: `.venv/bin/pytest tests/test_stripe.py -q`
Expected: 2 failed, 2 passed. The two new tests FAIL on the `calls[0]` assertion because the loader still sends a `created` filter. `test_incremental_uses_watermark_minus_overlap` and `test_missing_key_is_step_error` pass.

- [ ] **Step 7: Change the loader**

In `loaders/stripe_loader.py`:

1. Replace the module docstring with `"""Stripe: balance transactions (expanded source), refunds, disputes, payouts. Every object is sanitised before it is stored."""`.
2. Add the import `from loaders.stripe_sanitize import sanitize` below the other `loaders` imports.
3. Delete the line that defines `BACKFILL_FROM`.
4. Replace these three lines:

```python
            start = (wm.updated_at - OVERLAP) if wm else BACKFILL_FROM
            kw = {"limit": 100, "created": {"gte": int(start.timestamp())}}
```

with:

```python
            kw = {"limit": 100}
            if wm:   # no watermark, or --full: page the whole account history
                kw["created"] = {"gte": int((wm.updated_at - OVERLAP).timestamp())}
```

5. Replace `batch.append(RawRow(obj["id"], created, _plain(obj)))` with `batch.append(RawRow(obj["id"], created, sanitize(entity, _plain(obj))))`.

- [ ] **Step 8: Run the whole Python suite and the linter**

Run: `.venv/bin/pytest -q && .venv/bin/ruff check loaders tests`
Expected: every test passes; ruff reports `All checks passed!`.

- [ ] **Step 9: Prove it against the live account without writing anything**

This reads 200 real balance transactions, sanitises them in memory, and prints only counts. It writes nothing to BigQuery.

```bash
set -a; . ~/.config/sns-analytics/env; set +a
.venv/bin/python - <<'PY'
import json, os, collections, stripe
from loaders.stripe_loader import _plain
from loaders.stripe_sanitize import sanitize
stripe.api_key = os.environ["STRIPE_RESTRICTED_KEY"]
n = at = hashed = charges = 0
keys = collections.Counter()
for i, obj in enumerate(stripe.BalanceTransaction.list(limit=100, expand=["data.source"]).auto_paging_iter()):
    if i >= 200: break
    out = sanitize("balance_transactions", _plain(obj)); n += 1
    at += "@" in json.dumps(out)
    src = out.get("source")
    if isinstance(src, dict) and src.get("object") == "charge":
        charges += 1; hashed += src.get("customer_hash") is not None; keys.update(src["metadata"].keys())
print("objects", n, "| payloads containing @:", at, "| charges", charges, "| charges with customer_hash", hashed)
print("metadata keys kept:", dict(keys))
PY
```

Expected: `payloads containing @: 0`; `charges with customer_hash` equal to `charges`; metadata keys are a subset of `CheckoutSessionKey, OrderNumber, EventKey, TicketCount, AdHocChargeGuid, Type`. If `payloads containing @` is not 0, stop: print the **names** of the fields containing it (never the values) and fix the allowlist before continuing.

- [ ] **Step 10: Commit**

```bash
git add loaders/stripe_sanitize.py loaders/stripe_loader.py tests/test_stripe_sanitize.py tests/test_stripe.py
git commit -m "feat(stripe): allowlist sanitiser, hashed customer id, full-history backfill

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: First Stripe load and staging models

**Prerequisite:** Task 1 is committed. Base tasks 10–14 are committed (`ls dbt/models/core/core_orders.sql dbt/models/marts/mart_daily_kpis.sql` lists both files).

**Files:**
- Modify: `dbt/dbt_project.yml`
- Rewrite: `dbt/models/staging/stripe/stg_stripe__balance_transactions.sql`
- Modify: `dbt/models/staging/woo/stg_woo__products.sql`, `stg_woo__order_line_items.sql`, `stg_woo__events.sql`, `stg_woo__venues.sql`
- Create: `dbt/models/staging/woo/stg_woo__organizers.sql`
- Modify: `dbt/models/staging/schema.yml`
- Create: `dbt/tests/staging/assert_no_email_in_raw_stripe.sql`, `dbt/tests/staging/assert_stripe_charges_carry_a_join_key.sql`

**Interfaces:**
- Consumes: the stored payload shape from Task 1.
- Produces these staging columns, which Tasks 4–6 rely on:
  - `stg_stripe__balance_transactions`: `txn_id, type, reporting_category, created_at, amount, fee, net, currency, source_id, source_object, charge_id, refund_id, payment_intent_id, checkout_session_key, order_number, woo_order_id, order_ref, adhoc_charge_key, customer_hash`
  - `stg_woo__products`: existing columns plus `woo_event_id STRING, ticket_capacity INT64, regular_price FLOAT64`
  - `stg_woo__order_line_items`: existing columns plus `subtotal FLOAT64`
  - `stg_woo__events`: existing columns plus `event_date DATE, event_timezone STRING`
  - `stg_woo__venues`: `latitude`, `longitude` become `safe_cast` (9 rows hold unparseable text)
  - `stg_woo__organizers`: `woo_organizer_id, name, status, location, start_date`
- Produces dbt variables `sns_share_rate, instructor_share_rate, legacy_fee_rate, legacy_fee_fixed, materials_per_seat` and the model folder config `ops`.

- [ ] **Step 1: Run the first production Stripe load**

This pages the whole account history (2016 onward), several hundred thousand objects. Expect 20 to 40 minutes.

```bash
set -a; . ~/.config/sns-analytics/env; set +a
CMS_BASE_URL=https://sipandscript.com .venv/bin/python -m loaders run --sources stripe --full
```

Expected final line: `sns-analytics loaders: stripe <a number above 200,000>` with no `⚠` lines. Exit code 0.

- [ ] **Step 2: Write the two staging data tests (they fail or error first)**

`dbt/tests/staging/assert_no_email_in_raw_stripe.sql` (addendum success criterion 4):

```sql
-- Any stored Stripe payload containing an @ means personal data reached the warehouse.
select 'balance_transactions' as entity, key from {{ source('raw_stripe', 'balance_transactions') }} where strpos(to_json_string(payload), '@') > 0
union all
select 'refunds', key from {{ source('raw_stripe', 'refunds') }} where strpos(to_json_string(payload), '@') > 0
union all
select 'disputes', key from {{ source('raw_stripe', 'disputes') }} where strpos(to_json_string(payload), '@') > 0
union all
select 'payouts', key from {{ source('raw_stripe', 'payouts') }} where strpos(to_json_string(payload), '@') > 0
```

`dbt/tests/staging/assert_stripe_charges_carry_a_join_key.sql`:

```sql
-- At least 97% of charge transactions per year must carry something an order can be matched on.
{{ config(severity='warn') }}
select extract(year from created_at) as yr, count(*) as charges,
  countif(coalesce(checkout_session_key, order_number, woo_order_id, order_ref, adhoc_charge_key) is null) as without_key
from {{ ref('stg_stripe__balance_transactions') }}
where type = 'charge'
group by 1
having safe_divide(countif(coalesce(checkout_session_key, order_number, woo_order_id, order_ref, adhoc_charge_key) is null), count(*)) > 0.03
```

Run: `cd dbt && ../.venv/bin/dbt test --select assert_no_email_in_raw_stripe assert_stripe_charges_carry_a_join_key`
Expected: `assert_no_email_in_raw_stripe` PASS (this is the real check of Task 1 against the full history; if it fails, stop, delete the four `raw_stripe` tables, fix the sanitiser, and reload). `assert_stripe_charges_carry_a_join_key` ERROR with `Unrecognized name: checkout_session_key`.

- [ ] **Step 3: Rewrite the Stripe staging view**

Replace the whole of `dbt/models/staging/stripe/stg_stripe__balance_transactions.sql` with:

```sql
-- Reads the sanitised payload written by loaders/stripe_sanitize.py. Metadata key names were
-- verified against live charges on 2026-09-27 (addendum spec §4.5): bronco charges carry
-- CheckoutSessionKey and OrderNumber, legacy charges carry order_id, 2016-2018 charges carry the
-- order number only in the description (stored as order_ref). There is no order GUID in Stripe.
with latest as ({{ latest_raw('raw_stripe', 'balance_transactions') }})
select
  key                                                                  as txn_id,
  json_value(payload, '$.type')                                        as type,
  json_value(payload, '$.reporting_category')                          as reporting_category,
  timestamp_seconds(cast(json_value(payload, '$.created') as int64))   as created_at,
  cast(json_value(payload, '$.amount') as int64) / 100                 as amount,
  cast(json_value(payload, '$.fee') as int64) / 100                    as fee,
  cast(json_value(payload, '$.net') as int64) / 100                    as net,
  json_value(payload, '$.currency')                                    as currency,
  coalesce(json_value(payload, '$.source.id'), json_value(payload, '$.source')) as source_id,
  json_value(payload, '$.source.object')                               as source_object,
  case json_value(payload, '$.source.object')
    when 'charge' then json_value(payload, '$.source.id')
    when 'refund' then json_value(payload, '$.source.charge')
    when 'dispute' then json_value(payload, '$.source.charge')
  end                                                                  as charge_id,
  if(json_value(payload, '$.source.object') = 'refund', json_value(payload, '$.source.id'), null) as refund_id,
  json_value(payload, '$.source.payment_intent')                       as payment_intent_id,
  lower(json_value(payload, '$.source.metadata.CheckoutSessionKey'))   as checkout_session_key,
  json_value(payload, '$.source.metadata.OrderNumber')                 as order_number,
  json_value(payload, '$.source.metadata.order_id')                    as woo_order_id,
  json_value(payload, '$.source.order_ref')                            as order_ref,
  lower(json_value(payload, '$.source.metadata.AdHocChargeGuid'))      as adhoc_charge_key,
  json_value(payload, '$.source.customer_hash')                        as customer_hash
from latest
```

- [ ] **Step 4: Extend the archive staging views**

In `dbt/models/staging/woo/stg_woo__products.sql`, keep the comment block and the `case` expression, and change the select list so it reads:

```sql
select cast(id as string) as woo_product_id, name, type, cast(venue_id as string) as woo_venue_id,
  cast(tribe_wooticket_for_event as string) as woo_event_id,
  cast(ticket_capacity as int64) as ticket_capacity,
  regular_price,
  case
    when tribe_wooticket_for_event is not null then 'ticket'
    when lower(name) like '%gift card%' or lower(name) like '%gift certificate%' then 'gift_card'
    else 'materials'
  end as product_kind
from {{ source('woo', 'products') }}
```

In `stg_woo__order_line_items.sql`, add `cast(subtotal as float64) as subtotal` to the end of the select list (before `from`). In the archive `subtotal` is the line value before discounts and `total` is after; `subtotal >= total` on every one of 125,984 rows (checked 2026-09-27).

In `stg_woo__events.sql`, add two columns to the end of the select list:

```sql
  date(event_start_date) as event_date,        -- event_start_date holds local wall-clock time; verified: it differs from event_utc_start_date by 4-8 hours
  nullif(event_timezone, '') as event_timezone
```

In `stg_woo__venues.sql`, `latitude` and `longitude` must use `safe_cast(... as float64)`. The base work already did this; change it only if the file still has a plain `cast`.

Create `dbt/models/staging/woo/stg_woo__organizers.sql`. The archive table has an `email` column; it must never be selected.

```sql
-- Instructors in the legacy system. The source table also holds an email column, deliberately not selected.
select cast(id as string) as woo_organizer_id, name, status, location, date(start_date) as start_date
from {{ source('woo', 'organizers') }}
```

- [ ] **Step 5: Add variables and the ops model folder**

In `dbt/dbt_project.yml`, add to `vars:` (keep the existing entries):

```yaml
  sns_share_rate: 0.40
  instructor_share_rate: 0.60
  legacy_fee_rate: 0.029          # used only when an order has no Stripe match; reset in Task 10
  legacy_fee_fixed: 0.30
  materials_per_seat: 6.00        # instructor-side estimate, informational only
  curve_days: 60                  # booking curve starts this many days before the event, or at first sale if earlier
  peer_window_days: 365
  peer_min_count: 5
```

and add one line under `models: sns_analytics:` beside `staging`, `core`, `marts`:

```yaml
    ops: {+materialized: table, +schema: ops}
```

- [ ] **Step 6: Add schema tests**

Append to the `models:` list in `dbt/models/staging/schema.yml`. If an entry for `stg_stripe__balance_transactions` already exists, replace it with this one.

```yaml
  - name: stg_stripe__balance_transactions
    columns:
      - name: txn_id
        data_tests: [unique, not_null]
      - name: type
        data_tests: [not_null]
      - name: customer_hash
        data_tests:
          - dbt_utils.expression_is_true:
              arguments:
                expression: "is null or regexp_contains(customer_hash, r'^[0-9a-f]{64}$')"

  - name: stg_woo__organizers
    columns:
      - name: woo_organizer_id
        data_tests: [unique, not_null]
```

- [ ] **Step 7: Build and test staging**

Run: `cd dbt && ../.venv/bin/dbt build --select staging`
Expected: all views built, all tests pass, `assert_stripe_charges_carry_a_join_key` passes or warns. If it warns, run this and record the output in the commit message body:

```bash
../.venv/bin/dbt show --limit 20 --inline "select extract(year from created_at) yr, count(*) charges, countif(checkout_session_key is not null) cs, countif(order_number is not null) ord_no, countif(woo_order_id is not null) woo_id, countif(order_ref is not null) ref, countif(adhoc_charge_key is not null) adhoc, countif(customer_hash is not null) hashed from {{ ref('stg_stripe__balance_transactions') }} where type = 'charge' group by 1 order by 1"
```

- [ ] **Step 8: Commit**

```bash
git add dbt/dbt_project.yml dbt/models/staging/schema.yml dbt/models/staging/stripe/stg_stripe__balance_transactions.sql dbt/models/staging/woo/stg_woo__products.sql dbt/models/staging/woo/stg_woo__order_line_items.sql dbt/models/staging/woo/stg_woo__events.sql dbt/models/staging/woo/stg_woo__venues.sql dbt/models/staging/woo/stg_woo__organizers.sql dbt/tests/staging/assert_no_email_in_raw_stripe.sql dbt/tests/staging/assert_stripe_charges_carry_a_join_key.sql
git commit -m "feat(dbt): stripe staging on sanitised payload; archive capacity, subtotal, organizers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `platform_era` replaces `pre_launch`

**Files:**
- Create: `dbt/macros/platform_era.sql`
- Modify: `dbt/models/core/core_orders.sql`, `dbt/models/core/core_sessions.sql`, `dbt/models/core/core_tickets.sql`, `dbt/models/core/core_refunds.sql`, `dbt/models/core/core_order_items.sql`
- Modify: `dbt/models/marts/mart_daily_kpis.sql`, `dbt/models/marts/mart_paid_performance.sql`, `dbt/models/marts/schema.yml`, `dbt/models/core/schema.yml`
- Delete: `dbt/tests/marts/assert_daily_kpis_carries_pre_launch.sql`
- Create: `dbt/tests/marts/assert_daily_kpis_carries_both_eras.sql`, `dbt/tests/assert_no_pre_launch_column.sql`

**Interfaces:**
- Produces: macros `platform_era_of_date(date_expr)` and `platform_era_of_source(source_system_expr)`; column `platform_era` on `core_orders`, `core_order_items`, `core_tickets`, `core_refunds`, `core_sessions`, `mart_daily_kpis`, `mart_paid_performance`. (`core_events` gets it in Task 5, `mart_orders_reconciliation` in Task 9.)

- [ ] **Step 1: Write the failing tests**

`dbt/tests/assert_no_pre_launch_column.sql`:

```sql
-- The column pre_launch was replaced by platform_era. It must not exist in any dataset dbt writes.
select table_schema, table_name, column_name
from `{{ target.project }}`.`region-us`.INFORMATION_SCHEMA.COLUMNS
where table_schema in ('core', 'mart', 'ops') and column_name = 'pre_launch'
```

`dbt/tests/marts/assert_daily_kpis_carries_both_eras.sql`:

```sql
select n from (select count(distinct platform_era) as n from {{ ref('mart_daily_kpis') }}) where n < 2
```

Delete the old test: `git rm dbt/tests/marts/assert_daily_kpis_carries_pre_launch.sql`.

Run: `cd dbt && ../.venv/bin/dbt test --select assert_no_pre_launch_column assert_daily_kpis_carries_both_eras`
Expected: `assert_no_pre_launch_column` FAIL (rows for `core_orders`, `core_sessions`, `mart_daily_kpis`); `assert_daily_kpis_carries_both_eras` ERROR `Unrecognized name: platform_era`.

- [ ] **Step 2: Add the macros**

`dbt/macros/platform_era.sql`:

```sql
{# Era in which something happened, from its date. The boundary is the last day the legacy archive received data. #}
{% macro platform_era_of_date(date_expr) -%}
case when {{ date_expr }} < date('{{ var("launch_date") }}') then 'legacy_event_tickets' else 'bronco' end
{%- endmacro %}

{# Era of a sale, from the system that recorded it. #}
{% macro platform_era_of_source(source_system_expr) -%}
case {{ source_system_expr }} when 'woocommerce' then 'legacy_event_tickets' else 'bronco' end
{%- endmacro %}
```

- [ ] **Step 3: Replace the expression in each model**

Find every use: `grep -rn "pre_launch" dbt/models dbt/tests`. Make these replacements.

| File | Replace | With |
|---|---|---|
| `core_orders.sql` | `business_date < date('{{ var("launch_date") }}') as pre_launch` | `{{ platform_era_of_source('source_system') }} as platform_era` |
| `core_sessions.sql` | `session_date < date('{{ var("launch_date") }}') as pre_launch` | `{{ platform_era_of_date('session_date') }} as platform_era` |
| `mart_daily_kpis.sql` | every `pre_launch` (in CTEs `s`, `o`, `grid`, the final select, and both `using (...)` lists) | `platform_era` |

Add the era to three models that lack it. In `core_tickets.sql` add `, o.platform_era` to the select list (the model already joins `core_orders o`). In `core_refunds.sql` change the `from` to `from {{ ref('stg_cms__refunds') }} r left join {{ ref('core_orders') }} o using (order_key)`, prefix the existing columns that exist on both sides (`order_key`, `status`, `created_at`, `updated_at`) with `r.`, and add `coalesce(o.platform_era, 'bronco') as platform_era`. In `core_order_items.sql` add `'bronco' as platform_era` to the first select and `'legacy_event_tickets' as platform_era` to the second (both as the last column).

In `mart_paid_performance.sql` add `{{ platform_era_of_date('sp.date') }} as platform_era` to the final select list.

In `dbt/models/marts/schema.yml` change the `unique_combination_of_columns` test on `mart_daily_kpis` to list `[business_date, platform_era, channel_group, metro_key]`.

In `dbt/models/core/schema.yml` and `dbt/models/marts/schema.yml`, add this column block under each of `core_orders`, `core_order_items`, `core_tickets`, `core_refunds`, `core_sessions`, `mart_daily_kpis`, `mart_paid_performance`:

```yaml
      - name: platform_era
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [legacy_event_tickets, bronco]
```

- [ ] **Step 4: Rebuild**

`core_sessions` is incremental, so a column change needs a full refresh. It rescans GA4 from `ga4_start_date` and takes a few minutes.

Run: `cd dbt && ../.venv/bin/dbt build --full-refresh --select core_orders+ core_sessions+`
Expected: all models and tests pass, including both tests from Step 1.

Run: `grep -rn "pre_launch" dbt/models dbt/tests dbt/macros`
Expected: the only match is the literal string inside `dbt/tests/assert_no_pre_launch_column.sql`.

- [ ] **Step 5: Commit**

```bash
git add dbt/macros/platform_era.sql dbt/models/core/core_orders.sql dbt/models/core/core_sessions.sql dbt/models/core/core_tickets.sql dbt/models/core/core_refunds.sql dbt/models/core/core_order_items.sql dbt/models/core/schema.yml dbt/models/marts/mart_daily_kpis.sql dbt/models/marts/mart_paid_performance.sql dbt/models/marts/schema.yml dbt/tests/assert_no_pre_launch_column.sql dbt/tests/marts/assert_daily_kpis_carries_both_eras.sql
git commit -m "feat(dbt): platform_era replaces pre_launch across core and marts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Stripe order matching and customer identity

**Files:**
- Rewrite: `dbt/models/core/core_stripe_transactions.sql`
- Create: `dbt/models/core/core_customer_identity.sql`
- Modify: `dbt/models/core/core_orders.sql`
- Create: `dbt/models/core/unit_tests.yml`
- Modify: `dbt/models/core/schema.yml`
- Create: `dbt/tests/core/assert_identity_coverage.sql`, `dbt/tests/core/assert_stripe_match_rate.sql`

**Interfaces:**
- Consumes: `stg_stripe__balance_transactions` (Task 2); `stg_cms__orders` columns `order_key, order_number, status, checkout_session_key, customer_hash, source, wordpress_order_id, updated_at`; `stg_woo__orders` columns `order_key, woo_order_id, woo_customer_id`; macro `platform_era_of_date` (Task 3).
- Produces:
  - `core_stripe_transactions`: `txn_id, type, reporting_category, created_at, business_date, amount, fee, net, currency, source_id, source_object, charge_id, refund_id, payment_intent_id, order_key, match_method, customer_hash, platform_era`. `order_key` is a CMS order GUID or `woo-<id>`; it is set on charge, refund and dispute transactions alike.
  - `core_customer_identity`: `order_key, source_system, customer_hash, identity_source`. One row per order in either system.
  - `core_orders` gains `identity_source`; its `customer_hash` now comes from `core_customer_identity`.

- [ ] **Step 1: Write the failing unit tests**

Create `dbt/models/core/unit_tests.yml`:

```yaml
unit_tests:
  - name: stripe_transactions_resolve_orders
    description: Each join key in priority order; refunds inherit the order of their charge; fee rows match nothing.
    model: core_stripe_transactions
    given:
      - input: ref('stg_cms__orders')
        rows:
          - {order_key: "aaaaaaaa-0000-0000-0000-000000000001", order_number: "SNS-26-000001", status: "Paid", checkout_session_key: "cccccccc-0000-0000-0000-000000000001", source: "webapp", updated_at: "2026-09-01 00:00:00"}
          - {order_key: "aaaaaaaa-0000-0000-0000-000000000002", order_number: "SNS-26-000002", status: "Paid", checkout_session_key: "cccccccc-0000-0000-0000-000000000002", source: "webapp", updated_at: "2026-09-01 00:00:00"}
          - {order_key: "aaaaaaaa-0000-0000-0000-000000000099", order_number: "SNS-26-000099", status: "Paid", checkout_session_key: "cccccccc-0000-0000-0000-000000000001", source: "wordpressImport", updated_at: "2026-09-02 00:00:00"}
      - input: ref('stg_stripe__balance_transactions')
        rows:
          - {txn_id: t1, type: charge, created_at: "2026-09-10 15:00:00", amount: 126, fee: 4, net: 122, source_object: charge, charge_id: ch_1, checkout_session_key: "cccccccc-0000-0000-0000-000000000001", order_number: "SNS-26-000001", customer_hash: h1}
          - {txn_id: t2, type: charge, created_at: "2026-09-10 15:00:00", amount: 50, fee: 2, net: 48, source_object: charge, charge_id: ch_2, order_number: "SNS-26-000002", customer_hash: h2}
          - {txn_id: t3, type: charge, created_at: "2024-05-01 15:00:00", amount: 50, fee: 2, net: 48, source_object: charge, charge_id: ch_3, woo_order_id: "70123", order_ref: "70123", customer_hash: h3}
          - {txn_id: t4, type: charge, created_at: "2017-05-01 15:00:00", amount: 50, fee: 2, net: 48, source_object: charge, charge_id: ch_4, order_ref: "1234", customer_hash: h4}
          - {txn_id: t5, type: charge, created_at: "2026-09-10 15:00:00", amount: 10, fee: 1, net: 9, source_object: charge, charge_id: ch_5, adhoc_charge_key: "dddddddd-0000-0000-0000-000000000001", customer_hash: h5}
          - {txn_id: t6, type: refund, created_at: "2026-09-12 15:00:00", amount: -126, fee: 0, net: -126, source_object: refund, charge_id: ch_1, refund_id: re_1}
          - {txn_id: t7, type: stripe_fee, created_at: "2026-09-12 15:00:00", amount: -5, fee: 0, net: -5, source_id: fee_1}
          - {txn_id: t8, type: charge, created_at: "2026-09-10 15:00:00", amount: 10, fee: 1, net: 9, source_object: charge, charge_id: ch_8, checkout_session_key: "cccccccc-0000-0000-0000-00000000ffff"}
    expect:
      rows:
        - {txn_id: t1, order_key: "aaaaaaaa-0000-0000-0000-000000000001", match_method: checkout_session, customer_hash: h1, platform_era: bronco}
        - {txn_id: t2, order_key: "aaaaaaaa-0000-0000-0000-000000000002", match_method: order_number, customer_hash: h2, platform_era: bronco}
        - {txn_id: t3, order_key: "woo-70123", match_method: woo_metadata, customer_hash: h3, platform_era: legacy_event_tickets}
        - {txn_id: t4, order_key: "woo-1234", match_method: woo_description, customer_hash: h4, platform_era: legacy_event_tickets}
        - {txn_id: t5, order_key: null, match_method: adhoc, customer_hash: h5, platform_era: bronco}
        - {txn_id: t6, order_key: "aaaaaaaa-0000-0000-0000-000000000001", match_method: checkout_session, customer_hash: h1, platform_era: bronco}
        - {txn_id: t7, order_key: null, match_method: none, customer_hash: null, platform_era: bronco}
        - {txn_id: t8, order_key: null, match_method: none, customer_hash: null, platform_era: bronco}

  - name: customer_identity_priority
    description: cms, then stripe, then cms_import, then propagation through the WooCommerce customer id, then surrogate, then unresolved.
    model: core_customer_identity
    given:
      - input: ref('stg_cms__orders')
        rows:
          - {order_key: "aaaaaaaa-0000-0000-0000-000000000001", source: "webapp", customer_hash: cms_hash}
          - {order_key: "aaaaaaaa-0000-0000-0000-000000000077", source: "wordpressImport", wordpress_order_id: "102", customer_hash: import_hash}
      - input: ref('stg_woo__orders')
        rows:
          - {order_key: "woo-101", woo_order_id: "101", woo_customer_id: "0"}
          - {order_key: "woo-102", woo_order_id: "102", woo_customer_id: "0"}
          - {order_key: "woo-103", woo_order_id: "103", woo_customer_id: "55"}
          - {order_key: "woo-104", woo_order_id: "104", woo_customer_id: "55"}
          - {order_key: "woo-105", woo_order_id: "105", woo_customer_id: "66"}
          - {order_key: "woo-106", woo_order_id: "106", woo_customer_id: "0"}
          - {order_key: "woo-107", woo_order_id: "107", woo_customer_id: null}
      - input: ref('core_stripe_transactions')
        rows:
          - {txn_id: t1, type: charge, source_object: charge, order_key: "aaaaaaaa-0000-0000-0000-000000000001", customer_hash: stripe_hash_ignored, created_at: "2026-09-01 00:00:00"}
          - {txn_id: t2, type: charge, source_object: charge, order_key: "woo-101", customer_hash: stripe_101, created_at: "2024-01-01 00:00:00"}
          - {txn_id: t3, type: charge, source_object: charge, order_key: "woo-103", customer_hash: stripe_55, created_at: "2024-01-01 00:00:00"}
    expect:
      rows:
        - {order_key: "aaaaaaaa-0000-0000-0000-000000000001", source_system: webapp, customer_hash: cms_hash, identity_source: cms}
        - {order_key: "woo-101", source_system: woocommerce, customer_hash: stripe_101, identity_source: stripe}
        - {order_key: "woo-102", source_system: woocommerce, customer_hash: import_hash, identity_source: cms_import}
        - {order_key: "woo-103", source_system: woocommerce, customer_hash: stripe_55, identity_source: stripe}
        - {order_key: "woo-104", source_system: woocommerce, customer_hash: stripe_55, identity_source: woo_propagated}
        - {order_key: "woo-105", source_system: woocommerce, customer_hash: "woo-cust-66", identity_source: woo_surrogate}
        - {order_key: "woo-106", source_system: woocommerce, customer_hash: null, identity_source: unresolved}
        - {order_key: "woo-107", source_system: woocommerce, customer_hash: null, identity_source: unresolved}
```

Run: `cd dbt && ../.venv/bin/dbt test --select "test_type:unit"`
Expected: `stripe_transactions_resolve_orders` FAIL or ERROR (the model has no `match_method` column); `customer_identity_priority` ERROR (model `core_customer_identity` not found).

- [ ] **Step 2: Rewrite `core_stripe_transactions.sql`**

```sql
{{ config(tags=['hourly']) }}
-- Every Stripe balance transaction with the order it belongs to. Stripe holds no order GUID
-- (verified 2026-09-27), so bronco charges match on the checkout session key, then the order number;
-- legacy charges match on the WooCommerce order id from metadata, then from the description.
-- Refunds and disputes inherit the order of their charge.
with t as (
  select * from {{ ref('stg_stripe__balance_transactions') }}
),
cms_by_session as (
  select checkout_session_key, order_key
  from {{ ref('stg_cms__orders') }}
  where source = 'webapp' and checkout_session_key is not null
  qualify row_number() over (partition by checkout_session_key
                             order by if(status in ('Paid', 'Partial Refund', 'Refunded'), 0, 1), updated_at desc) = 1
),
cms_by_number as (
  select order_number, order_key
  from {{ ref('stg_cms__orders') }}
  where source = 'webapp' and order_number is not null
  qualify row_number() over (partition by order_number order by updated_at desc) = 1
),
charge_match as (
  select t.charge_id,
    coalesce(s.order_key, n.order_key, concat('woo-', t.woo_order_id), concat('woo-', t.order_ref)) as order_key,
    case
      when s.order_key is not null then 'checkout_session'
      when n.order_key is not null then 'order_number'
      when t.woo_order_id is not null then 'woo_metadata'
      when t.order_ref is not null then 'woo_description'
      when t.adhoc_charge_key is not null then 'adhoc'
      else 'none'
    end as match_method,
    t.customer_hash
  from t
  left join cms_by_session s on s.checkout_session_key = t.checkout_session_key
  left join cms_by_number n on n.order_number = t.order_number
  where t.source_object = 'charge' and t.charge_id is not null
  qualify row_number() over (partition by t.charge_id order by t.created_at, t.txn_id) = 1
)
select t.txn_id, t.type, t.reporting_category, t.created_at, date(t.created_at, 'America/New_York') as business_date,
  t.amount, t.fee, t.net, t.currency, t.source_id, t.source_object, t.charge_id, t.refund_id, t.payment_intent_id,
  m.order_key, coalesce(m.match_method, 'none') as match_method, m.customer_hash,
  {{ platform_era_of_date("date(t.created_at, 'America/New_York')") }} as platform_era
from t
left join charge_match m on m.charge_id = t.charge_id
```

- [ ] **Step 3: Create `core_customer_identity.sql`**

```sql
{{ config(tags=['hourly']) }}
-- One row per order in either system, with the customer it belongs to. The legacy archive holds no
-- email and 36% of its orders are guest checkouts, so legacy identity comes from the hashed billing
-- email on the Stripe charge, then from the CMS's imported copy of the WordPress order.
with orders as (
  select order_key, 'webapp' as source_system, customer_hash as cms_hash, cast(null as string) as woo_customer_id
  from {{ ref('stg_cms__orders') }}
  where source = 'webapp'
  union all
  select order_key, 'woocommerce', cast(null as string), nullif(nullif(woo_customer_id, '0'), '')
  from {{ ref('stg_woo__orders') }}
),
stripe as (
  select order_key, array_agg(customer_hash order by created_at desc limit 1)[offset(0)] as stripe_hash
  from {{ ref('core_stripe_transactions') }}
  where source_object = 'charge' and order_key is not null and customer_hash is not null
  group by order_key
),
cms_import as (
  select concat('woo-', wordpress_order_id) as order_key, min(customer_hash) as import_hash
  from {{ ref('stg_cms__orders') }}
  where source = 'wordpressImport' and wordpress_order_id is not null and customer_hash is not null
  group by 1
),
direct as (
  select o.order_key, o.source_system, o.woo_customer_id,
    case when o.source_system = 'webapp' then o.cms_hash else coalesce(s.stripe_hash, i.import_hash) end as direct_hash,
    case
      when o.source_system = 'webapp' and o.cms_hash is not null then 'cms'
      when o.source_system = 'woocommerce' and s.stripe_hash is not null then 'stripe'
      when o.source_system = 'woocommerce' and i.import_hash is not null then 'cms_import'
    end as direct_source
  from orders o
  left join stripe s using (order_key)
  left join cms_import i using (order_key)
),
propagated as (
  -- a registered WooCommerce customer: reuse the hash most of their other orders resolved to
  select woo_customer_id, direct_hash as propagated_hash
  from direct
  where woo_customer_id is not null and direct_hash is not null
  group by woo_customer_id, direct_hash
  qualify row_number() over (partition by woo_customer_id order by count(*) desc, direct_hash) = 1
)
select d.order_key, d.source_system,
  coalesce(d.direct_hash, p.propagated_hash, concat('woo-cust-', d.woo_customer_id)) as customer_hash,
  case
    when d.direct_hash is not null then d.direct_source
    when p.propagated_hash is not null then 'woo_propagated'
    when d.woo_customer_id is not null then 'woo_surrogate'
    else 'unresolved'
  end as identity_source
from direct d
left join propagated p using (woo_customer_id)
```

- [ ] **Step 4: Run the unit tests**

Run: `cd dbt && ../.venv/bin/dbt build --select core_stripe_transactions core_customer_identity`
Expected: both unit tests PASS, both models built.

- [ ] **Step 5: Take `customer_hash` in `core_orders` from the bridge**

In `dbt/models/core/core_orders.sql`, replace the final `select` (the one that reads `from with_metro` and computes `net_revenue`, the era and `is_first_order`) with:

```sql
select w.* except (customer_hash),
  ci.customer_hash, coalesce(ci.identity_source, 'unresolved') as identity_source,
  w.gross_revenue - w.refunded_amount as net_revenue,
  {{ platform_era_of_source('w.source_system') }} as platform_era,
  ci.customer_hash is not null
    and row_number() over (partition by ci.customer_hash order by w.created_at, w.order_key) = 1 as is_first_order
from with_metro w
left join {{ ref('core_customer_identity') }} ci on ci.order_key = w.order_key
```

Leave the `cms` and `woo` CTEs as they are; the `customer_hash` they carry is discarded by `except`.

- [ ] **Step 6: Data tests**

`dbt/tests/core/assert_identity_coverage.sql` (addendum success criterion 3):

```sql
-- Warn when fewer than 98% of a year's orders resolve to a real customer hash, from 2019 onward.
{{ config(severity='warn') }}
select extract(year from business_date) as yr, platform_era, count(*) as orders,
  countif(identity_source in ('cms', 'stripe', 'cms_import', 'woo_propagated')) as resolved
from {{ ref('core_orders') }}
where business_date >= '2019-01-01'
group by 1, 2
having safe_divide(countif(identity_source in ('cms', 'stripe', 'cms_import', 'woo_propagated')), count(*)) < 0.98
```

`dbt/tests/core/assert_stripe_match_rate.sql`:

```sql
-- Warn when fewer than 98% of a year's paid orders (charged amount above zero, older than two days) have a Stripe charge.
{{ config(severity='warn') }}
with charged as (
  select distinct order_key from {{ ref('core_stripe_transactions') }} where source_object = 'charge' and order_key is not null
)
select extract(year from o.business_date) as yr, o.platform_era, count(*) as orders, countif(c.order_key is not null) as matched
from {{ ref('core_orders') }} o
left join charged c using (order_key)
where o.gross_revenue > 0 and o.business_date < date_sub(current_date('America/New_York'), interval 2 day)
group by 1, 2
having safe_divide(countif(c.order_key is not null), count(*)) < 0.98
```

Append to `dbt/models/core/schema.yml` under `models:`. If an entry for `core_stripe_transactions` already exists, replace it.

```yaml
  - name: core_stripe_transactions
    columns:
      - name: txn_id
        data_tests: [unique, not_null]
      - name: match_method
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [checkout_session, order_number, woo_metadata, woo_description, adhoc, none]

  - name: core_customer_identity
    columns:
      - name: order_key
        data_tests: [unique, not_null]
      - name: identity_source
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [cms, stripe, cms_import, woo_propagated, woo_surrogate, unresolved]
```

Under the existing `core_orders` entry add:

```yaml
      - name: identity_source
        data_tests: [not_null]
```

- [ ] **Step 7: Build and read the coverage**

Run: `cd dbt && ../.venv/bin/dbt build --select core_stripe_transactions+ `
Expected: every model and error-severity test passes. The base pinned-fact tests still pass (orders 5,275–5,381 and ticket revenue $469,359–$478,841 for 2026-06-23..09-17), which proves the identity join did not duplicate or drop orders.

Then print coverage and keep the output for Task 10:

```bash
../.venv/bin/dbt show --limit 40 --inline "select extract(year from business_date) yr, platform_era, identity_source, count(*) orders from {{ ref('core_orders') }} group by 1,2,3 order by 1,2,3"
../.venv/bin/dbt show --limit 40 --inline "select extract(year from created_at) yr, match_method, count(*) charges from {{ ref('core_stripe_transactions') }} where source_object = 'charge' group by 1,2 order by 1,2"
```

If bronco rows show `identity_source = 'unresolved'` or bronco charges show `match_method = 'none'` above 2%, the CMS export has not been loaded or lacks `checkoutSessionKey`; report it rather than loosening a test.

- [ ] **Step 8: Commit**

```bash
git add dbt/models/core/core_stripe_transactions.sql dbt/models/core/core_customer_identity.sql dbt/models/core/core_orders.sql dbt/models/core/unit_tests.yml dbt/models/core/schema.yml dbt/tests/core/assert_identity_coverage.sql dbt/tests/core/assert_stripe_match_rate.sql
git commit -m "feat(dbt): match Stripe transactions to orders; one customer hash per order across eras

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Legacy-only events, venues and instructors

**Files:**
- Rewrite: `dbt/models/core/core_venues.sql`, `dbt/models/core/core_instructors.sql`, `dbt/models/core/core_events.sql`
- Modify: `dbt/models/core/unit_tests.yml`, `dbt/models/core/schema.yml`
- Create: `dbt/tests/core/assert_wordpress_source_id_unique_on_events.sql`

**Interfaces:**
- Consumes: `stg_cms__events`, `stg_cms__venues`, `stg_cms__instructors`, `stg_cms__tickets`, `core_metros`; `stg_woo__products` (`woo_event_id, ticket_capacity, regular_price, product_kind, name`), `stg_woo__order_line_items` (`order_key, woo_product_id, quantity, subtotal`), `stg_woo__orders` (`order_key, status`), `stg_woo__events` (`woo_event_id, title, status, url, start_at, event_date, event_timezone, event_cost, woo_venue_id, woo_organizer_id`), `stg_woo__venues`, `stg_woo__organizers`.
- Produces:
  - `core_venues`: existing columns plus `venue_source` (`cms` | `woo_archive`). Legacy-only keys are `woo-venue-<id>`. `wordpress_source_id` is set on every row that has a legacy id.
  - `core_instructors`: existing columns plus `instructor_source`. Legacy-only keys are `woo-org-<id>`.
  - `core_events`: existing columns plus `time_zone, platform_era, event_source` (`cms` | `woo_archive`), `capacity_source` (`cms` | `woo_products` | `none`), `has_event_date BOOL`. Legacy-only keys are `woo-ev-<id>` and their `wordpress_source_id` is the legacy event id, so the existing join in `core_order_items` resolves them. `seats_sold` now counts both CMS tickets and legacy ticket lines.

- [ ] **Step 1: Write the failing unit test**

Append to the `unit_tests:` list in `dbt/models/core/unit_tests.yml`:

```yaml
  - name: events_union_legacy_and_capacity_fallback
    description: A CMS event imported from WordPress with no capacity borrows it from the archive; an event the CMS never imported appears as woo-ev-<id>; two ticket products sum.
    model: core_events
    given:
      - input: ref('stg_cms__events')
        rows:
          - {event_key: "eeeeeeee-0000-0000-0000-000000000001", title: "Bronco event", event_date: "2026-08-01", start_time: "18:00:00", end_time: "20:00:00", time_zone: "America/New_York", venue_key: v1, capacity: 20, ticket_price: 70, status: Published}
          - {event_key: "eeeeeeee-0000-0000-0000-000000000002", title: "Imported event", event_date: "2025-03-01", start_time: "18:00:00", end_time: "20:00:00", time_zone: "America/New_York", venue_key: v1, capacity: null, ticket_price: null, wordpress_source_id: "500", status: Published}
      - input: ref('stg_cms__tickets')
        rows:
          - {ticket_key: k1, event_key: "eeeeeeee-0000-0000-0000-000000000001", status: Paid}
          - {ticket_key: k2, event_key: "eeeeeeee-0000-0000-0000-000000000001", status: Refunded}
      - input: ref('core_venues')
        rows:
          - {venue_key: v1, metro_key: m1, wordpress_source_id: null}
          - {venue_key: "woo-venue-9", metro_key: m2, wordpress_source_id: "9"}
      - input: ref('core_instructors')
        rows:
          - {instructor_key: "woo-org-7", wordpress_source_id: "7"}
      - input: ref('stg_woo__events')
        rows:
          - {woo_event_id: "500", title: "Imported event (archive)", event_date: "2025-03-01", start_at: "2025-03-01 23:00:00", woo_venue_id: "9", woo_organizer_id: "7", event_cost: 60}
          - {woo_event_id: "600", title: "Legacy only", status: publish, event_date: "2024-05-04", start_at: "2024-05-04 22:00:00", woo_venue_id: "9", woo_organizer_id: "7", event_cost: 55}
      - input: ref('stg_woo__products')
        rows:
          - {woo_product_id: "p1", woo_event_id: "500", product_kind: ticket, ticket_capacity: 16, regular_price: 60, name: "Imported event"}
          - {woo_product_id: "p2", woo_event_id: "600", product_kind: ticket, ticket_capacity: 10, regular_price: 55, name: "Legacy only GA"}
          - {woo_product_id: "p3", woo_event_id: "600", product_kind: ticket, ticket_capacity: 4, regular_price: 75, name: "Legacy only VIP"}
          - {woo_product_id: "p4", woo_event_id: "700", product_kind: ticket, ticket_capacity: 0, regular_price: 40, name: "Old undated workshop"}
      - input: ref('stg_woo__orders')
        rows:
          - {order_key: "woo-1", status: completed}
          - {order_key: "woo-2", status: failed}
      - input: ref('stg_woo__order_line_items')
        rows:
          - {order_item_key: "woo-li-1", order_key: "woo-1", woo_product_id: "p2", quantity: 3, subtotal: 150}
          - {order_item_key: "woo-li-2", order_key: "woo-1", woo_product_id: "p1", quantity: 2, subtotal: 120}
          - {order_item_key: "woo-li-3", order_key: "woo-2", woo_product_id: "p2", quantity: 5, subtotal: 275}
    expect:
      rows:
        - {event_key: "eeeeeeee-0000-0000-0000-000000000001", event_source: cms, platform_era: bronco, capacity: 20, capacity_source: cms, ticket_price: 70, seats_sold: 1, seats_available: 19, metro_key: m1, has_event_date: true}
        - {event_key: "eeeeeeee-0000-0000-0000-000000000002", event_source: cms, platform_era: legacy_event_tickets, capacity: 16, capacity_source: woo_products, ticket_price: 60, seats_sold: 2, seats_available: 14, metro_key: m1, has_event_date: true}
        - {event_key: "woo-ev-600", event_source: woo_archive, platform_era: legacy_event_tickets, title: "Legacy only", capacity: 14, capacity_source: woo_products, ticket_price: 50, seats_sold: 3, seats_available: 11, venue_key: "woo-venue-9", metro_key: m2, instructor_key: "woo-org-7", wordpress_source_id: "600", has_event_date: true}
        - {event_key: "woo-ev-700", event_source: woo_archive, platform_era: legacy_event_tickets, title: "Old undated workshop", capacity: null, capacity_source: none, ticket_price: 40, seats_sold: 0, seats_available: null, wordpress_source_id: "700", has_event_date: false}
```

Run: `cd dbt && ../.venv/bin/dbt test --select events_union_legacy_and_capacity_fallback`
Expected: FAIL or ERROR (no `event_source` column; two rows where four are expected).

- [ ] **Step 2: Rewrite `core_venues.sql`**

```sql
with cms as (
  select venue_key, name, city, state, zip, latitude, longitude, metro_key as assigned_metro_key, capacity, time_zone,
    wordpress_source_id, updated_at, 'cms' as venue_source
  from {{ ref('stg_cms__venues') }}
),
legacy_only as (
  select concat('woo-venue-', w.woo_venue_id) as venue_key, w.name, w.city, w.state, w.zip, w.latitude, w.longitude,
    cast(null as string) as assigned_metro_key, cast(null as int64) as capacity, cast(null as string) as time_zone,
    w.woo_venue_id as wordpress_source_id, cast(null as timestamp) as updated_at, 'woo_archive' as venue_source
  from {{ ref('stg_woo__venues') }} w
  where w.woo_venue_id not in (select wordpress_source_id from {{ ref('stg_cms__venues') }} where wordpress_source_id is not null)
),
v as (
  select * from cms union all select * from legacy_only
),
nearest as (
  select v.venue_key, m.metro_key
  from v
  join {{ ref('core_metros') }} m
    on st_dwithin(safe.st_geogpoint(v.longitude, v.latitude), m.center_geog, m.radius_miles * 1609.344)
  where v.latitude is not null and v.longitude is not null
  qualify row_number() over (partition by v.venue_key
                             order by st_distance(safe.st_geogpoint(v.longitude, v.latitude), m.center_geog)) = 1
)
select v.venue_key, v.name, v.city, v.state, v.zip, v.latitude, v.longitude, v.assigned_metro_key, v.capacity, v.time_zone,
  v.wordpress_source_id, v.updated_at, v.venue_source,
  coalesce(v.assigned_metro_key, nearest.metro_key) as metro_key
from v
left join nearest using (venue_key)
```

- [ ] **Step 3: Rewrite `core_instructors.sql`**

```sql
select instructor_key, name, url_path, city, state, start_date, no_longer_teaches, wordpress_source_id, updated_at,
  'cms' as instructor_source
from {{ ref('stg_cms__instructors') }}
union all
select concat('woo-org-', o.woo_organizer_id), o.name, cast(null as string), o.location, cast(null as string),
  timestamp(o.start_date), cast(null as bool), o.woo_organizer_id, cast(null as timestamp),
  'woo_archive'
from {{ ref('stg_woo__organizers') }} o
where o.woo_organizer_id not in (select wordpress_source_id from {{ ref('stg_cms__instructors') }} where wordpress_source_id is not null)
```

- [ ] **Step 4: Rewrite `core_events.sql`**

```sql
-- One row per event in either era. CMS events come first; an event that exists only in the legacy
-- archive is built from its ticket products and keyed woo-ev-<id>. seats_sold here is a plain count
-- for convenience; core_event_economics (built from bookings) is the authoritative outcome table.
with woo_products as (
  select woo_event_id, nullif(sum(ticket_capacity), 0) as capacity, max(regular_price) as regular_price, min(name) as product_name
  from {{ ref('stg_woo__products') }}
  where product_kind = 'ticket' and woo_event_id is not null
  group by woo_event_id
),
woo_sales as (
  select p.woo_event_id, sum(li.quantity) as seats, safe_divide(sum(li.subtotal), sum(li.quantity)) as avg_list_price
  from {{ ref('stg_woo__order_line_items') }} li
  join {{ ref('stg_woo__products') }} p using (woo_product_id)
  join {{ ref('stg_woo__orders') }} o using (order_key)
  where p.product_kind = 'ticket' and p.woo_event_id is not null and o.status in ('completed', 'refunded')
  group by p.woo_event_id
),
woo_event as (
  select wp.woo_event_id, we.title, we.status, we.url, we.event_date, we.start_at, we.event_timezone, we.woo_venue_id, we.woo_organizer_id,
    wp.capacity, coalesce(ws.avg_list_price, wp.regular_price, we.event_cost) as ticket_price,
    wp.product_name, coalesce(ws.seats, 0) as seats
  from woo_products wp
  left join {{ ref('stg_woo__events') }} we using (woo_event_id)
  left join woo_sales ws using (woo_event_id)
),
venue_by_legacy_id as (
  select wordpress_source_id, venue_key, metro_key from {{ ref('core_venues') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(venue_key like 'woo-venue-%', 1, 0), venue_key) = 1
),
instructor_by_legacy_id as (
  select wordpress_source_id, instructor_key from {{ ref('core_instructors') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(instructor_key like 'woo-org-%', 1, 0), instructor_key) = 1
),
cms_sold as (
  select event_key, countif(status in ('Paid', 'Used')) as seats
  from {{ ref('stg_cms__tickets') }}
  group by event_key
),
cms_rows as (
  select e.event_key, e.title, e.url_path, e.event_date,
    timestamp(datetime(e.event_date, coalesce(safe.parse_time('%H:%M:%S', e.start_time), time '00:00:00')), coalesce(e.time_zone, 'America/New_York')) as start_at,
    timestamp(datetime(e.event_date, coalesce(safe.parse_time('%H:%M:%S', e.end_time), time '00:00:00')), coalesce(e.time_zone, 'America/New_York')) as end_at,
    coalesce(e.time_zone, 'America/New_York') as time_zone,
    e.venue_key, coalesce(e.metro_key, v.metro_key) as metro_key, e.instructor_key, e.category, e.event_type, e.theme, e.status,
    coalesce(nullif(e.capacity, 0), w.capacity) as capacity,
    coalesce(e.ticket_price, w.ticket_price) as ticket_price,
    e.is_virtual, e.no_tickets, e.external_ticket_url, e.wordpress_source_id, e.updated_at,
    coalesce(s.seats, 0) + coalesce(w.seats, 0) as seats_sold,
    'cms' as event_source,
    case when nullif(e.capacity, 0) is not null then 'cms' when w.capacity is not null then 'woo_products' else 'none' end as capacity_source
  from {{ ref('stg_cms__events') }} e
  left join {{ ref('core_venues') }} v using (venue_key)
  left join cms_sold s using (event_key)
  left join woo_event w on w.woo_event_id = e.wordpress_source_id
),
legacy_rows as (
  select concat('woo-ev-', w.woo_event_id) as event_key, coalesce(w.title, w.product_name) as title, w.url as url_path, w.event_date,
    w.start_at, cast(null as timestamp) as end_at,
    coalesce(w.event_timezone, 'America/New_York') as time_zone,
    v.venue_key, v.metro_key, i.instructor_key,
    cast(null as string) as category, cast(null as string) as event_type, cast(null as string) as theme, w.status,
    w.capacity, w.ticket_price,
    cast(null as bool) as is_virtual, cast(null as bool) as no_tickets, cast(null as string) as external_ticket_url,
    w.woo_event_id as wordpress_source_id, cast(null as timestamp) as updated_at,
    w.seats as seats_sold,
    'woo_archive' as event_source,
    case when w.capacity is not null then 'woo_products' else 'none' end as capacity_source
  from woo_event w
  left join venue_by_legacy_id v on v.wordpress_source_id = w.woo_venue_id
  left join instructor_by_legacy_id i on i.wordpress_source_id = w.woo_organizer_id
  where w.woo_event_id not in (select wordpress_source_id from {{ ref('stg_cms__events') }} where wordpress_source_id is not null)
),
unioned as (
  select * from cms_rows union all select * from legacy_rows
)
select u.*,
  greatest(u.capacity - u.seats_sold, 0) as seats_available,
  u.event_date is not null as has_event_date,
  case when u.event_date is null and u.event_source = 'woo_archive' then 'legacy_event_tickets'
       else {{ platform_era_of_date('u.event_date') }} end as platform_era
from unioned u
```

- [ ] **Step 5: Tests**

`dbt/tests/core/assert_wordpress_source_id_unique_on_events.sql`:

```sql
-- Legacy ticket lines find their event through wordpress_source_id; a duplicate would double-count them.
{{ config(severity='warn') }}
select wordpress_source_id, count(*) as events
from {{ ref('core_events') }}
where wordpress_source_id is not null
group by 1
having count(*) > 1
```

In `dbt/models/core/schema.yml`, under `core_events` add the `platform_era` column block from Task 3 Step 3 and:

```yaml
      - name: event_source
        data_tests:
          - accepted_values:
              arguments:
                values: [cms, woo_archive]
      - name: capacity_source
        data_tests:
          - accepted_values:
              arguments:
                values: [cms, woo_products, none]
      - name: seats_sold
        description: "Plain count of CMS tickets (Paid, Used) plus legacy ticket lines on completed or refunded orders. Use core_event_economics for analysis."
```

- [ ] **Step 6: Build**

Run: `cd dbt && ../.venv/bin/dbt build --select core_venues+ core_instructors+`
Expected: the unit test passes; every downstream model and error-severity test passes; base pinned-fact tests still pass.

Then check coverage and keep the output for Task 10:

```bash
../.venv/bin/dbt show --limit 40 --inline "select extract(year from event_date) yr, platform_era, event_source, count(*) events, countif(capacity is not null) with_capacity, countif(venue_key is not null) with_venue, countif(metro_key is not null) with_metro, countif(instructor_key is not null) with_instructor from {{ ref('core_events') }} group by 1,2,3 order by 1,2,3"
```

- [ ] **Step 7: Commit**

```bash
git add dbt/models/core/core_venues.sql dbt/models/core/core_instructors.sql dbt/models/core/core_events.sql dbt/models/core/unit_tests.yml dbt/models/core/schema.yml dbt/tests/core/assert_wordpress_source_id_unique_on_events.sql
git commit -m "feat(dbt): legacy-only events, venues and instructors; capacity fallback to archive

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Order item economics and `core_bookings`

**Files:**
- Create: `dbt/models/core/core_order_item_economics.sql`, `dbt/models/core/core_bookings.sql`
- Modify: `dbt/models/core/unit_tests.yml`, `dbt/models/core/schema.yml`
- Create: `dbt/tests/core/assert_shares_sum_to_net.sql`, `assert_allocation_conserves_money.sql`, `assert_no_estimated_fee_on_settled_bronco.sql`, `assert_fee_actual_coverage.sql`

**Interfaces:**
- Consumes: `stg_cms__orders` (`order_key, status, source, created_at, paid_at, discount, service_fee, total`), `stg_cms__order_items` (`order_item_key, order_key, item_type, ticket_key, event_key, quantity, line_total`), `stg_cms__refunds` (`order_key, amount, status`), `stg_cms__tickets` (`ticket_key, status`), `stg_woo__orders` (`order_key, status, created_at, paid_at, total`), `stg_woo__order_line_items` (`order_item_key, order_key, woo_product_id, quantity, line_total, subtotal`), `stg_woo__products` (`woo_product_id, woo_event_id, product_kind`), `core_stripe_transactions` (Task 4), `core_events` (Task 5), `core_customer_identity` (Task 4); variables `sns_share_rate, instructor_share_rate, legacy_fee_rate, legacy_fee_fixed, launch_date`.
- Produces:
  - `core_order_item_economics`, grain one order item of any type: `order_item_key, order_key, source_system, platform_era, item_kind` (`ticket` | `gift_card` | `other`), `event_key, purchased_at, purchase_date, seats, list_value, discount, service_fee, realized_revenue, refunded_amount, processing_fee, fee_source, net_distributable, sns_share, instructor_share, is_cancelled`.
  - `core_bookings`, grain one **ticket** order item: `booking_key` (= `order_item_key`), `order_key, event_key, customer_hash, identity_source, source_system, platform_era, purchased_at, purchase_date, sale_date, days_before_event, seats, net_seats, list_value, discount, service_fee, realized_revenue, refunded_amount, processing_fee, fee_source, net_distributable, sns_share, instructor_share, is_cancelled`. `sale_date = least(purchase_date, event_date)`; `net_seats = 0` when `is_cancelled`, else `seats`.

- [ ] **Step 1: Write the failing unit tests**

Append to `dbt/models/core/unit_tests.yml`:

```yaml
  - name: order_item_economics_bronco_split
    description: Order-level discount, service fee and Stripe fee are split across items by line value; 60/40 applies after the fee.
    model: core_order_item_economics
    given:
      - input: ref('stg_cms__orders')
        rows:
          - {order_key: A, source: webapp, status: Paid, created_at: "2026-09-10 14:00:00", paid_at: "2026-09-10 14:01:00", subtotal: 130, discount: 10, service_fee: 6, total: 126}
      - input: ref('stg_cms__order_items')
        rows:
          - {order_item_key: A1, order_key: A, item_type: ticket, ticket_key: T1, event_key: E1, quantity: 1, line_total: 65}
          - {order_item_key: A2, order_key: A, item_type: ticket, ticket_key: T2, event_key: E1, quantity: 1, line_total: 65}
      - input: ref('stg_cms__refunds')
        rows: []
      - input: ref('stg_cms__tickets')
        rows:
          - {ticket_key: T1, status: Paid}
          - {ticket_key: T2, status: Used}
      - input: ref('core_stripe_transactions')
        rows:
          - {txn_id: t1, type: charge, source_object: charge, order_key: A, amount: 126, fee: 4, net: 122}
      - input: ref('stg_woo__orders')
        rows: []
      - input: ref('stg_woo__order_line_items')
        rows: []
      - input: ref('stg_woo__products')
        rows: []
      - input: ref('core_events')
        rows: []
    expect:
      rows:
        - {order_item_key: A1, source_system: webapp, platform_era: bronco, item_kind: ticket, event_key: E1, purchase_date: "2026-09-10", seats: 1, list_value: 65, discount: 5, service_fee: 3, realized_revenue: 63, refunded_amount: 0, processing_fee: 2, fee_source: actual, net_distributable: 61, sns_share: 24.4, instructor_share: 36.6, is_cancelled: false}
        - {order_item_key: A2, source_system: webapp, platform_era: bronco, item_kind: ticket, event_key: E1, purchase_date: "2026-09-10", seats: 1, list_value: 65, discount: 5, service_fee: 3, realized_revenue: 63, refunded_amount: 0, processing_fee: 2, fee_source: actual, net_distributable: 61, sns_share: 24.4, instructor_share: 36.6, is_cancelled: false}

  - name: order_item_economics_zero_value_order
    description: Review focus 2. A comp order worth nothing must not divide by zero; the seat still counts; there is no card payment so no fee.
    model: core_order_item_economics
    given:
      - input: ref('stg_cms__orders')
        rows:
          - {order_key: Z, source: webapp, status: Paid, created_at: "2026-09-10 14:00:00", paid_at: null, subtotal: 0, discount: 0, service_fee: 0, total: 0}
      - input: ref('stg_cms__order_items')
        rows:
          - {order_item_key: Z1, order_key: Z, item_type: ticket, ticket_key: T9, event_key: E1, quantity: 1, line_total: 0}
          - {order_item_key: Z2, order_key: Z, item_type: ticket, ticket_key: T8, event_key: E1, quantity: 1, line_total: 0}
      - input: ref('stg_cms__refunds')
        rows: []
      - input: ref('stg_cms__tickets')
        rows: []
      - input: ref('core_stripe_transactions')
        rows: []
      - input: ref('stg_woo__orders')
        rows: []
      - input: ref('stg_woo__order_line_items')
        rows: []
      - input: ref('stg_woo__products')
        rows: []
      - input: ref('core_events')
        rows: []
    expect:
      rows:
        - {order_item_key: Z1, seats: 1, realized_revenue: 0, refunded_amount: 0, processing_fee: 0, fee_source: none, net_distributable: 0, sns_share: 0, instructor_share: 0, is_cancelled: false}
        - {order_item_key: Z2, seats: 1, realized_revenue: 0, refunded_amount: 0, processing_fee: 0, fee_source: none, net_distributable: 0, sns_share: 0, instructor_share: 0, is_cancelled: false}

  - name: order_item_economics_legacy
    description: Legacy line totals are already net of discount. An unmatched order gets an estimated fee. A refunded order keeps the Stripe fee as a loss, split 60/40. A partly refunded bronco order cancels only the refunded ticket.
    model: core_order_item_economics
    given:
      - input: ref('stg_cms__orders')
        rows:
          - {order_key: P, source: webapp, status: "Partial Refund", created_at: "2026-09-10 14:00:00", paid_at: "2026-09-10 14:01:00", subtotal: 100, discount: 0, service_fee: 0, total: 100}
          - {order_key: X, source: wordpressImport, status: Paid, created_at: "2024-05-01 14:00:00", paid_at: "2024-05-01 14:01:00", subtotal: 50, discount: 0, service_fee: 0, total: 50}
          - {order_key: D, source: webapp, status: Pending, created_at: "2026-09-10 14:00:00", paid_at: null, subtotal: 50, discount: 0, service_fee: 0, total: 50}
      - input: ref('stg_cms__order_items')
        rows:
          - {order_item_key: P1, order_key: P, item_type: ticket, ticket_key: TP1, event_key: E1, quantity: 1, line_total: 50}
          - {order_item_key: P2, order_key: P, item_type: ticket, ticket_key: TP2, event_key: E1, quantity: 1, line_total: 50}
          - {order_item_key: X1, order_key: X, item_type: ticket, ticket_key: TX1, event_key: E1, quantity: 1, line_total: 50}
          - {order_item_key: D1, order_key: D, item_type: ticket, ticket_key: TD1, event_key: E1, quantity: 1, line_total: 50}
      - input: ref('stg_cms__refunds')
        rows:
          - {refund_key: R1, order_key: P, amount: 50, status: Completed}
          - {refund_key: R2, order_key: P, amount: 50, status: Failed}
      - input: ref('stg_cms__tickets')
        rows:
          - {ticket_key: TP1, status: Refunded}
          - {ticket_key: TP2, status: Paid}
      - input: ref('core_stripe_transactions')
        rows:
          - {txn_id: t1, type: charge, source_object: charge, order_key: P, amount: 100, fee: 3.2, net: 96.8}
          - {txn_id: t2, type: refund, source_object: refund, order_key: P, amount: -50, fee: 0, net: -50}
          - {txn_id: t3, type: charge, source_object: charge, order_key: "woo-2", amount: 40, fee: 1.46, net: 38.54}
          - {txn_id: t4, type: refund, source_object: refund, order_key: "woo-2", amount: -40, fee: 0, net: -40}
      - input: ref('stg_woo__orders')
        rows:
          - {order_key: "woo-1", status: completed, created_at: "2024-05-01 14:00:00", paid_at: "2024-05-01 14:00:30", total: 50}
          - {order_key: "woo-2", status: refunded, created_at: "2024-05-02 14:00:00", paid_at: "2024-05-02 14:00:30", total: 40}
          - {order_key: "woo-3", status: refunded, created_at: "2018-05-02 14:00:00", paid_at: null, total: 30}
          - {order_key: "woo-4", status: failed, created_at: "2024-05-02 14:00:00", paid_at: null, total: 30}
      - input: ref('stg_woo__order_line_items')
        rows:
          - {order_item_key: "woo-li-1", order_key: "woo-1", woo_product_id: p1, quantity: 2, subtotal: 60, line_total: 50}
          - {order_item_key: "woo-li-2", order_key: "woo-2", woo_product_id: p1, quantity: 1, subtotal: 40, line_total: 40}
          - {order_item_key: "woo-li-3", order_key: "woo-3", woo_product_id: p1, quantity: 1, subtotal: 30, line_total: 30}
          - {order_item_key: "woo-li-4", order_key: "woo-4", woo_product_id: p1, quantity: 1, subtotal: 30, line_total: 30}
      - input: ref('stg_woo__products')
        rows:
          - {woo_product_id: p1, woo_event_id: "600", product_kind: ticket}
      - input: ref('core_events')
        rows:
          - {event_key: "woo-ev-600", wordpress_source_id: "600", event_source: woo_archive}
    expect:
      rows:
        - {order_item_key: P1, platform_era: bronco, seats: 1, realized_revenue: 50, refunded_amount: 25, processing_fee: 1.6, fee_source: actual, net_distributable: 23.4, sns_share: 9.36, instructor_share: 14.04, is_cancelled: true}
        - {order_item_key: P2, platform_era: bronco, seats: 1, realized_revenue: 50, refunded_amount: 25, processing_fee: 1.6, fee_source: actual, net_distributable: 23.4, sns_share: 9.36, instructor_share: 14.04, is_cancelled: false}
        - {order_item_key: "woo-li-1", source_system: woocommerce, platform_era: legacy_event_tickets, item_kind: ticket, event_key: "woo-ev-600", seats: 2, list_value: 60, discount: 10, service_fee: 0, realized_revenue: 50, refunded_amount: 0, processing_fee: 1.75, fee_source: estimated, net_distributable: 48.25, sns_share: 19.3, instructor_share: 28.95, is_cancelled: false}
        - {order_item_key: "woo-li-2", source_system: woocommerce, platform_era: legacy_event_tickets, item_kind: ticket, event_key: "woo-ev-600", seats: 1, list_value: 40, discount: 0, service_fee: 0, realized_revenue: 40, refunded_amount: 40, processing_fee: 1.46, fee_source: actual, net_distributable: -1.46, sns_share: -0.584, instructor_share: -0.876, is_cancelled: true}
        - {order_item_key: "woo-li-3", source_system: woocommerce, platform_era: legacy_event_tickets, seats: 1, realized_revenue: 30, refunded_amount: 30, processing_fee: 1.17, fee_source: estimated, net_distributable: -1.17, sns_share: -0.468, instructor_share: -0.702, is_cancelled: true}
```

Notes on what this test pins: the imported WordPress order `X`, the pending order `D` and the failed order `woo-4` produce no rows. `R2` (a failed refund) is ignored. `woo-3` has no Stripe match, so its refund comes from the order status and its fee is estimated: `30 × 0.029 + 0.30 = 1.17`.

Run: `cd dbt && ../.venv/bin/dbt test --select "test_type:unit,core_order_item_economics"`
Expected: ERROR, model `core_order_item_economics` not found.

- [ ] **Step 2: Create `core_order_item_economics.sql`**

```sql
{{ config(tags=['hourly']) }}
-- Economics per order item, for every item type, in both eras. Order-level amounts (discount,
-- service fee, refund, Stripe fee) are split across the order's items in proportion to line value.
-- core_bookings keeps the ticket rows; the conservation test runs here, where all items are present.
with event_by_legacy_id as (
  select wordpress_source_id as woo_event_id, event_key
  from {{ ref('core_events') }}
  where wordpress_source_id is not null
  qualify row_number() over (partition by wordpress_source_id order by if(event_source = 'cms', 0, 1), event_key) = 1
),
stripe as (
  select order_key,
    sum(fee) as fee,
    -sum(if(type in ('refund', 'payment_refund'), amount, 0)) as refunded,
    countif(source_object = 'charge') > 0 as has_charge
  from {{ ref('core_stripe_transactions') }}
  where order_key is not null
  group by order_key
),
cms_refunds as (
  select order_key, sum(amount) as refunded
  from {{ ref('stg_cms__refunds') }}
  where status in ('Completed', 'Succeeded', 'succeeded')
  group by order_key
),
bronco as (
  select i.order_item_key, i.order_key, 'webapp' as source_system,
    case i.item_type when 'ticket' then 'ticket' when 'giftCard' then 'gift_card' else 'other' end as item_kind,
    i.event_key,
    coalesce(o.paid_at, o.created_at) as purchased_at,
    coalesce(i.quantity, 1) as seats,
    coalesce(i.line_total, 0) as list_value,
    coalesce(i.line_total, 0) as weight_base,
    cast(null as float64) as line_discount,           -- bronco discount is order-level; allocated below
    coalesce(o.discount, 0) as order_discount,
    coalesce(o.service_fee, 0) as order_service_fee,
    coalesce(r.refunded, 0) as order_refunded,
    coalesce(o.total, 0) > 0 as card_paid,
    coalesce(t.status = 'Refunded', false) as ticket_refunded
  from {{ ref('stg_cms__order_items') }} i
  join {{ ref('stg_cms__orders') }} o using (order_key)
  left join cms_refunds r using (order_key)
  left join {{ ref('stg_cms__tickets') }} t using (ticket_key)
  where o.source = 'webapp' and o.status in ('Paid', 'Partial Refund', 'Refunded')
),
legacy as (
  select li.order_item_key, li.order_key, 'woocommerce' as source_system,
    coalesce(p.product_kind, 'other') as item_kind_raw,
    m.event_key,
    coalesce(o.paid_at, o.created_at) as purchased_at,
    coalesce(li.quantity, 1) as seats,
    coalesce(li.subtotal, li.line_total, 0) as list_value,
    coalesce(li.line_total, 0) as weight_base,
    greatest(coalesce(li.subtotal, li.line_total, 0) - coalesce(li.line_total, 0), 0) as line_discount,
    0.0 as order_discount,
    0.0 as order_service_fee,
    case when coalesce(s.refunded, 0) > 0 then s.refunded when o.status = 'refunded' then coalesce(o.total, 0) else 0 end as order_refunded,
    coalesce(o.total, 0) > 0 as card_paid,
    false as ticket_refunded
  from {{ ref('stg_woo__order_line_items') }} li
  join {{ ref('stg_woo__orders') }} o using (order_key)
  left join {{ ref('stg_woo__products') }} p using (woo_product_id)
  left join event_by_legacy_id m on m.woo_event_id = p.woo_event_id
  left join stripe s using (order_key)
  where o.status in ('completed', 'refunded')
    and o.created_at < timestamp('{{ var("launch_date") }}', 'America/New_York')
),
items as (
  select order_item_key, order_key, source_system, item_kind, event_key, purchased_at, seats, list_value, weight_base,
    line_discount, order_discount, order_service_fee, order_refunded, card_paid, ticket_refunded
  from bronco
  union all
  select order_item_key, order_key, source_system,
    case item_kind_raw when 'ticket' then 'ticket' when 'gift_card' then 'gift_card' else 'other' end,
    event_key, purchased_at, seats, list_value, weight_base,
    line_discount, order_discount, order_service_fee, order_refunded, card_paid, ticket_refunded
  from legacy
),
weighted as (
  select *,
    case when sum(weight_base) over (partition by order_key) > 0
         then weight_base / sum(weight_base) over (partition by order_key)
         else 1 / count(*) over (partition by order_key) end as w
  from items
),
revenue as (
  select *,
    coalesce(line_discount, order_discount * w) as discount,
    order_service_fee * w as service_fee,
    list_value - coalesce(line_discount, order_discount * w) + order_service_fee * w as realized_revenue,
    order_refunded * w as refunded_amount
  from weighted
),
fees as (
  select r.*,
    case
      when coalesce(s.has_charge, false) then s.fee * r.w
      when r.card_paid then (sum(r.realized_revenue) over (partition by r.order_key) * {{ var('legacy_fee_rate') }} + {{ var('legacy_fee_fixed') }}) * r.w
      else 0
    end as processing_fee,
    case when coalesce(s.has_charge, false) then 'actual' when r.card_paid then 'estimated' else 'none' end as fee_source
  from revenue r
  left join stripe s using (order_key)
)
select order_item_key, order_key, source_system,
  {{ platform_era_of_source('source_system') }} as platform_era,
  item_kind, event_key, purchased_at, date(purchased_at, 'America/New_York') as purchase_date, seats,
  round(list_value, 6) as list_value,
  round(discount, 6) as discount,
  round(service_fee, 6) as service_fee,
  round(realized_revenue, 6) as realized_revenue,
  round(refunded_amount, 6) as refunded_amount,
  round(processing_fee, 6) as processing_fee,
  fee_source,
  round(realized_revenue - refunded_amount - processing_fee, 6) as net_distributable,
  round({{ var('sns_share_rate') }} * (realized_revenue - refunded_amount - processing_fee), 6) as sns_share,
  round({{ var('instructor_share_rate') }} * (realized_revenue - refunded_amount - processing_fee), 6) as instructor_share,
  ticket_refunded or (realized_revenue > 0 and refunded_amount >= realized_revenue - 0.005) as is_cancelled
from fees
```

- [ ] **Step 3: Run the unit tests**

Run: `cd dbt && ../.venv/bin/dbt build --select core_order_item_economics`
Expected: three unit tests PASS; model built.

- [ ] **Step 4: Write the failing `core_bookings` unit test**

Append to `dbt/models/core/unit_tests.yml`:

```yaml
  - name: bookings_are_ticket_items_with_event_timing
    description: Only ticket items become bookings. A sale recorded after the event is counted on the event date. A cancelled booking has no net seats.
    model: core_bookings
    given:
      - input: ref('core_order_item_economics')
        rows:
          - {order_item_key: A1, order_key: A, source_system: webapp, platform_era: bronco, item_kind: ticket, event_key: E1, purchased_at: "2026-09-01 14:00:00", purchase_date: "2026-09-01", seats: 2, realized_revenue: 126, net_distributable: 122, sns_share: 48.8, instructor_share: 73.2, fee_source: actual, is_cancelled: false}
          - {order_item_key: A2, order_key: A, source_system: webapp, platform_era: bronco, item_kind: gift_card, event_key: null, purchased_at: "2026-09-01 14:00:00", purchase_date: "2026-09-01", seats: 1, realized_revenue: 50, is_cancelled: false}
          - {order_item_key: B1, order_key: B, source_system: webapp, platform_era: bronco, item_kind: ticket, event_key: E1, purchased_at: "2026-09-12 14:00:00", purchase_date: "2026-09-12", seats: 1, realized_revenue: 63, is_cancelled: false}
          - {order_item_key: C1, order_key: C, source_system: webapp, platform_era: bronco, item_kind: ticket, event_key: E1, purchased_at: "2026-09-05 14:00:00", purchase_date: "2026-09-05", seats: 3, realized_revenue: 189, is_cancelled: true}
          - {order_item_key: N1, order_key: N, source_system: woocommerce, platform_era: legacy_event_tickets, item_kind: ticket, event_key: null, purchased_at: "2018-09-05 14:00:00", purchase_date: "2018-09-05", seats: 1, realized_revenue: 40, is_cancelled: false}
      - input: ref('core_events')
        rows:
          - {event_key: E1, event_date: "2026-09-10"}
      - input: ref('core_customer_identity')
        rows:
          - {order_key: A, customer_hash: h1, identity_source: cms}
          - {order_key: B, customer_hash: h2, identity_source: cms}
          - {order_key: C, customer_hash: h1, identity_source: cms}
    expect:
      rows:
        - {booking_key: A1, order_key: A, event_key: E1, customer_hash: h1, identity_source: cms, purchase_date: "2026-09-01", sale_date: "2026-09-01", days_before_event: 9, seats: 2, net_seats: 2}
        - {booking_key: B1, order_key: B, event_key: E1, customer_hash: h2, identity_source: cms, purchase_date: "2026-09-12", sale_date: "2026-09-10", days_before_event: -2, seats: 1, net_seats: 1}
        - {booking_key: C1, order_key: C, event_key: E1, customer_hash: h1, identity_source: cms, purchase_date: "2026-09-05", sale_date: "2026-09-05", days_before_event: 5, seats: 3, net_seats: 0}
        - {booking_key: N1, order_key: N, event_key: null, customer_hash: null, identity_source: unresolved, purchase_date: "2018-09-05", sale_date: "2018-09-05", days_before_event: null, seats: 1, net_seats: 1}
```

Run: `cd dbt && ../.venv/bin/dbt test --select bookings_are_ticket_items_with_event_timing`
Expected: ERROR, model `core_bookings` not found.

- [ ] **Step 5: Create `core_bookings.sql`**

```sql
{{ config(tags=['hourly']) }}
-- The economics fact: one row per ticket order item (order x event), both eras.
select
  i.order_item_key as booking_key, i.order_key, i.event_key,
  ci.customer_hash, coalesce(ci.identity_source, 'unresolved') as identity_source,
  i.source_system, i.platform_era,
  i.purchased_at, i.purchase_date,
  least(i.purchase_date, coalesce(e.event_date, i.purchase_date)) as sale_date,
  date_diff(e.event_date, i.purchase_date, day) as days_before_event,
  i.seats, if(i.is_cancelled, 0, i.seats) as net_seats,
  i.list_value, i.discount, i.service_fee, i.realized_revenue, i.refunded_amount, i.processing_fee, i.fee_source,
  i.net_distributable, i.sns_share, i.instructor_share, i.is_cancelled
from {{ ref('core_order_item_economics') }} i
left join {{ ref('core_events') }} e using (event_key)
left join {{ ref('core_customer_identity') }} ci on ci.order_key = i.order_key
where i.item_kind = 'ticket'
```

- [ ] **Step 6: Data tests**

`dbt/tests/core/assert_shares_sum_to_net.sql`:

```sql
select order_item_key
from {{ ref('core_order_item_economics') }}
where abs(sns_share + instructor_share - net_distributable) > 0.01
```

`dbt/tests/core/assert_allocation_conserves_money.sql`:

```sql
-- What was split across an order's items must add back up to the order-level amount.
with items as (
  select order_key, source_system, sum(discount) as discount, sum(service_fee) as service_fee,
    sum(refunded_amount) as refunded, sum(processing_fee) as fee, any_value(fee_source) as fee_source
  from {{ ref('core_order_item_economics') }}
  group by 1, 2
),
cms as (
  select o.order_key, o.discount, o.service_fee, coalesce(r.refunded, 0) as refunded
  from {{ ref('stg_cms__orders') }} o
  left join (select order_key, sum(amount) as refunded from {{ ref('stg_cms__refunds') }}
             where status in ('Completed', 'Succeeded', 'succeeded') group by 1) r using (order_key)
),
stripe as (
  select order_key, sum(fee) as fee from {{ ref('core_stripe_transactions') }} where order_key is not null group by 1
)
select i.order_key, 'discount' as what, i.discount as allocated, c.discount as expected
from items i join cms c using (order_key) where i.source_system = 'webapp' and abs(i.discount - coalesce(c.discount, 0)) > 0.01
union all
select i.order_key, 'service_fee', i.service_fee, c.service_fee
from items i join cms c using (order_key) where i.source_system = 'webapp' and abs(i.service_fee - coalesce(c.service_fee, 0)) > 0.01
union all
select i.order_key, 'refund', i.refunded, c.refunded
from items i join cms c using (order_key) where i.source_system = 'webapp' and abs(i.refunded - c.refunded) > 0.01
union all
select i.order_key, 'stripe_fee', i.fee, s.fee
from items i join stripe s using (order_key) where i.fee_source = 'actual' and abs(i.fee - s.fee) > 0.01
```

`dbt/tests/core/assert_no_estimated_fee_on_settled_bronco.sql` (Review focus 1):

```sql
-- Stripe loads daily and the CMS hourly, so a fresh bronco order legitimately has no Stripe charge yet.
-- After two days a card-paid bronco order without one is a broken join, not a timing gap.
select booking_key, order_key, purchase_date
from {{ ref('core_bookings') }}
where platform_era = 'bronco' and fee_source = 'estimated'
  and purchase_date < date_sub(current_date('America/New_York'), interval 2 day)
```

`dbt/tests/core/assert_fee_actual_coverage.sql` (addendum success criterion 2):

```sql
{{ config(severity='warn') }}
select platform_era, extract(year from purchase_date) as yr,
  countif(fee_source != 'none') as card_paid, countif(fee_source = 'actual') as actual
from {{ ref('core_bookings') }}
where purchase_date < date_sub(current_date('America/New_York'), interval 2 day)
group by 1, 2
having safe_divide(countif(fee_source = 'actual'), nullif(countif(fee_source != 'none'), 0)) < 0.98
```

Append to `dbt/models/core/schema.yml` under `models:`:

```yaml
  - name: core_order_item_economics
    columns:
      - name: order_item_key
        data_tests: [unique, not_null]
      - name: fee_source
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [actual, estimated, none]
      - name: item_kind
        data_tests:
          - accepted_values:
              arguments:
                values: [ticket, gift_card, other]
      - name: platform_era
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [legacy_event_tickets, bronco]
      - name: realized_revenue
        data_tests: [not_null]
      - name: processing_fee
        data_tests:
          - dbt_utils.accepted_range:
              arguments:
                min_value: 0

  - name: core_bookings
    description: "One row per ticket order item. sns_share is 40% of realized revenue less refunds less Stripe fees. Instructor materials are never subtracted."
    columns:
      - name: booking_key
        data_tests: [unique, not_null]
      - name: platform_era
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [legacy_event_tickets, bronco]
      - name: event_key
        data_tests:
          - relationships:
              arguments:
                to: ref('core_events')
                field: event_key
              config:
                severity: warn
```

- [ ] **Step 7: Build and reconcile against the base model**

Run: `cd dbt && ../.venv/bin/dbt build --select core_order_item_economics+`
Expected: all unit tests pass; all error-severity data tests pass.

Then confirm bookings agree with `core_orders` for the pinned window. Seats and realized revenue from bookings must be within 1% of the base model's ticket orders:

```bash
../.venv/bin/dbt show --inline "select 'core_orders' src, sum(seats) seats, round(sum(gross_revenue)) revenue from {{ ref('core_orders') }} where source_system='webapp' and order_type='ticket' and business_date between '2026-06-23' and '2026-09-17' union all select 'core_bookings', sum(seats), round(sum(realized_revenue)) from {{ ref('core_bookings') }} where platform_era='bronco' and purchase_date between '2026-06-23' and '2026-09-17'"
```

If revenue differs by more than 1%, the usual cause is gift-card-paid orders: `core_orders.gross_revenue` is the charged total, which excludes the gift card amount, while `realized_revenue` includes it by design. Quantify it with `select sum(gift_card_applied) from core_orders` over the same window before concluding anything is wrong. Record both numbers for Task 10.

- [ ] **Step 8: Commit**

```bash
git add dbt/models/core/core_order_item_economics.sql dbt/models/core/core_bookings.sql dbt/models/core/unit_tests.yml dbt/models/core/schema.yml dbt/tests/core/assert_shares_sum_to_net.sql dbt/tests/core/assert_allocation_conserves_money.sql dbt/tests/core/assert_no_estimated_fee_on_settled_bronco.sql dbt/tests/core/assert_fee_actual_coverage.sql
git commit -m "feat(dbt): order item economics and core_bookings with 60/40 split after Stripe fees

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Ad spend allocation and the booking curve

**Files:**
- Create: `dbt/models/core/core_ad_spend_allocation.sql`, `dbt/models/core/core_event_daily.sql`, `dbt/models/ops/ops_unallocated_ad_spend.sql`
- Modify: `dbt/models/core/unit_tests.yml`, `dbt/models/core/schema.yml`
- Create: `dbt/models/ops/schema.yml`, `dbt/tests/core/assert_spend_conserves.sql`, `dbt/tests/core/assert_curve_closes.sql`

**Interfaces:**
- Consumes: `core_bookings` (`event_key, sale_date, net_seats, realized_revenue, refunded_amount, sns_share`), `core_events` (`event_key, event_date, metro_key, capacity, platform_era, has_event_date`), `core_ad_spend` (`date, platform, metro_key, spend`); variable `curve_days`.
- Produces:
  - `core_ad_spend_allocation`, grain `date × platform × metro_key × event_key`: `date, platform, metro_key, event_key, spend`. `event_key` is null on the unallocated remainder. `metro_key` is null for spend that belongs to no metro.
  - `core_event_daily`, grain `event_key × snapshot_date`: `event_key, snapshot_date, days_until_event, platform_era, capacity, seats_sold_that_day, cumulative_seats, remaining_capacity, pct_sold, cumulative_realized_revenue, cumulative_sns_share, ad_spend_that_day, cumulative_ad_spend, has_spend_data_that_day`. `cumulative_realized_revenue` is realized revenue less refunds.
  - `ops_unallocated_ad_spend`: `date, platform, metro_key, spend`.

- [ ] **Step 1: Write the failing unit tests**

Append to `dbt/models/core/unit_tests.yml`:

```yaml
  - name: ad_spend_split_by_seats_within_metro_day
    description: Metro spend is divided among that metro's events by seats sold that day. Spend with no metro is divided among all events. Spend nobody can absorb stays unallocated.
    model: core_ad_spend_allocation
    given:
      - input: ref('core_ad_spend')
        rows:
          - {date: "2026-09-01", platform: meta, metro_key: m1, campaign_name: c1, spend: 60}
          - {date: "2026-09-01", platform: meta, metro_key: m1, campaign_name: c2, spend: 30}
          - {date: "2026-09-01", platform: google, metro_key: null, campaign_name: c3, spend: 40}
          - {date: "2026-09-02", platform: meta, metro_key: m2, campaign_name: c4, spend: 25}
      - input: ref('core_bookings')
        rows:
          - {booking_key: b1, event_key: E1, sale_date: "2026-09-01", net_seats: 2}
          - {booking_key: b2, event_key: E2, sale_date: "2026-09-01", net_seats: 1}
          - {booking_key: b3, event_key: E3, sale_date: "2026-09-01", net_seats: 1}
          - {booking_key: b4, event_key: E1, sale_date: "2026-09-01", net_seats: 0}
          - {booking_key: b5, event_key: null, sale_date: "2026-09-01", net_seats: 5}
      - input: ref('core_events')
        rows:
          - {event_key: E1, metro_key: m1, has_event_date: true}
          - {event_key: E2, metro_key: m1, has_event_date: true}
          - {event_key: E3, metro_key: m2, has_event_date: true}
    expect:
      rows:
        - {date: "2026-09-01", platform: meta, metro_key: m1, event_key: E1, spend: 60}
        - {date: "2026-09-01", platform: meta, metro_key: m1, event_key: E2, spend: 30}
        - {date: "2026-09-01", platform: google, metro_key: null, event_key: E1, spend: 20}
        - {date: "2026-09-01", platform: google, metro_key: null, event_key: E2, spend: 10}
        - {date: "2026-09-01", platform: google, metro_key: null, event_key: E3, spend: 10}
        - {date: "2026-09-02", platform: meta, metro_key: m2, event_key: null, spend: 25}

  - name: event_daily_curve
    description: Cumulative seats by day, percentage sold against capacity, spend attached on the day it was spent.
    model: core_event_daily
    overrides:
      vars: {curve_days: 3}
    given:
      - input: ref('core_events')
        rows:
          - {event_key: E1, event_date: "2026-09-10", capacity: 10, platform_era: bronco, has_event_date: true}
      - input: ref('core_bookings')
        rows:
          - {booking_key: b1, event_key: E1, sale_date: "2026-09-05", net_seats: 4, realized_revenue: 252, refunded_amount: 0, sns_share: 97.6}
          - {booking_key: b2, event_key: E1, sale_date: "2026-09-09", net_seats: 6, realized_revenue: 378, refunded_amount: 0, sns_share: 146.4}
          - {booking_key: b3, event_key: E1, sale_date: "2026-09-09", net_seats: 0, realized_revenue: 63, refunded_amount: 63, sns_share: -0.8}
      - input: ref('core_ad_spend_allocation')
        rows:
          - {date: "2026-09-05", platform: meta, metro_key: m1, event_key: E1, spend: 12}
          - {date: "2026-09-05", platform: google, metro_key: null, event_key: E1, spend: 3}
          - {date: "2026-09-08", platform: meta, metro_key: m1, event_key: null, spend: 9}
    expect:
      rows:
        - {event_key: E1, snapshot_date: "2026-09-05", days_until_event: 5, seats_sold_that_day: 4, cumulative_seats: 4, remaining_capacity: 6, pct_sold: 0.4, cumulative_realized_revenue: 252, cumulative_sns_share: 97.6, ad_spend_that_day: 15, cumulative_ad_spend: 15, has_spend_data_that_day: true}
        - {event_key: E1, snapshot_date: "2026-09-06", days_until_event: 4, seats_sold_that_day: 0, cumulative_seats: 4, remaining_capacity: 6, pct_sold: 0.4, cumulative_realized_revenue: 252, cumulative_sns_share: 97.6, ad_spend_that_day: 0, cumulative_ad_spend: 15, has_spend_data_that_day: false}
        - {event_key: E1, snapshot_date: "2026-09-07", days_until_event: 3, seats_sold_that_day: 0, cumulative_seats: 4, remaining_capacity: 6, pct_sold: 0.4, cumulative_realized_revenue: 252, cumulative_sns_share: 97.6, ad_spend_that_day: 0, cumulative_ad_spend: 15, has_spend_data_that_day: false}
        - {event_key: E1, snapshot_date: "2026-09-08", days_until_event: 2, seats_sold_that_day: 0, cumulative_seats: 4, remaining_capacity: 6, pct_sold: 0.4, cumulative_realized_revenue: 252, cumulative_sns_share: 97.6, ad_spend_that_day: 0, cumulative_ad_spend: 15, has_spend_data_that_day: true}
        - {event_key: E1, snapshot_date: "2026-09-09", days_until_event: 1, seats_sold_that_day: 6, cumulative_seats: 10, remaining_capacity: 0, pct_sold: 1.0, cumulative_realized_revenue: 630, cumulative_sns_share: 243.2, ad_spend_that_day: 0, cumulative_ad_spend: 15, has_spend_data_that_day: false}
        - {event_key: E1, snapshot_date: "2026-09-10", days_until_event: 0, seats_sold_that_day: 0, cumulative_seats: 10, remaining_capacity: 0, pct_sold: 1.0, cumulative_realized_revenue: 630, cumulative_sns_share: 243.2, ad_spend_that_day: 0, cumulative_ad_spend: 15, has_spend_data_that_day: false}

  - name: event_daily_no_capacity
    description: Review focus 3. With no capacity there is no percentage sold and no remaining capacity; seats still accumulate.
    model: core_event_daily
    overrides:
      vars: {curve_days: 1}
    given:
      - input: ref('core_events')
        rows:
          - {event_key: E1, event_date: "2024-05-04", capacity: null, platform_era: legacy_event_tickets, has_event_date: true}
          - {event_key: E2, event_date: null, capacity: 10, platform_era: legacy_event_tickets, has_event_date: false}
      - input: ref('core_bookings')
        rows:
          - {booking_key: b1, event_key: E1, sale_date: "2024-05-03", net_seats: 3, realized_revenue: 150, refunded_amount: 0, sns_share: 58}
          - {booking_key: b2, event_key: E2, sale_date: "2018-05-03", net_seats: 3, realized_revenue: 150, refunded_amount: 0, sns_share: 58}
      - input: ref('core_ad_spend_allocation')
        rows: []
    expect:
      rows:
        - {event_key: E1, snapshot_date: "2024-05-03", days_until_event: 1, cumulative_seats: 3, remaining_capacity: null, pct_sold: null}
        - {event_key: E1, snapshot_date: "2024-05-04", days_until_event: 0, cumulative_seats: 3, remaining_capacity: null, pct_sold: null}

  - name: event_daily_late_sale_clamped
    description: Review focus 4. core_bookings already moved a late sale to the event date, so the last row carries every seat. An oversold event caps pct_sold at 1.
    model: core_event_daily
    overrides:
      vars: {curve_days: 1}
    given:
      - input: ref('core_events')
        rows:
          - {event_key: E1, event_date: "2024-05-04", capacity: 4, platform_era: legacy_event_tickets, has_event_date: true}
      - input: ref('core_bookings')
        rows:
          - {booking_key: b1, event_key: E1, sale_date: "2024-05-03", net_seats: 3, realized_revenue: 150, refunded_amount: 0, sns_share: 58}
          - {booking_key: b2, event_key: E1, sale_date: "2024-05-04", net_seats: 2, realized_revenue: 100, refunded_amount: 0, sns_share: 38}
      - input: ref('core_ad_spend_allocation')
        rows: []
    expect:
      rows:
        - {event_key: E1, snapshot_date: "2024-05-03", cumulative_seats: 3, remaining_capacity: 1, pct_sold: 0.75}
        - {event_key: E1, snapshot_date: "2024-05-04", cumulative_seats: 5, remaining_capacity: 0, pct_sold: 1.0}
```

Run: `cd dbt && ../.venv/bin/dbt test --select "test_type:unit,core_ad_spend_allocation" "test_type:unit,core_event_daily"`
Expected: ERROR, models not found.

- [ ] **Step 2: Create `core_ad_spend_allocation.sql`**

```sql
-- An allocation convention, not attribution and not a measure of incrementality.
-- Each (date, platform, metro) amount of spend is divided among the events that sold seats that day,
-- in that metro, in proportion to seats. Spend with no metro is divided among every event that sold
-- seats that day. What no event can absorb is kept with event_key null so that money is conserved.
with spend as (
  select date, platform, metro_key, sum(spend) as spend
  from {{ ref('core_ad_spend') }}
  where spend is not null and spend != 0
  group by 1, 2, 3
),
sales as (
  select b.sale_date as date, e.metro_key, b.event_key, sum(b.net_seats) as seats
  from {{ ref('core_bookings') }} b
  join {{ ref('core_events') }} e using (event_key)
  where e.has_event_date
  group by 1, 2, 3
  having sum(b.net_seats) > 0
),
metro_split as (
  select sp.date, sp.platform, sp.metro_key, s.event_key,
    sp.spend * s.seats / sum(s.seats) over (partition by sp.date, sp.platform, sp.metro_key) as spend
  from spend sp
  join sales s on s.date = sp.date and s.metro_key = sp.metro_key
  where sp.metro_key is not null
),
national_split as (
  select sp.date, sp.platform, sp.metro_key, s.event_key,
    sp.spend * s.seats / sum(s.seats) over (partition by sp.date, sp.platform) as spend
  from spend sp
  join (select date, event_key, sum(seats) as seats from sales group by 1, 2) s on s.date = sp.date
  where sp.metro_key is null
),
allocated as (
  select * from metro_split union all select * from national_split
),
remainder as (
  select sp.date, sp.platform, sp.metro_key, cast(null as string) as event_key, sp.spend
  from spend sp
  where not exists (
    select 1 from allocated a
    where a.date = sp.date and a.platform = sp.platform
      and (a.metro_key = sp.metro_key or (a.metro_key is null and sp.metro_key is null))
  )
)
select date, platform, metro_key, event_key, round(spend, 6) as spend from allocated
union all
select date, platform, metro_key, event_key, round(spend, 6) as spend from remainder
```

- [ ] **Step 3: Create `core_event_daily.sql`**

```sql
{{ config(partition_by={'field': 'snapshot_date', 'data_type': 'date', 'granularity': 'month'}, cluster_by=['event_key']) }}
-- The booking curve: one row per event per calendar day, from the earlier of the first sale and
-- curve_days before the event, up to the event date. Capacity is the final recorded capacity.
with sales as (
  select event_key, sale_date,
    sum(net_seats) as seats,
    sum(realized_revenue - refunded_amount) as revenue,
    sum(sns_share) as sns_share
  from {{ ref('core_bookings') }}
  where event_key is not null
  group by 1, 2
),
events as (
  select e.event_key, e.event_date, e.capacity, e.platform_era,
    least(date_sub(e.event_date, interval {{ var('curve_days') }} day), coalesce(min(s.sale_date), e.event_date)) as curve_start
  from {{ ref('core_events') }} e
  left join sales s using (event_key)
  where e.has_event_date
  group by 1, 2, 3, 4
),
spine as (
  select e.event_key, e.event_date, e.capacity, e.platform_era, snapshot_date
  from events e, unnest(generate_date_array(e.curve_start, e.event_date)) as snapshot_date
),
spend as (
  select event_key, date, sum(spend) as spend
  from {{ ref('core_ad_spend_allocation') }}
  where event_key is not null
  group by 1, 2
),
spend_days as (
  select distinct date from {{ ref('core_ad_spend_allocation') }}
),
daily as (
  select sp.event_key, sp.snapshot_date, sp.event_date, sp.capacity, sp.platform_era,
    coalesce(s.seats, 0) as seats_sold_that_day,
    coalesce(s.revenue, 0) as revenue_that_day,
    coalesce(s.sns_share, 0) as sns_share_that_day,
    coalesce(a.spend, 0) as ad_spend_that_day,
    d.date is not null as has_spend_data_that_day
  from spine sp
  left join sales s on s.event_key = sp.event_key and s.sale_date = sp.snapshot_date
  left join spend a on a.event_key = sp.event_key and a.date = sp.snapshot_date
  left join spend_days d on d.date = sp.snapshot_date
),
running as (
  select *,
    sum(seats_sold_that_day) over w as cumulative_seats,
    sum(revenue_that_day) over w as cumulative_revenue,
    sum(sns_share_that_day) over w as cumulative_sns_share,
    sum(ad_spend_that_day) over w as cumulative_ad_spend
  from daily
  window w as (partition by event_key order by snapshot_date rows between unbounded preceding and current row)
)
select event_key, snapshot_date, date_diff(event_date, snapshot_date, day) as days_until_event, platform_era, capacity,
  seats_sold_that_day, cumulative_seats,
  if(capacity > 0, greatest(capacity - cumulative_seats, 0), null) as remaining_capacity,
  if(capacity > 0, least(round(cumulative_seats / capacity, 6), 1.0), null) as pct_sold,
  round(cumulative_revenue, 6) as cumulative_realized_revenue,
  round(cumulative_sns_share, 6) as cumulative_sns_share,
  round(ad_spend_that_day, 6) as ad_spend_that_day,
  round(cumulative_ad_spend, 6) as cumulative_ad_spend,
  has_spend_data_that_day
from running
```

- [ ] **Step 4: Create `ops_unallocated_ad_spend.sql` and its schema**

`dbt/models/ops/ops_unallocated_ad_spend.sql`:

```sql
-- Ad spend that no event absorbed: no event in that metro sold a seat that day.
select date, platform, metro_key, spend
from {{ ref('core_ad_spend_allocation') }}
where event_key is null
```

`dbt/models/ops/schema.yml`:

```yaml
version: 2

models:
  - name: ops_unallocated_ad_spend
    description: "Spend left over after allocation to events. Large values in a metro mean ads ran on days nothing sold there."
    columns:
      - name: spend
        data_tests: [not_null]
```

- [ ] **Step 5: Data tests**

`dbt/tests/core/assert_spend_conserves.sql`:

```sql
with a as (select date, sum(spend) as spend from {{ ref('core_ad_spend_allocation') }} group by 1),
s as (select date, sum(spend) as spend from {{ ref('core_ad_spend') }} group by 1)
select coalesce(a.date, s.date) as date, a.spend as allocated_plus_unallocated, s.spend as total
from a full outer join s using (date)
where abs(coalesce(a.spend, 0) - coalesce(s.spend, 0)) > 0.01
```

`dbt/tests/core/assert_curve_closes.sql`:

```sql
-- On the event date the curve must hold exactly the seats the bookings hold.
with last_day as (
  select event_key, cumulative_seats from {{ ref('core_event_daily') }} where days_until_event = 0
),
booked as (
  select event_key, sum(net_seats) as seats from {{ ref('core_bookings') }} where event_key is not null group by 1
)
select l.event_key, l.cumulative_seats, coalesce(b.seats, 0) as booked_seats
from last_day l
left join booked b using (event_key)
where l.cumulative_seats != coalesce(b.seats, 0)
```

Append to `dbt/models/core/schema.yml` under `models:`:

```yaml
  - name: core_ad_spend_allocation
    description: "Allocation convention, not attribution. event_key is null on spend no event absorbed."
    columns:
      - name: spend
        data_tests: [not_null]

  - name: core_event_daily
    description: "Booking curve. cumulative_realized_revenue is realized revenue less refunds. Capacity is the final recorded capacity, so pct_sold is capped at 1."
    data_tests:
      - dbt_utils.unique_combination_of_columns:
          arguments:
            combination_of_columns: [event_key, snapshot_date]
    columns:
      - name: platform_era
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [legacy_event_tickets, bronco]
      - name: days_until_event
        data_tests:
          - dbt_utils.accepted_range:
              arguments:
                min_value: 0
```

- [ ] **Step 6: Build**

Run: `cd dbt && ../.venv/bin/dbt build --select core_ad_spend_allocation+`
Expected: four unit tests pass; `assert_spend_conserves` and `assert_curve_closes` pass; models built. `core_event_daily` should hold between one and three million rows:

```bash
../.venv/bin/dbt show --inline "select platform_era, count(*) row_count, count(distinct event_key) events from {{ ref('core_event_daily') }} group by 1"
```

- [ ] **Step 7: Commit**

```bash
git add dbt/models/core/core_ad_spend_allocation.sql dbt/models/core/core_event_daily.sql dbt/models/ops/ops_unallocated_ad_spend.sql dbt/models/ops/schema.yml dbt/models/core/unit_tests.yml dbt/models/core/schema.yml dbt/tests/core/assert_spend_conserves.sql dbt/tests/core/assert_curve_closes.sql
git commit -m "feat(dbt): booking curve per event and conserved ad spend allocation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `core_event_economics` and `core_customers`

**Files:**
- Create: `dbt/macros/season.sql`, `dbt/models/core/core_event_economics.sql`, `dbt/models/core/core_customers.sql`
- Modify: `dbt/models/core/unit_tests.yml`, `dbt/models/core/schema.yml`
- Create: `dbt/tests/core/assert_event_economics_matches_bookings.sql`, `dbt/tests/core/assert_cross_era_customers_exist.sql`

**Interfaces:**
- Consumes: `core_events` (Task 5), `core_bookings` (Task 6), `core_event_daily` (Task 7), `core_orders` (`order_key, customer_hash, identity_source, created_at, business_date, platform_era`), `core_session_orders` (`order_key, session_key`), `core_sessions` (`session_key, default_channel_group`); variable `materials_per_seat`.
- Produces:
  - macro `season(date_expr)` → `winter` | `spring` | `summer` | `fall`.
  - `core_event_economics`, one row per event: `event_key, title, event_date, start_at, start_hour_local, weekday, is_weekend, month, season, venue_key, metro_key, instructor_key, category, event_type, theme, status, platform_era, has_event_date, capacity, capacity_source, ticket_price, seats_sold, bookings, customers, utilisation, utilisation_band, sold_out, realized_revenue, refunded_amount, processing_fee, fee_actual_share, net_distributable, sns_share, instructor_share, instructor_materials_estimate, allocated_ad_spend, has_ad_spend_data, sns_contribution_before_ads, sns_contribution, sns_share_per_available_seat, sns_share_per_sold_seat, contribution_per_available_seat, contribution_per_sold_seat, first_sale_days_before, days_before_at_25pct, days_before_at_50pct, days_before_at_75pct, days_before_at_sellout`.
  - `core_customers`, one row per resolved `customer_hash`: `customer_hash, is_surrogate, first_purchase_date, most_recent_purchase_date, first_era, eras_seen ARRAY<STRING>, bought_in_both_eras, lifetime_orders, lifetime_events, lifetime_seats, lifetime_realized_revenue, lifetime_sns_share, home_metro_key, first_order_channel, is_repeat, days_first_to_second_purchase`.

`sns_share_per_available_seat` and `sns_share_per_sold_seat` are additions to the spec's column list. They exist because `sns_contribution` is null wherever ad spend history is missing, which covers most of the legacy era, and the milestone still needs a per-seat figure that is comparable across eras.

- [ ] **Step 1: Write the failing unit tests**

Append to `dbt/models/core/unit_tests.yml`:

```yaml
  - name: event_economics_outcomes_and_pace
    description: A sold-out event with spend data; an event with no capacity (review focus 3); an event nobody booked.
    model: core_event_economics
    given:
      - input: ref('core_events')
        rows:
          - {event_key: E1, title: "Sold out", event_date: "2026-09-10", start_at: "2026-09-10 22:30:00", time_zone: "America/New_York", metro_key: m1, capacity: 10, capacity_source: cms, ticket_price: 63, platform_era: bronco, has_event_date: true}
          - {event_key: E2, title: "No capacity", event_date: "2024-05-04", start_at: "2024-05-04 23:00:00", time_zone: "America/Chicago", metro_key: m1, capacity: null, capacity_source: none, ticket_price: 50, platform_era: legacy_event_tickets, has_event_date: true}
          - {event_key: E3, title: "Nobody came", event_date: "2026-01-15", start_at: "2026-01-16 00:00:00", time_zone: "America/New_York", metro_key: m1, capacity: 12, capacity_source: cms, ticket_price: 70, platform_era: legacy_event_tickets, has_event_date: true}
      - input: ref('core_bookings')
        rows:
          - {booking_key: b1, event_key: E1, customer_hash: h1, seats: 4, net_seats: 4, realized_revenue: 252, refunded_amount: 0, processing_fee: 8, fee_source: actual, net_distributable: 244, sns_share: 97.6, instructor_share: 146.4, is_cancelled: false}
          - {booking_key: b2, event_key: E1, customer_hash: h2, seats: 6, net_seats: 6, realized_revenue: 378, refunded_amount: 0, processing_fee: 12, fee_source: actual, net_distributable: 366, sns_share: 146.4, instructor_share: 219.6, is_cancelled: false}
          - {booking_key: b3, event_key: E2, customer_hash: h1, seats: 3, net_seats: 3, realized_revenue: 150, refunded_amount: 0, processing_fee: 5, fee_source: estimated, net_distributable: 145, sns_share: 58, instructor_share: 87, is_cancelled: false}
      - input: ref('core_event_daily')
        rows:
          - {event_key: E1, snapshot_date: "2026-09-05", days_until_event: 5, cumulative_seats: 4, pct_sold: 0.4, ad_spend_that_day: 15, has_spend_data_that_day: true}
          - {event_key: E1, snapshot_date: "2026-09-09", days_until_event: 1, cumulative_seats: 10, pct_sold: 1.0, ad_spend_that_day: 0, has_spend_data_that_day: false}
          - {event_key: E1, snapshot_date: "2026-09-10", days_until_event: 0, cumulative_seats: 10, pct_sold: 1.0, ad_spend_that_day: 0, has_spend_data_that_day: false}
          - {event_key: E2, snapshot_date: "2024-05-03", days_until_event: 1, cumulative_seats: 3, pct_sold: null, ad_spend_that_day: 0, has_spend_data_that_day: false}
          - {event_key: E2, snapshot_date: "2024-05-04", days_until_event: 0, cumulative_seats: 3, pct_sold: null, ad_spend_that_day: 0, has_spend_data_that_day: false}
          - {event_key: E3, snapshot_date: "2026-01-15", days_until_event: 0, cumulative_seats: 0, pct_sold: 0, ad_spend_that_day: 0, has_spend_data_that_day: false}
    expect:
      rows:
        - {event_key: E1, weekday: Thursday, is_weekend: false, month: 9, season: fall, start_hour_local: 18, seats_sold: 10, bookings: 2, customers: 2, utilisation: 1.0, utilisation_band: "95-100", sold_out: true, realized_revenue: 630, processing_fee: 20, fee_actual_share: 1.0, net_distributable: 610, sns_share: 244, instructor_share: 366, instructor_materials_estimate: 60, allocated_ad_spend: 15, has_ad_spend_data: true, sns_contribution_before_ads: 244, sns_contribution: 229, sns_share_per_available_seat: 24.4, sns_share_per_sold_seat: 24.4, contribution_per_available_seat: 22.9, contribution_per_sold_seat: 22.9, first_sale_days_before: 5, days_before_at_25pct: 5, days_before_at_50pct: 1, days_before_at_75pct: 1, days_before_at_sellout: 1}
        - {event_key: E2, weekday: Saturday, is_weekend: true, month: 5, season: spring, start_hour_local: 18, seats_sold: 3, bookings: 1, customers: 1, utilisation: null, utilisation_band: null, sold_out: false, realized_revenue: 150, processing_fee: 5, fee_actual_share: 0.0, net_distributable: 145, sns_share: 58, instructor_share: 87, instructor_materials_estimate: 18, allocated_ad_spend: null, has_ad_spend_data: false, sns_contribution_before_ads: 58, sns_contribution: null, sns_share_per_available_seat: null, sns_share_per_sold_seat: 19.333333, contribution_per_available_seat: null, contribution_per_sold_seat: null, first_sale_days_before: 1, days_before_at_25pct: null, days_before_at_50pct: null, days_before_at_75pct: null, days_before_at_sellout: null}
        - {event_key: E3, weekday: Thursday, is_weekend: false, month: 1, season: winter, start_hour_local: 19, seats_sold: 0, bookings: 0, customers: 0, utilisation: 0.0, utilisation_band: "<40", sold_out: false, realized_revenue: 0, processing_fee: 0, fee_actual_share: null, net_distributable: 0, sns_share: 0, instructor_share: 0, instructor_materials_estimate: 0, allocated_ad_spend: null, has_ad_spend_data: false, sns_contribution_before_ads: 0, sns_contribution: null, sns_share_per_available_seat: 0.0, sns_share_per_sold_seat: null, first_sale_days_before: null, days_before_at_25pct: null, days_before_at_sellout: null}

  - name: customers_span_both_eras
    description: One person who bought on the legacy site and on the new platform is one customer. Unresolved orders create no customer.
    model: core_customers
    given:
      - input: ref('core_orders')
        rows:
          - {order_key: "woo-1", customer_hash: h1, identity_source: stripe, created_at: "2025-01-10 15:00:00", business_date: "2025-01-10", platform_era: legacy_event_tickets}
          - {order_key: "woo-2", customer_hash: h1, identity_source: woo_propagated, created_at: "2025-03-01 15:00:00", business_date: "2025-03-01", platform_era: legacy_event_tickets}
          - {order_key: A, customer_hash: h1, identity_source: cms, created_at: "2026-08-01 15:00:00", business_date: "2026-08-01", platform_era: bronco}
          - {order_key: B, customer_hash: h2, identity_source: cms, created_at: "2026-08-02 15:00:00", business_date: "2026-08-02", platform_era: bronco}
          - {order_key: "woo-3", customer_hash: "woo-cust-66", identity_source: woo_surrogate, created_at: "2019-08-02 15:00:00", business_date: "2019-08-02", platform_era: legacy_event_tickets}
          - {order_key: "woo-4", customer_hash: null, identity_source: unresolved, created_at: "2019-08-02 15:00:00", business_date: "2019-08-02", platform_era: legacy_event_tickets}
      - input: ref('core_bookings')
        rows:
          - {booking_key: k1, order_key: "woo-1", event_key: E1, customer_hash: h1, identity_source: stripe, purchase_date: "2025-01-10", net_seats: 2, realized_revenue: 100, refunded_amount: 0, sns_share: 38}
          - {booking_key: k2, order_key: "woo-2", event_key: E2, customer_hash: h1, identity_source: woo_propagated, purchase_date: "2025-03-01", net_seats: 1, realized_revenue: 50, refunded_amount: 0, sns_share: 19}
          - {booking_key: k3, order_key: A, event_key: E3, customer_hash: h1, identity_source: cms, purchase_date: "2026-08-01", net_seats: 2, realized_revenue: 126, refunded_amount: 0, sns_share: 48.8}
          - {booking_key: k4, order_key: B, event_key: E3, customer_hash: h2, identity_source: cms, purchase_date: "2026-08-02", net_seats: 1, realized_revenue: 63, refunded_amount: 63, sns_share: -0.8}
          - {booking_key: k5, order_key: "woo-3", event_key: E1, customer_hash: "woo-cust-66", identity_source: woo_surrogate, purchase_date: "2019-08-02", net_seats: 1, realized_revenue: 40, refunded_amount: 0, sns_share: 15}
      - input: ref('core_events')
        rows:
          - {event_key: E1, metro_key: boston}
          - {event_key: E2, metro_key: boston}
          - {event_key: E3, metro_key: nashville}
      - input: ref('core_session_orders')
        rows:
          - {order_key: B, session_key: s1}
      - input: ref('core_sessions')
        rows:
          - {session_key: s1, default_channel_group: "Paid Social"}
    expect:
      rows:
        - {customer_hash: h1, is_surrogate: false, first_purchase_date: "2025-01-10", most_recent_purchase_date: "2026-08-01", first_era: legacy_event_tickets, bought_in_both_eras: true, lifetime_orders: 3, lifetime_events: 3, lifetime_seats: 5, lifetime_realized_revenue: 276, lifetime_sns_share: 105.8, home_metro_key: boston, first_order_channel: null, is_repeat: true, days_first_to_second_purchase: 50}
        - {customer_hash: h2, is_surrogate: false, first_purchase_date: "2026-08-02", most_recent_purchase_date: "2026-08-02", first_era: bronco, bought_in_both_eras: false, lifetime_orders: 1, lifetime_events: 1, lifetime_seats: 1, lifetime_realized_revenue: 0, lifetime_sns_share: -0.8, home_metro_key: nashville, first_order_channel: "Paid Social", is_repeat: false, days_first_to_second_purchase: null}
        - {customer_hash: "woo-cust-66", is_surrogate: true, first_purchase_date: "2019-08-02", most_recent_purchase_date: "2019-08-02", first_era: legacy_event_tickets, bought_in_both_eras: false, lifetime_orders: 1, lifetime_events: 1, lifetime_seats: 1, lifetime_realized_revenue: 40, lifetime_sns_share: 15, home_metro_key: boston, first_order_channel: null, is_repeat: false, days_first_to_second_purchase: null}
```

Run: `cd dbt && ../.venv/bin/dbt test --select "test_type:unit,core_event_economics" "test_type:unit,core_customers"`
Expected: ERROR, models not found.

- [ ] **Step 2: Add the season macro**

`dbt/macros/season.sql`:

```sql
{% macro season(date_expr) -%}
case
  when extract(month from {{ date_expr }}) in (12, 1, 2) then 'winter'
  when extract(month from {{ date_expr }}) in (3, 4, 5) then 'spring'
  when extract(month from {{ date_expr }}) in (6, 7, 8) then 'summer'
  when extract(month from {{ date_expr }}) in (9, 10, 11) then 'fall'
end
{%- endmacro %}
```

- [ ] **Step 3: Create `core_event_economics.sql`**

```sql
-- One row per event in either era: what it was, how it sold, what it earned, how fast it filled.
-- Instructor materials appear only as an estimate on the instructor's side and are never subtracted
-- from any S&S figure. When there is no ad spend data for the selling window, contribution is null
-- rather than overstated.
with b as (
  select event_key,
    sum(net_seats) as seats_sold,
    count(*) as bookings,
    count(distinct customer_hash) as customers,
    sum(realized_revenue) as realized_revenue,
    sum(refunded_amount) as refunded_amount,
    sum(processing_fee) as processing_fee,
    safe_divide(sum(if(fee_source = 'actual', processing_fee, 0)), sum(processing_fee)) as fee_actual_share,
    sum(net_distributable) as net_distributable,
    sum(sns_share) as sns_share,
    sum(instructor_share) as instructor_share
  from {{ ref('core_bookings') }}
  where event_key is not null
  group by event_key
),
d as (
  select event_key,
    max(if(cumulative_seats > 0, days_until_event, null)) as first_sale_days_before,
    max(if(pct_sold >= 0.25, days_until_event, null)) as days_before_at_25pct,
    max(if(pct_sold >= 0.50, days_until_event, null)) as days_before_at_50pct,
    max(if(pct_sold >= 0.75, days_until_event, null)) as days_before_at_75pct,
    max(if(pct_sold >= 1.0, days_until_event, null)) as days_before_at_sellout,
    sum(ad_spend_that_day) as allocated_ad_spend,
    logical_or(has_spend_data_that_day) as has_ad_spend_data
  from {{ ref('core_event_daily') }}
  group by event_key
),
joined as (
  select e.event_key, e.title, e.event_date, e.start_at,
    extract(hour from datetime(e.start_at, e.time_zone)) as start_hour_local,
    format_date('%A', e.event_date) as weekday,
    extract(dayofweek from e.event_date) in (1, 7) as is_weekend,
    extract(month from e.event_date) as month,
    {{ season('e.event_date') }} as season,
    e.venue_key, e.metro_key, e.instructor_key, e.category, e.event_type, e.theme, e.status,
    e.platform_era, e.has_event_date, e.capacity, e.capacity_source, e.ticket_price,
    coalesce(b.seats_sold, 0) as seats_sold,
    coalesce(b.bookings, 0) as bookings,
    coalesce(b.customers, 0) as customers,
    coalesce(b.realized_revenue, 0) as realized_revenue,
    coalesce(b.refunded_amount, 0) as refunded_amount,
    coalesce(b.processing_fee, 0) as processing_fee,
    b.fee_actual_share,
    coalesce(b.net_distributable, 0) as net_distributable,
    coalesce(b.sns_share, 0) as sns_share,
    coalesce(b.instructor_share, 0) as instructor_share,
    coalesce(d.has_ad_spend_data, false) as has_ad_spend_data,
    if(coalesce(d.has_ad_spend_data, false), d.allocated_ad_spend, null) as allocated_ad_spend,
    d.first_sale_days_before, d.days_before_at_25pct, d.days_before_at_50pct, d.days_before_at_75pct, d.days_before_at_sellout
  from {{ ref('core_events') }} e
  left join b using (event_key)
  left join d using (event_key)
)
select event_key, title, event_date, start_at, start_hour_local, weekday, is_weekend, month, season,
  venue_key, metro_key, instructor_key, category, event_type, theme, status, platform_era, has_event_date,
  capacity, capacity_source, ticket_price,
  seats_sold, bookings, customers,
  if(capacity > 0, round(seats_sold / capacity, 6), null) as utilisation,
  case
    when capacity is null or capacity <= 0 then null
    when seats_sold / capacity < 0.40 then '<40'
    when seats_sold / capacity < 0.60 then '40-60'
    when seats_sold / capacity < 0.80 then '60-80'
    when seats_sold / capacity < 0.95 then '80-95'
    else '95-100'
  end as utilisation_band,
  coalesce(capacity > 0 and seats_sold >= capacity, false) as sold_out,
  round(realized_revenue, 6) as realized_revenue,
  round(refunded_amount, 6) as refunded_amount,
  round(processing_fee, 6) as processing_fee,
  round(fee_actual_share, 6) as fee_actual_share,
  round(net_distributable, 6) as net_distributable,
  round(sns_share, 6) as sns_share,
  round(instructor_share, 6) as instructor_share,
  round(seats_sold * {{ var('materials_per_seat') }}, 6) as instructor_materials_estimate,
  round(allocated_ad_spend, 6) as allocated_ad_spend,
  has_ad_spend_data,
  round(sns_share, 6) as sns_contribution_before_ads,
  round(sns_share - allocated_ad_spend, 6) as sns_contribution,
  round(safe_divide(sns_share, if(capacity > 0, capacity, null)), 6) as sns_share_per_available_seat,
  round(safe_divide(sns_share, nullif(seats_sold, 0)), 6) as sns_share_per_sold_seat,
  round(safe_divide(sns_share - allocated_ad_spend, if(capacity > 0, capacity, null)), 6) as contribution_per_available_seat,
  round(safe_divide(sns_share - allocated_ad_spend, nullif(seats_sold, 0)), 6) as contribution_per_sold_seat,
  first_sale_days_before, days_before_at_25pct, days_before_at_50pct, days_before_at_75pct, days_before_at_sellout
from joined
```

- [ ] **Step 4: Create `core_customers.sql`**

```sql
-- One row per resolved customer across both eras. Orders that resolved to nobody create no customer.
-- A woo-cust-<id> key is a registered legacy account whose email was never recovered (is_surrogate).
with o as (
  select order_key, customer_hash, identity_source, created_at, business_date, platform_era
  from {{ ref('core_orders') }}
  where customer_hash is not null and identity_source != 'unresolved'
),
ranked as (
  select *, row_number() over (partition by customer_hash order by created_at, order_key) as n
  from o
),
order_stats as (
  select customer_hash,
    min(business_date) as first_purchase_date,
    max(business_date) as most_recent_purchase_date,
    count(*) as lifetime_orders,
    array_agg(distinct platform_era order by platform_era) as eras_seen,
    count(distinct platform_era) > 1 as bought_in_both_eras,
    max(if(n = 1, platform_era, null)) as first_era,
    max(if(n = 1, order_key, null)) as first_order_key,
    max(if(n = 1, business_date, null)) as first_order_date,
    max(if(n = 2, business_date, null)) as second_order_date,
    logical_and(identity_source = 'woo_surrogate') as is_surrogate
  from ranked
  group by customer_hash
),
booking_stats as (
  select customer_hash,
    count(distinct event_key) as lifetime_events,
    sum(net_seats) as lifetime_seats,
    sum(realized_revenue - refunded_amount) as lifetime_realized_revenue,
    sum(sns_share) as lifetime_sns_share
  from {{ ref('core_bookings') }}
  where customer_hash is not null and identity_source != 'unresolved'
  group by customer_hash
),
home as (
  select b.customer_hash, e.metro_key
  from {{ ref('core_bookings') }} b
  join {{ ref('core_events') }} e using (event_key)
  where b.customer_hash is not null and e.metro_key is not null
  group by b.customer_hash, e.metro_key
  qualify row_number() over (partition by b.customer_hash order by count(*) desc, max(b.purchase_date) desc, e.metro_key) = 1
),
first_channel as (
  select os.customer_hash, s.default_channel_group
  from order_stats os
  join {{ ref('core_session_orders') }} so on so.order_key = os.first_order_key
  join {{ ref('core_sessions') }} s on s.session_key = so.session_key
)
select os.customer_hash, os.is_surrogate, os.first_purchase_date, os.most_recent_purchase_date,
  os.first_era, os.eras_seen, os.bought_in_both_eras,
  os.lifetime_orders,
  coalesce(bs.lifetime_events, 0) as lifetime_events,
  coalesce(bs.lifetime_seats, 0) as lifetime_seats,
  round(coalesce(bs.lifetime_realized_revenue, 0), 6) as lifetime_realized_revenue,
  round(coalesce(bs.lifetime_sns_share, 0), 6) as lifetime_sns_share,
  h.metro_key as home_metro_key,
  fc.default_channel_group as first_order_channel,
  os.lifetime_orders > 1 as is_repeat,
  date_diff(os.second_order_date, os.first_order_date, day) as days_first_to_second_purchase
from order_stats os
left join booking_stats bs using (customer_hash)
left join home h using (customer_hash)
left join first_channel fc using (customer_hash)
```

- [ ] **Step 5: Run the unit tests**

Run: `cd dbt && ../.venv/bin/dbt build --select core_event_economics core_customers`
Expected: both unit tests PASS; both models built.

- [ ] **Step 6: Data tests**

`dbt/tests/core/assert_event_economics_matches_bookings.sql`:

```sql
-- Rolling bookings up to events must not create or lose money or seats.
with e as (
  select sum(seats_sold) as seats, sum(sns_share) as sns_share, sum(realized_revenue) as revenue from {{ ref('core_event_economics') }}
),
b as (
  select sum(net_seats) as seats, sum(sns_share) as sns_share, sum(realized_revenue) as revenue from {{ ref('core_bookings') }} where event_key is not null
)
select e.seats as event_seats, b.seats as booking_seats, e.sns_share as event_sns, b.sns_share as booking_sns
from e cross join b
where e.seats != b.seats or abs(e.sns_share - b.sns_share) > 1 or abs(e.revenue - b.revenue) > 1
```

`dbt/tests/core/assert_cross_era_customers_exist.sql` (addendum success criterion 3):

```sql
-- If identity resolution works, thousands of legacy customers have also bought on the new platform.
-- Fewer than 500 means the two eras are not joining.
select n from (select countif(bought_in_both_eras) as n from {{ ref('core_customers') }}) where n < 500
```

Append to `dbt/models/core/schema.yml` under `models:`:

```yaml
  - name: core_event_economics
    description: "Authoritative event outcomes. sns_contribution is null when no ad spend data exists for the selling window; use sns_share_per_available_seat to compare across eras."
    columns:
      - name: event_key
        data_tests: [unique, not_null]
      - name: platform_era
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [legacy_event_tickets, bronco]
      - name: utilisation_band
        data_tests:
          - accepted_values:
              arguments:
                values: ["<40", "40-60", "60-80", "80-95", "95-100"]
      - name: seats_sold
        data_tests:
          - dbt_utils.accepted_range:
              arguments:
                min_value: 0

  - name: core_customers
    columns:
      - name: customer_hash
        data_tests: [unique, not_null]
      - name: first_era
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: [legacy_event_tickets, bronco]
```

- [ ] **Step 7: Build and sanity-check the shape of the business**

Run: `cd dbt && ../.venv/bin/dbt build --select core_event_economics+ core_customers+`
Expected: all pass.

Then print these and keep the output for Task 10. The 2022–2025 sold-out counts should be close to the archive-only counts measured on 2026-09-27 (1,073; 814; 817; 1,252). A figure far outside that means capacity or seat counting is wrong.

```bash
../.venv/bin/dbt show --limit 20 --inline "select extract(year from event_date) yr, platform_era, count(*) events, countif(sold_out) sold_out, round(avg(utilisation),3) avg_utilisation, round(sum(sns_share)) sns_share, countif(has_ad_spend_data) with_spend_data from {{ ref('core_event_economics') }} where has_event_date and seats_sold > 0 group by 1,2 order by 1,2"
../.venv/bin/dbt show --inline "select count(*) customers, countif(bought_in_both_eras) both_eras, countif(is_repeat) repeaters, countif(is_surrogate) surrogates, round(avg(lifetime_sns_share),2) avg_sns_share from {{ ref('core_customers') }}"
```

- [ ] **Step 8: Commit**

```bash
git add dbt/macros/season.sql dbt/models/core/core_event_economics.sql dbt/models/core/core_customers.sql dbt/models/core/unit_tests.yml dbt/models/core/schema.yml dbt/tests/core/assert_event_economics_matches_bookings.sql dbt/tests/core/assert_cross_era_customers_exist.sql
git commit -m "feat(dbt): event economics with pace and contribution; customers across both eras

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Marts

**Files:**
- Create: `dbt/models/marts/mart_event_performance.sql`, `dbt/models/marts/unit_tests.yml`
- Modify: `dbt/models/marts/mart_daily_kpis.sql`, `dbt/models/marts/mart_paid_performance.sql`, `dbt/models/marts/schema.yml`
- Rewrite: `dbt/models/marts/mart_orders_reconciliation.sql`
- Modify: `dbt/tests/marts/assert_reconciliation_variance_recent.sql`

**Interfaces:**
- Consumes: `core_event_economics` (Task 8), `core_bookings` (Task 6), `core_orders`, `core_stripe_transactions` (Task 4); variables `peer_window_days`, `peer_min_count`.
- Produces:
  - `mart_event_performance`: every column of `core_event_economics` plus `peer_count, peer_median_utilisation, peer_median_days_before_at_50pct, peer_median_sns_share_per_available_seat, peer_median_contribution_per_available_seat, utilisation_vs_peers, sns_share_per_seat_vs_peers, contribution_per_seat_vs_peers`.
  - `mart_daily_kpis` gains `net_distributable, sns_share`. `mart_paid_performance` gains `sns_share, sns_contribution`.
  - `mart_orders_reconciliation` gains `platform_era, orders_matched_to_stripe, stripe_match_rate` and covers both eras; `flagged` can only be true for the bronco era.

- [ ] **Step 1: Write the failing unit test**

Create `dbt/models/marts/unit_tests.yml`:

```yaml
unit_tests:
  - name: event_performance_peer_benchmarks
    description: Peers are events in the same metro, category and weekday class in the 365 days before. Fewer than five peers gives no benchmark.
    model: mart_event_performance
    given:
      - input: ref('core_event_economics')
        rows:
          - {event_key: P1, event_date: "2026-08-01", metro_key: m1, category: calligraphy, is_weekend: true, utilisation: 0.5, days_before_at_50pct: 2, sns_share_per_available_seat: 10, contribution_per_available_seat: 8}
          - {event_key: P2, event_date: "2026-08-08", metro_key: m1, category: calligraphy, is_weekend: true, utilisation: 0.6, days_before_at_50pct: 4, sns_share_per_available_seat: 12, contribution_per_available_seat: 9}
          - {event_key: P3, event_date: "2026-08-15", metro_key: m1, category: calligraphy, is_weekend: true, utilisation: 0.7, days_before_at_50pct: 6, sns_share_per_available_seat: 14, contribution_per_available_seat: 10}
          - {event_key: P4, event_date: "2026-08-22", metro_key: m1, category: calligraphy, is_weekend: true, utilisation: 0.8, days_before_at_50pct: 8, sns_share_per_available_seat: 16, contribution_per_available_seat: null}
          - {event_key: P5, event_date: "2026-09-05", metro_key: m1, category: calligraphy, is_weekend: true, utilisation: 0.9, days_before_at_50pct: null, sns_share_per_available_seat: 18, contribution_per_available_seat: 12}
          - {event_key: T1, event_date: "2026-09-12", metro_key: m1, category: calligraphy, is_weekend: true, utilisation: 1.0, days_before_at_50pct: 12, sns_share_per_available_seat: 24, contribution_per_available_seat: 22}
          - {event_key: W1, event_date: "2026-09-09", metro_key: m1, category: calligraphy, is_weekend: false, utilisation: 0.2, days_before_at_50pct: null, sns_share_per_available_seat: 4, contribution_per_available_seat: 3}
          - {event_key: O1, event_date: "2026-09-06", metro_key: m2, category: calligraphy, is_weekend: true, utilisation: 0.1, days_before_at_50pct: null, sns_share_per_available_seat: 2, contribution_per_available_seat: 1}
          - {event_key: OLD, event_date: "2025-09-05", metro_key: m1, category: calligraphy, is_weekend: true, utilisation: 0.1, days_before_at_50pct: 1, sns_share_per_available_seat: 1, contribution_per_available_seat: 1}
    expect:
      rows:
        - {event_key: OLD, peer_count: 0, peer_median_utilisation: null, utilisation_vs_peers: null}
        - {event_key: P1, peer_count: 1, peer_median_utilisation: null, utilisation_vs_peers: null}
        - {event_key: P2, peer_count: 2, peer_median_utilisation: null, utilisation_vs_peers: null}
        - {event_key: P3, peer_count: 3, peer_median_utilisation: null, utilisation_vs_peers: null}
        - {event_key: P4, peer_count: 4, peer_median_utilisation: null, utilisation_vs_peers: null}
        - {event_key: P5, peer_count: 5, peer_median_utilisation: 0.6, utilisation_vs_peers: 0.3}
        - {event_key: T1, peer_count: 5, peer_median_utilisation: 0.7, peer_median_days_before_at_50pct: 5.0, peer_median_sns_share_per_available_seat: 14.0, peer_median_contribution_per_available_seat: 9.5, utilisation_vs_peers: 0.3, sns_share_per_seat_vs_peers: 10.0, contribution_per_seat_vs_peers: 12.5}
        - {event_key: W1, peer_count: 0, peer_median_utilisation: null, utilisation_vs_peers: null}
        - {event_key: O1, peer_count: 0, peer_median_utilisation: null, utilisation_vs_peers: null}
```

What the numbers pin: `T1` (2026-09-12) has peers P1–P5; `OLD` is 372 days earlier, outside the 365-day window. `P5` (2026-09-05) has peers P1–P4 and `OLD` (exactly 365 days earlier, inside the window): utilisations 0.1, 0.5, 0.6, 0.7, 0.8, median 0.6. Medians skip nulls: T1's median days-to-50% is over 2, 4, 6, 8, and its median contribution is over 8, 9, 10, 12.

Run: `cd dbt && ../.venv/bin/dbt test --select event_performance_peer_benchmarks`
Expected: ERROR, model `mart_event_performance` not found.

- [ ] **Step 2: Create `mart_event_performance.sql`**

```sql
-- core_event_economics plus a benchmark against similar events. Together with core_event_daily this
-- answers every question in the first milestone for one event.
with e as (
  select * from {{ ref('core_event_economics') }}
),
pairs as (
  select e.event_key, p.utilisation, p.days_before_at_50pct, p.sns_share_per_available_seat, p.contribution_per_available_seat
  from e
  join e as p
    on p.metro_key = e.metro_key
   and coalesce(p.category, '') = coalesce(e.category, '')
   and p.is_weekend = e.is_weekend
   and p.event_key != e.event_key
   and p.event_date between date_sub(e.event_date, interval {{ var('peer_window_days') }} day) and date_sub(e.event_date, interval 1 day)
),
stats as (
  select distinct event_key,
    count(*) over (partition by event_key) as peer_count,
    percentile_cont(utilisation, 0.5) over (partition by event_key) as median_utilisation,
    percentile_cont(days_before_at_50pct, 0.5) over (partition by event_key) as median_days_before_at_50pct,
    percentile_cont(sns_share_per_available_seat, 0.5) over (partition by event_key) as median_sns_share_per_available_seat,
    percentile_cont(contribution_per_available_seat, 0.5) over (partition by event_key) as median_contribution_per_available_seat
  from pairs
),
peers as (
  select event_key, peer_count,
    if(peer_count >= {{ var('peer_min_count') }}, round(median_utilisation, 6), null) as peer_median_utilisation,
    if(peer_count >= {{ var('peer_min_count') }}, round(median_days_before_at_50pct, 6), null) as peer_median_days_before_at_50pct,
    if(peer_count >= {{ var('peer_min_count') }}, round(median_sns_share_per_available_seat, 6), null) as peer_median_sns_share_per_available_seat,
    if(peer_count >= {{ var('peer_min_count') }}, round(median_contribution_per_available_seat, 6), null) as peer_median_contribution_per_available_seat
  from stats
)
select e.*,
  coalesce(p.peer_count, 0) as peer_count,
  p.peer_median_utilisation, p.peer_median_days_before_at_50pct,
  p.peer_median_sns_share_per_available_seat, p.peer_median_contribution_per_available_seat,
  round(e.utilisation - p.peer_median_utilisation, 6) as utilisation_vs_peers,
  round(e.sns_share_per_available_seat - p.peer_median_sns_share_per_available_seat, 6) as sns_share_per_seat_vs_peers,
  round(e.contribution_per_available_seat - p.peer_median_contribution_per_available_seat, 6) as contribution_per_seat_vs_peers
from e
left join peers p using (event_key)
```

Run: `cd dbt && ../.venv/bin/dbt build --select mart_event_performance`
Expected: the unit test PASSES; model built.

- [ ] **Step 3: Add contribution to `mart_daily_kpis` and `mart_paid_performance`**

In `dbt/models/marts/mart_daily_kpis.sql`:

1. Inside the `o` CTE, add this join after the existing joins and before `group by`:

```sql
  left join (select order_key, sum(net_distributable) as net_distributable, sum(sns_share) as sns_share
             from {{ ref('core_bookings') }} group by order_key) bk using (order_key)
```

2. Add to the `o` CTE's select list: `sum(coalesce(bk.net_distributable, 0)) as net_distributable, sum(coalesce(bk.sns_share, 0)) as sns_share`.
3. Add to the final select list, after `net_revenue`: `coalesce(o.net_distributable, 0) as net_distributable, coalesce(o.sns_share, 0) as sns_share,`.

In `dbt/models/marts/mart_paid_performance.sql`:

1. Replace the `orders_by_session` CTE with:

```sql
orders_by_session as (
  select so.session_key, o.business_date, count(*) as orders, sum(o.seats) as seats, sum(o.net_revenue) as net_revenue,
    sum(coalesce(bk.sns_share, 0)) as sns_share
  from {{ ref('core_session_orders') }} so
  join {{ ref('core_orders') }} o using (order_key)
  left join (select order_key, sum(sns_share) as sns_share from {{ ref('core_bookings') }} group by order_key) bk using (order_key)
  group by 1, 2
),
```

2. In both `google_agg` and `social_agg`, add `sum(coalesce(ob.sns_share, 0)) as sns_share` to the select list.
3. In the final select, add after `net_revenue`:

```sql
  coalesce(g.sns_share, so.sns_share, 0) as sns_share,
  coalesce(g.sns_share, so.sns_share, 0) - sp.spend as sns_contribution,
```

In `dbt/models/marts/schema.yml`, add under `mart_paid_performance` columns:

```yaml
      - name: sns_contribution
        description: "S&S 40% share of bookings from sessions of this campaign, minus the campaign's spend. Session-attributed, so it is not a measure of incrementality. This, not roas, is the decision column."
        data_tests: [not_null]
```

- [ ] **Step 4: Rewrite `mart_orders_reconciliation.sql`**

```sql
{{ config(tags=['hourly']) }}
-- Orders against Stripe, by business day, for both eras. The 1% variance flag applies to the bronco
-- era. For the legacy era the useful number is the share of paid orders that found their Stripe charge.
with charged as (
  select distinct order_key from {{ ref('core_stripe_transactions') }} where source_object = 'charge' and order_key is not null
),
orders as (
  select o.business_date, count(*) as cms_orders, sum(o.net_revenue) as cms_net_revenue,
    countif(o.gross_revenue > 0) as paid_orders,
    countif(o.gross_revenue > 0 and c.order_key is not null) as orders_matched_to_stripe
  from {{ ref('core_orders') }} o
  left join charged c using (order_key)
  group by 1
),
stripe as (
  select business_date, countif(type = 'charge') as stripe_charges, sum(net) as stripe_net, sum(fee) as stripe_fees,
    sum(case when type = 'charge' then amount else 0 end) + sum(case when type in ('refund', 'payment_refund') then amount else 0 end) as stripe_gross_less_refunds
  from {{ ref('core_stripe_transactions') }}
  group by 1
),
joined as (
  select coalesce(o.business_date, s.business_date) as business_date,
    coalesce(o.cms_orders, 0) as cms_orders, coalesce(o.cms_net_revenue, 0) as cms_net_revenue,
    coalesce(o.orders_matched_to_stripe, 0) as orders_matched_to_stripe,
    safe_divide(o.orders_matched_to_stripe, nullif(o.paid_orders, 0)) as stripe_match_rate,
    coalesce(s.stripe_charges, 0) as stripe_charges, coalesce(s.stripe_net, 0) as stripe_net, coalesce(s.stripe_fees, 0) as stripe_fees,
    coalesce(s.stripe_gross_less_refunds, 0) as stripe_gross_less_refunds
  from orders o
  full outer join stripe s using (business_date)
)
select business_date,
  {{ platform_era_of_date('business_date') }} as platform_era,
  cms_orders, cms_net_revenue, orders_matched_to_stripe, stripe_match_rate,
  stripe_charges, stripe_net, stripe_fees, stripe_gross_less_refunds,
  cms_net_revenue - stripe_gross_less_refunds as variance_amount,
  safe_divide(cms_net_revenue - stripe_gross_less_refunds, nullif(stripe_gross_less_refunds, 0)) as variance_pct,
  {{ platform_era_of_date('business_date') }} = 'bronco'
    and coalesce(abs(safe_divide(cms_net_revenue - stripe_gross_less_refunds, nullif(stripe_gross_less_refunds, 0))) > 0.01, false) as flagged
from joined
```

The column names `cms_orders` and `cms_net_revenue` are kept for the Slack brief; in the legacy era they hold archive orders.

In `dbt/tests/marts/assert_reconciliation_variance_recent.sql`, no change is needed if it filters on `flagged`; confirm by reading it. In `dbt/models/marts/schema.yml`, add the `platform_era` column block (from Task 3 Step 3) under `mart_orders_reconciliation`, and add a new model entry:

```yaml
  - name: mart_event_performance
    description: "One row per event with outcomes, pace, contribution and peer benchmarks. Join to core.core_event_daily on event_key for the booking curve."
    columns:
      - name: event_key
        data_tests: [unique, not_null]
      - name: peer_count
        data_tests: [not_null]
```

- [ ] **Step 5: Build everything from clean**

Run: `cd dbt && ../.venv/bin/dbt build`
Expected: every model builds; every unit test and error-severity data test passes; warnings are listed by name. `assert_no_pre_launch_column` passes.

- [ ] **Step 6: Commit**

```bash
git add dbt/models/marts/mart_event_performance.sql dbt/models/marts/unit_tests.yml dbt/models/marts/mart_daily_kpis.sql dbt/models/marts/mart_paid_performance.sql dbt/models/marts/mart_orders_reconciliation.sql dbt/models/marts/schema.yml
git commit -m "feat(dbt): event performance mart with peer benchmarks; contribution in KPI and paid marts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: ECON-001 validation and acceptance

This task proves the numbers against sources outside the model, pins them, and records coverage. It needs the CMS export loaded (base task 16) and the Stripe history loaded (Task 2).

**Files:**
- Create: `scripts/econ_check_order.py`
- Create: `dbt/tests/core/assert_worked_order.sql`, `dbt/tests/core/assert_worked_event.sql`, `dbt/tests/assert_no_pii_columns.sql`
- Modify: `dbt/dbt_project.yml` (fee variables)
- Create: `docs/econ-001-validation.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: every model above; the Stripe API through `STRIPE_RESTRICTED_KEY`.
- Produces: `scripts/econ_check_order.py <order_number>` prints one JSON line `{"order_number", "charged", "refunded", "fee", "charges"}` in dollars, computed from Stripe alone.

- [ ] **Step 1: Write the independent Stripe check**

This script shares no code with the loader or dbt, which is the point: it is a second opinion. It prints amounts only.

Create `scripts/econ_check_order.py`:

```python
"""Second opinion on one bronco order, straight from Stripe. Prints amounts only, never personal data.

Usage: set -a; . ~/.config/sns-analytics/env; set +a; .venv/bin/python scripts/econ_check_order.py SNS-26-000123
"""
from __future__ import annotations

import json
import os
import re
import sys

import stripe


def check(order_number: str) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9-]+", order_number):
        raise SystemExit("order number must be letters, digits and dashes")
    stripe.api_key = os.environ["STRIPE_RESTRICTED_KEY"]
    charged = refunded = fee = 0
    charges = 0
    found = stripe.Charge.search(query=f"metadata['OrderNumber']:'{order_number}'", limit=100)
    for charge in found.auto_paging_iter():
        if charge["status"] != "succeeded":
            continue
        charges += 1
        charged += charge["amount"]
        refunded += charge["amount_refunded"]
        for txn in stripe.BalanceTransaction.list(source=charge["id"], limit=100).auto_paging_iter():
            fee += txn["fee"]
        for refund in stripe.Refund.list(charge=charge["id"], limit=100).auto_paging_iter():
            if refund.get("balance_transaction"):
                fee += stripe.BalanceTransaction.retrieve(refund["balance_transaction"])["fee"]
    return {"order_number": order_number, "charges": charges, "charged": charged / 100, "refunded": refunded / 100, "fee": fee / 100}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    print(json.dumps(check(sys.argv[1])))
```

Run: `.venv/bin/ruff check scripts/econ_check_order.py`
Expected: `All checks passed!`

- [ ] **Step 2: Choose the worked order and compute its economics by hand**

Pick a settled bronco order with two tickets and a discount, which exercises allocation:

```bash
cd dbt && ../.venv/bin/dbt show --limit 5 --inline "select o.order_key, o.order_number, o.business_date, count(*) items, sum(b.seats) seats, round(sum(b.list_value),2) list_value, round(sum(b.discount),2) discount, round(sum(b.service_fee),2) service_fee, round(sum(b.realized_revenue),2) realized, round(sum(b.refunded_amount),2) refunded, round(sum(b.processing_fee),2) fee, round(sum(b.net_distributable),2) net, round(sum(b.sns_share),2) sns_share from {{ ref('core_bookings') }} b join {{ ref('core_orders') }} o using (order_key) where b.platform_era = 'bronco' and b.fee_source = 'actual' and o.business_date between '2026-08-01' and '2026-09-15' and o.discount > 0 and o.gift_card_applied = 0 group by 1,2,3 having count(*) = 2 and sum(b.refunded_amount) = 0 order by o.business_date limit 5"
```

Take the first row. Then, from the repo root, ask Stripe about the same order:

```bash
set -a; . ~/.config/sns-analytics/env; set +a
.venv/bin/python scripts/econ_check_order.py <order_number from the row>
```

Work the economics by hand from the Stripe output, with a calculator and not with SQL: `realized = charged`, `net = charged − refunded − fee`, `sns_share = 0.40 × net`, `instructor_share = 0.60 × net`. The model's `realized`, `fee`, `net` and `sns_share` for that order must equal the hand figures to the cent. If they do not, stop: this is the defect ECON-001 exists to find. Report the order number, both sets of figures and the difference, and do not pin anything.

- [ ] **Step 3: Pin the worked order**

Create `dbt/tests/core/assert_worked_order.sql`, substituting the four values from Step 2 (`order_key` from the first query; the three amounts from the hand calculation):

```sql
-- ECON-001 worked order. Amounts were computed by hand from Stripe on the date in docs/econ-001-validation.md.
-- The order is identified by its key only; no personal data is recorded.
{% set order_key = 'ORDER_KEY_FROM_STEP_2' %}
{% set expected_fee = 0.00 %}
{% set expected_net = 0.00 %}
{% set expected_sns_share = 0.00 %}
with got as (
  select round(sum(processing_fee), 2) as fee, round(sum(net_distributable), 2) as net, round(sum(sns_share), 2) as sns_share, count(*) as n
  from {{ ref('core_bookings') }}
  where order_key = '{{ order_key }}'
)
select * from got
where n = 0
   or abs(fee - {{ expected_fee }}) > 0.01
   or abs(net - {{ expected_net }}) > 0.01
   or abs(sns_share - {{ expected_sns_share }}) > 0.01
```

The four `set` lines are the only lines to edit. With the literal text `ORDER_KEY_FROM_STEP_2` left in place the test fails on `n = 0`, which is the intended failing state.

Run: `cd dbt && ../.venv/bin/dbt test --select assert_worked_order`
Expected before substituting: FAIL (1 row, `n = 0`). After substituting: PASS.

- [ ] **Step 4: Choose and pin the worked event**

Pick a sold-out legacy event with at least ten bookings, and count its seats from the archive directly, bypassing every core model:

```bash
../.venv/bin/dbt show --limit 3 --inline "select event_key, wordpress_source_id, event_date, capacity, seats_sold, round(realized_revenue,2) realized, days_before_at_sellout, first_sale_days_before from {{ ref('core_event_economics') }} where platform_era = 'legacy_event_tickets' and event_key like 'woo-ev-%' and sold_out and bookings >= 10 and refunded_amount = 0 and event_date between '2024-03-01' and '2024-10-31' order by event_date limit 3"
```

Take the first row, then run the independent count with its `wordpress_source_id`:

```bash
../.venv/bin/dbt show --limit 100 --inline "select date(o.date_created_gmt, 'America/New_York') d, sum(li.quantity) seats, round(sum(li.total),2) revenue from {{ source('woo','order_line_items') }} li join {{ source('woo','products') }} p on p.id = li.product_id join {{ source('woo','orders') }} o on o.id = li.order_id where p.tribe_wooticket_for_event = <wordpress_source_id> and o.status in ('completed','refunded') group by 1 order by 1"
```

Add the daily seats up by hand. The total must equal `seats_sold`; the revenue total must equal `realized`; the first date must be `first_sale_days_before` days before the event; the date on which the running total first reaches `capacity` must be `days_before_at_sellout` days before the event. If `date_paid_gmt` differs from `date_created_gmt` by a day for some orders the dates can be off by one; the model uses the paid time when present, so recompute with `coalesce(o.date_paid_gmt, o.date_created_gmt)` before treating a difference as a defect.

Create `dbt/tests/core/assert_worked_event.sql`, substituting the five hand-derived values:

```sql
-- ECON-001 worked event, counted by hand from the archive tables.
{% set event_key = 'EVENT_KEY_FROM_STEP_4' %}
{% set expected_seats = 0 %}
{% set expected_realized = 0.00 %}
{% set expected_first_sale_days_before = 0 %}
{% set expected_days_before_at_sellout = 0 %}
with got as (
  select seats_sold, round(realized_revenue, 2) as realized, first_sale_days_before, days_before_at_sellout, sold_out
  from {{ ref('core_event_economics') }}
  where event_key = '{{ event_key }}'
)
select 'missing' as problem from (select count(*) as n from got) where n = 0
union all
select 'mismatch' from got
where seats_sold != {{ expected_seats }}
   or abs(realized - {{ expected_realized }}) > 0.01
   or first_sale_days_before != {{ expected_first_sale_days_before }}
   or days_before_at_sellout != {{ expected_days_before_at_sellout }}
   or not sold_out
```

Run: `../.venv/bin/dbt test --select assert_worked_event`
Expected before substituting: FAIL (`missing`). After substituting: PASS.

- [ ] **Step 5: Reset the legacy fee estimate from observed data**

```bash
../.venv/bin/dbt show --inline "select count(*) charges, round(sum(fee),2) fees, round(sum(amount),2) amount, round(safe_divide(sum(fee) - 0.30 * count(*), sum(amount)), 4) implied_rate from {{ ref('core_stripe_transactions') }} where type = 'charge' and platform_era = 'legacy_event_tickets' and match_method in ('woo_metadata','woo_description') and amount > 0"
```

In `dbt/dbt_project.yml`, set `legacy_fee_rate` to the `implied_rate` printed. Leave `legacy_fee_fixed: 0.30`. If `implied_rate` is outside 0.020–0.040, do not change the variable; record the figure in the validation document as unexplained.

Run: `../.venv/bin/dbt build --select core_order_item_economics+`
Expected: all pass. The `order_item_economics_legacy` unit test passes unchanged only if the rate is still 0.029; if the rate changed, add `overrides: {vars: {legacy_fee_rate: 0.029, legacy_fee_fixed: 0.30}}` to that unit test and to `order_item_economics_bronco_split` and `order_item_economics_zero_value_order` so their expectations stay fixed, then rebuild.

- [ ] **Step 6: Scan for personal data columns**

`dbt/tests/assert_no_pii_columns.sql`:

```sql
-- No dataset the pipeline writes may hold a column that looks like personal data.
select table_schema, table_name, column_name
from `{{ target.project }}`.`region-us`.INFORMATION_SCHEMA.COLUMNS
where table_schema in ('staging', 'core', 'mart', 'ops')
  and regexp_contains(lower(column_name), r'(e_?mail|phone|first_?name|last_?name|full_?name|street|address|card|last4|purchaser|attendee)')
```

Run: `../.venv/bin/dbt test --select assert_no_pii_columns assert_no_email_in_raw_stripe`
Expected: both PASS. Instructor and venue `name` columns are business names that the public site shows and are allowed; they do not match the pattern.

- [ ] **Step 7: Answer the milestone for the worked event in one query**

```bash
../.venv/bin/dbt show --limit 1 --inline "select p.title, p.event_date, p.weekday, p.start_hour_local, v.name venue, v.city, v.state, m.name metro, i.name instructor, p.platform_era, p.capacity, p.ticket_price, p.seats_sold, p.customers, p.utilisation, p.sold_out, p.first_sale_days_before, p.days_before_at_50pct, p.days_before_at_sellout, p.realized_revenue, p.processing_fee, p.net_distributable, p.sns_share, p.instructor_share, p.allocated_ad_spend, p.sns_contribution, p.sns_share_per_available_seat, p.peer_count, p.peer_median_utilisation, p.utilisation_vs_peers, p.sns_share_per_seat_vs_peers from {{ ref('mart_event_performance') }} p left join {{ ref('core_venues') }} v using (venue_key) left join {{ ref('core_metros') }} m on m.metro_key = p.metro_key left join {{ ref('core_instructors') }} i using (instructor_key) where p.event_key = '<worked event key>'"
../.venv/bin/dbt show --limit 120 --inline "select snapshot_date, days_until_event, seats_sold_that_day, cumulative_seats, pct_sold, cumulative_realized_revenue, cumulative_sns_share from {{ ref('core_event_daily') }} where event_key = '<worked event key>' order by snapshot_date"
```

Expected: one row with no unexpected nulls (ad spend and contribution are null for a 2024 event unless spend history was loaded), and a curve that rises to `seats_sold`.

- [ ] **Step 8: Write the validation record**

Create `docs/econ-001-validation.md` with these sections, filled from the outputs kept in Task 4 Step 7, Task 5 Step 6, Task 6 Step 7, Task 8 Step 7 and this task. Identify orders and events by key only.

```markdown
# ECON-001 validation

Date run:
Commit:

## Rules validated
The eight rules in the addendum spec §2, each marked confirmed or contradicted by the worked order.

## Worked order
Order key, business date, seats. Table: figure | from Stripe by hand | from core_bookings | difference.
Rows: charged, refunded, Stripe fee, net distributable, S&S share (40%), instructor share (60%).

## Worked event
Event key, date, capacity. Table: figure | counted by hand from the archive | from core_event_economics.
Rows: seats sold, realized revenue, first sale (days before), sellout (days before).
The one-row milestone answer and the booking curve from Step 7.

## Coverage
Identity resolution by year and era (Task 4 Step 7).
Stripe match method by year (Task 4 Step 7).
Fee source share by year and era.
Events by year with capacity, venue, metro, instructor (Task 5 Step 6).
Bookings vs core_orders for 2026-06-23..09-17, with the gift card amount that explains any gap (Task 6 Step 7).

## Success criteria (addendum spec §10)
Each of the five criteria: met or not met, with the number.

## Legacy fee estimate
Implied rate, the value set in dbt_project.yml, and the count of bookings it applies to.

## Warnings outstanding
Every dbt test that finished with a warning, by name, with its row count.

## Known limits observed
Anything from the addendum spec §9 that the data confirmed, with counts.
```

In `README.md`, add a section named `Economics` with: the five formulae from Global Constraints; the sentence "Materials are paid by instructors from their share and are never subtracted from S&S figures."; the list of the new tables with one line each; and a pointer to `docs/econ-001-validation.md`.

- [ ] **Step 9: Final build and commit**

Run: `cd dbt && ../.venv/bin/dbt build && cd .. && .venv/bin/pytest -q && .venv/bin/ruff check loaders tests scripts`
Expected: dbt finishes with no errors; pytest all pass; ruff clean.

```bash
git add scripts/econ_check_order.py dbt/tests/core/assert_worked_order.sql dbt/tests/core/assert_worked_event.sql dbt/tests/assert_no_pii_columns.sql dbt/dbt_project.yml dbt/models/core/unit_tests.yml docs/econ-001-validation.md README.md
git commit -m "test: ECON-001 worked order and event pinned; coverage and success criteria recorded

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Transferred seats

Runs BEFORE Task 10. Implements addendum spec §6.8, which holds the definitions and the nine rules; read it first.

**Files:**
- Modify: `dbt/models/staging/woo/stg_woo__orders.sql` (expose `parent_order_key`)
- Create: `dbt/models/core/core_seat_transfers.sql`
- Modify: `dbt/models/core/core_customer_identity.sql`, `core_orders.sql`, `core_order_item_economics.sql`, `core_bookings.sql`, `core_customers.sql`
- Modify: `dbt/models/marts/mart_daily_kpis.sql`
- Modify: `dbt/models/core/unit_tests.yml`, `dbt/models/core/schema.yml`, `dbt/models/marts/mart_daily_kpis_unit_tests.yml`, `dbt/models/marts/schema.yml`
- Create: `dbt/tests/core/assert_transfers_conserve_money.sql`, `dbt/tests/core/assert_transfer_seats_within_purchase.sql`
- Modify: `docs/runbook.md`, `docs/looker-studio.md`

**Interfaces:**
- Consumes: `stg_woo__orders` (`order_key, woo_order_id, status, total, created_at, paid_at`), `stg_woo__order_line_items`, `stg_woo__products`, `core_events`, `core_stripe_transactions`, `core_customer_identity`.
- Produces:
  - `stg_woo__orders.parent_order_key`: `woo-<parent_id>` or NULL when the archive's `parent_id` is 0 or NULL.
  - `core_seat_transfers`, grain one ticket line of a transfer order: `order_item_key, order_key, root_order_key, event_key, transferred_at, seats, seats_held, is_superseded, depth`. `root_order_key` is NULL when no paid ancestor exists. `seats_held` is 0 when superseded or rootless.
  - `core_order_item_economics` and `core_bookings` gain `booking_kind`, `seats_purchased`, `seats_transferred_out`, `transfer_root_order_key`. On a root line `seats` = `seats_purchased − seats_transferred_out`. On a `transfer_in` line `seats` = `seats_held`.
  - `core_orders` gains `is_transfer BOOL NOT NULL`, `transfer_root_order_key`.
  - `core_customer_identity.identity_source` gains `transfer_parent`.

**Unit tests to write first.** All on `core_order_item_economics` unless stated. Every expected row in a test carries the same column keys. Rates: shares 0.40 and 0.60.

| Case | Fixture | Expected |
|---|---|---|
| A, one of two seats moved | Root R1: total 140, one ticket line, 2 seats, line total 140, event E1, Stripe charge fee 4.36. Transfer C1: parent R1, total 0, one line, 1 seat, line value 70, event E2. | R1 line: `purchase`, seats_purchased 2, seats_transferred_out 1, seats 1, realized 70, fee 2.18, net 67.82, shares 27.128 and 40.692. C1 line: `transfer_in`, seats 1, realized 70, fee 2.18, `fee_source` actual, net 67.82, shares 27.128 and 40.692, event E2, root R1. |
| B, price differs | Root R2: total 130, 2 seats, line total 130, E1, fee 4.07. Transfers C2a and C2b: parent R2, 1 seat each, line value 80, event E3. | R2 line: seats 0, realized 0, fee 0, net 0, seats_transferred_out 2. Each transfer: realized 65, fee 2.035, net 62.965, shares 25.186 and 37.779. |
| C, moved twice from the same order | Root R3: total 70, 1 seat, E1, fee 2.33. C3a created day 5 on E2 and C3b created day 9 on E4, both with parent R3. | C3b: `transfer_in`, seats 1, realized 70, fee 2.33, net 67.67. C3a: `transfer_superseded`, seats 0, realized 0, fee 0, cancelled. R3 line: seats 0, realized 0. |
| D, chain | Root R4: total 70, 1 seat, fee 2.33. C4a parent R4 on E2, created day 5. C4b parent C4a on E5, created day 9. | C4b holds the seat and the money, root R4. C4a superseded. |
| E, no paid ancestor | Order U1: total 0, no parent, 1 seat, line value 65. Order U2: total 0, parent U1, 1 seat, line value 65. | Both `unpaid_zero_total`, realized 65, fee 0, `fee_source` none, seats 1. |
| F, root refunded | Root R5: total 70, 1 seat, fee 2.33, Stripe refund 70. Transfer C5 parent R5. | C5: realized 70, refunded 70, fee 2.33, net −2.33, cancelled. R5 line: all zero, seats 0. |
| G, two lines on the root | Root R6: total 135, line a (key sorts first) 1 seat 70 on E1, line b 1 seat 65 on E6, fee 4.22. Transfer C6: 1 seat. | C6 takes the seat from line a: realized 70, fee 4.22 × 70 / 135. Line a: seats 0, all zero. Line b unchanged: realized 65, fee 4.22 × 65 / 135. |

Further unit tests: `core_customer_identity` (a transfer order takes its root's customer with `identity_source: transfer_parent`; a rootless one resolves as any other order); `core_orders` (`is_transfer` true for transfer orders, false otherwise; a transfer is never `is_first_order`); `core_customers` (a customer with one purchase and two transfers has `lifetime_orders: 1`, `is_repeat: false`, and `lifetime_seats`, `lifetime_events` and money from the bookings that hold seats); `mart_daily_kpis` (a transfer order adds nothing to `orders`, `ticket_orders`, `seats`, `gross_revenue`; its moved `sns_share` is reported on the transfer's business date).

**Data tests.**
- `assert_transfers_conserve_money.sql`: for every root, realized revenue, refunded amount and processing fee summed over the root's lines and its transfer bookings equal the same sums computed for the root's lines directly from staging and Stripe, within one cent.
- `assert_transfer_seats_within_purchase.sql`: for every root, seats held by transfers plus seats remaining on its lines equal the seats it bought; no line has negative seats.
- Existing tests must still pass: `assert_shares_sum_to_net`, `assert_allocation_conserves_money` (adapt its legacy branches so they compare per root family where a transfer is involved), `assert_curve_closes`, `assert_event_economics_matches_bookings`, `assert_daily_kpis_conserves_totals`.

**Report from real data**, counts and sums only, before and after: legacy realized revenue, S&S share and net seats by year; sold-out events by year; customers, repeat customers and the distribution of lifetime orders; bookings by `booking_kind`; unresolved identity by year.

**Commit** by explicit path.

---

## Out of scope for this plan

- The descriptive analyses (sellouts, underutilisation, booking-curve pace bands, retention cohorts, marketing economics). They are queries over the tables built here and get their own spec.
- The Opportunity register, forecasting models, any interface, Klaviyo, Meta and Pinterest API loaders.
- Any change to the CMS export API. `checkoutSessionKey` and `orderNumber` are already exported on orders.
