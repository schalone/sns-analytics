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
