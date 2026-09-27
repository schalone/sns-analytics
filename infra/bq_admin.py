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
