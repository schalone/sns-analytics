"""Dataset administration over the BigQuery API with Application Default Credentials.

Usage:
  python infra/bq_admin.py datasets
      create every pipeline dataset in the US multi-region (idempotent)
  python infra/bq_admin.py grant DATASET ROLE MEMBER
      give MEMBER (an email: service account or user) ROLE on DATASET, idempotently.
      ROLE is a BigQuery predefined role such as roles/bigquery.dataEditor or roles/bigquery.dataViewer.
      The bq CLI's add-iam-policy-binding does not support datasets ("requires allowlisting"), so
      infra/setup.sh uses this instead.
"""
import sys

from google.cloud import bigquery

PROJECT, LOCATION = "sipandscript", "US"
DATASETS = ["raw_cms", "raw_stripe", "raw_gsc", "raw_spend", "google_ads", "ops", "staging", "core", "mart"]


def create_datasets(client: bigquery.Client) -> None:
    for d in DATASETS:
        ds = bigquery.Dataset(f"{PROJECT}.{d}")
        ds.location = LOCATION
        client.create_dataset(ds, exists_ok=True)
        print("ok", d)


def grant(client: bigquery.Client, dataset: str, role: str, member: str) -> None:
    ds = client.get_dataset(f"{PROJECT}.{dataset}")
    entries = list(ds.access_entries)
    for e in entries:
        if e.role == role and e.entity_type == "userByEmail" and e.entity_id == member:
            print("already", dataset, role, member)
            return
    entries.append(bigquery.AccessEntry(role=role, entity_type="userByEmail", entity_id=member))
    ds.access_entries = entries
    client.update_dataset(ds, ["access_entries"])
    print("granted", dataset, role, member)


if __name__ == "__main__":
    args = sys.argv[1:]
    c = bigquery.Client(project=PROJECT)
    if args == ["datasets"]:
        create_datasets(c)
    elif len(args) == 4 and args[0] == "grant":
        grant(c, args[1], args[2], args[3])
    else:
        raise SystemExit(__doc__)
