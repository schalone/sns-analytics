"""Create the empty raw tables (key/updated_at/payload/_loaded_at/_run_id) so dbt staging
views compile before any loader has run against real sources. Idempotent: ensure_table()
is a no-op if the table already exists.

Usage: python infra/create_raw_tables.py
"""
from google.cloud import bigquery

from loaders.common.bq import RawWriter

PROJECT, LOCATION = "sipandscript", "US"

ENTITIES = {
    "raw_cms": [
        "orders", "order_items", "tickets", "refunds", "promo_redemptions",
        "gift_cards", "gift_card_transactions", "checkout_sessions",
        "events", "venues", "metros", "instructors",
    ],
    "raw_stripe": ["balance_transactions", "refunds", "disputes", "payouts"],
    "raw_gsc": ["totals", "page", "device_country", "page_query"],   # page_device_country (dropped, I18) keeps its data but is no longer loaded
    "raw_spend": ["meta", "pinterest"],
}

if __name__ == "__main__":
    writer = RawWriter(bigquery.Client(project=PROJECT, location=LOCATION), PROJECT, "bootstrap", LOCATION)
    for dataset, entities in ENTITIES.items():
        writer.ensure_dataset(dataset)
        for entity in entities:
            writer.ensure_table(dataset, entity)
            print("ok", dataset, entity)
