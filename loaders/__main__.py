"""python -m loaders run --sources cms,stripe,gsc,spend [--full] [--mode daily|hourly]"""
from __future__ import annotations

import argparse
import collections
import os
import sys

from google.cloud import bigquery

from loaders.common.bq import RawWriter
from loaders.common.config import OPS, RAW_CMS, RAW_GSC, RAW_SPEND, RAW_STRIPE, Settings
from loaders.common.slack import post_status
from loaders.common.state import LoadState, StepResult

ALL = ["cms", "stripe", "gsc", "spend"]


def parse_args(argv):
    p = argparse.ArgumentParser(prog="loaders")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--sources", default=",".join(ALL), type=lambda s: [x for x in s.split(",") if x])
    r.add_argument("--full", action="store_true")
    r.add_argument("--mode", choices=["daily", "hourly"], default="daily")
    return p.parse_args(argv)


def summarise(results: list[StepResult]) -> str:
    per = collections.OrderedDict()
    for r in results:
        per[r.step.split(".")[0]] = per.get(r.step.split(".")[0], 0) + r.rows
    parts = [f"{k} {v:,}" for k, v in per.items()]
    errors = [f"⚠ {r.step}: {r.message.splitlines()[0]}" for r in results if r.status == "error"]
    return "sns-analytics loaders: " + " · ".join(parts) + ("\n" + "\n".join(errors) if errors else "")


def main(argv=None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    settings = Settings.from_env(os.environ)
    client = bigquery.Client(project=settings.project, location=settings.location)
    writer = RawWriter(client, settings.project, settings.run_id, settings.location)
    for ds in (RAW_CMS, RAW_STRIPE, RAW_GSC, RAW_SPEND, OPS):
        writer.ensure_dataset(ds)
    state = LoadState(client, settings.project); state.ensure()

    results: list[StepResult] = []
    if "cms" in args.sources:
        from loaders.cms import load_cms
        results += load_cms(settings, writer, state, full=args.full, mode=args.mode)
    if "stripe" in args.sources:
        from loaders.stripe_loader import load_stripe
        results += load_stripe(settings, writer, state, full=args.full)
    if "gsc" in args.sources:
        from loaders.gsc import load_gsc
        results += load_gsc(settings, writer, state, full=args.full)
    if "spend" in args.sources:
        from loaders.spend_csv import load_spend_csv
        results += load_spend_csv(settings, writer, state)

    text = summarise(results)
    print(text)
    if any(r.status == "error" for r in results):
        post_status(settings, text)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
