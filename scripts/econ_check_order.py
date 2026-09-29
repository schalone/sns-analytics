"""Second opinion on one order, straight from Stripe. Prints amounts only, never personal data.

This script shares no code with the loader or dbt, which is the point: it is a second opinion,
not a rendering of the same logic twice.

Usage:
  set -a; . ~/.config/sns-analytics/env; set +a
  .venv/bin/python scripts/econ_check_order.py --bronco SNS-26-000123
  .venv/bin/python scripts/econ_check_order.py --legacy 70123
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

import stripe

ORDER_NUMBER_RE = re.compile(r"^[A-Za-z0-9-]+$")
ORDER_ID_RE = re.compile(r"^[0-9]+$")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--bronco", metavar="ORDER_NUMBER", help="bronco order number (metadata OrderNumber)")
    group.add_argument("--legacy", metavar="WOO_ORDER_ID", help="legacy WooCommerce order id (metadata order_id)")
    return parser.parse_args(argv)


def build_query(args: argparse.Namespace) -> str:
    if args.bronco is not None:
        if not ORDER_NUMBER_RE.fullmatch(args.bronco):
            raise SystemExit("order number must be letters, digits and dashes")
        return f"metadata['OrderNumber']:'{args.bronco}'"
    if not ORDER_ID_RE.fullmatch(args.legacy):
        raise SystemExit("order id must be digits only")
    return f"metadata['order_id']:'{args.legacy}'"


def check(query: str) -> dict[str, float | int]:
    stripe.api_key = os.environ["STRIPE_RESTRICTED_KEY"]
    charged = refunded = fee = refund_fee = 0
    charges = 0
    found = stripe.Charge.search(query=query, limit=100)
    for charge in found.auto_paging_iter():
        if charge["status"] != "succeeded":
            continue
        charges += 1
        charged += charge["amount"]
        refunded += charge["amount_refunded"]
        for txn in stripe.BalanceTransaction.list(source=charge["id"], limit=100).auto_paging_iter():
            fee += txn["fee"]
        for refund in stripe.Refund.list(charge=charge["id"], limit=100).auto_paging_iter():
            balance_transaction = refund.to_dict().get("balance_transaction")
            if balance_transaction:
                this_fee = stripe.BalanceTransaction.retrieve(balance_transaction)["fee"]
                fee += this_fee
                refund_fee += this_fee
    # refund_fee is the part of fee carried by refund balance transactions (Stripe usually keeps the
    # charge's fee on a refund and charges nothing more, so it is usually zero).
    return {
        "charges": charges,
        "charged": charged / 100,
        "refunded": refunded / 100,
        "fee": fee / 100,
        "refund_fee": refund_fee / 100,
    }


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    query = build_query(args)
    try:
        result = check(query)
    except stripe.error.StripeError as exc:
        print(json.dumps({"error": type(exc).__name__, "code": getattr(exc, "code", None)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
