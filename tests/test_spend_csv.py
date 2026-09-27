import datetime as dt

from loaders.common.bq import RawWriter
from loaders.common.config import Settings
from loaders.common.state import LoadState
from loaders.spend_csv import load_spend_csv, normalise_header, parse_csv
from tests.fakes import FakeBqClient, FakeBucketBlob, FakeStorageClient

META = "Day,Campaign name,Amount spent (USD),Impressions,Link clicks\n2026-09-25,SNS | Paid Social | Dallas,42.10,5000,120\n"
PIN = "Date,Campaign,Spend,Impressions,Pin clicks\n2026-09-25,Fall Classes,10.00,800,15\n"


def test_normalise_header_maps_platform_variants():
    assert normalise_header("Amount spent (USD)") == "spend" and normalise_header("Link clicks") == "clicks"
    assert normalise_header("Day") == "date" and normalise_header("Campaign") == "campaign_name" and normalise_header("Pin clicks") == "clicks"


def test_parse_csv_builds_rows():
    rows = parse_csv("meta", "spend/meta/sep.csv", META, generation=17)
    assert len(rows) == 1 and rows[0].payload == {"platform": "meta", "file": "spend/meta/sep.csv", "date": "2026-09-25", "campaign_name": "SNS | Paid Social | Dallas", "spend": 42.1, "impressions": 5000, "clicks": 120}


def test_parse_csv_missing_column_raises():
    import pytest
    with pytest.raises(ValueError, match="clicks"):
        parse_csv("meta", "f.csv", "Day,Campaign name,Amount spent (USD),Impressions\n2026-09-25,x,1,2\n", generation=1)


def test_parse_csv_strips_leading_bom():
    rows = parse_csv("meta", "spend/meta/sep.csv", "﻿" + META, generation=17)
    assert len(rows) == 1
    assert rows[0].payload["date"] == "2026-09-25" and rows[0].payload["campaign_name"] == "SNS | Paid Social | Dallas"


def test_parse_csv_tolerates_currency_symbols_and_thousands_separators():
    text = ("Day,Campaign name,Amount spent (USD),Impressions,Link clicks\n"
            '2026-09-25,SNS | Paid Social | Dallas,"$1,234.56","12,000","1,050"\n')
    rows = parse_csv("meta", "spend/meta/sep.csv", text, generation=17)
    assert len(rows) == 1
    assert rows[0].payload["spend"] == 1234.56
    assert rows[0].payload["impressions"] == 12000
    assert rows[0].payload["clicks"] == 1050


def test_spend_skip_same_generation_reload_new_generation():
    bq = FakeBqClient(); s = Settings.from_env({"CMS_BASE_URL": "x"})
    blobs = [FakeBucketBlob("spend/meta/sep.csv", 17, META), FakeBucketBlob("spend/pinterest/sep.csv", 5, PIN)]
    # first file already loaded at generation 17; second never loaded
    # FakeBqClient answers every query (watermark reads AND run_log inserts) from one queue, in call order:
    # list.meta log, meta get, meta log, list.pinterest log, pinterest get (none)
    bq.query_results.extend([[], [{"watermark": dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc), "cursor": "17"}], [], [], []])
    res = load_spend_csv(s, RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), storage=FakeStorageClient(blobs))
    assert [(r.step, r.rows) for r in res] == [("spend.list.meta", 1), ("spend.spend/meta/sep.csv", 0),
                                               ("spend.list.pinterest", 1), ("spend.spend/pinterest/sep.csv", 1)]
    # now meta file re-exported: new generation 18 -> reload
    bq2 = FakeBqClient(); bq2.query_results.extend([[], [{"watermark": dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc), "cursor": "17"}]])
    res2 = load_spend_csv(s, RawWriter(bq2, "sipandscript", "r"), LoadState(bq2, "sipandscript"), storage=FakeStorageClient([FakeBucketBlob("spend/meta/sep.csv", 18, META)]))
    assert res2[1].rows == 1


# --------------------------------------------------------------------------- final-review I9 / I10 ---
import pytest  # noqa: E402

from loaders.spend_csv import _num, normalise_date, parse_csv_counted  # noqa: E402

HEAD = "Day,Campaign name,Amount spent (USD),Impressions,Link clicks\n"


@pytest.mark.parametrize("raw,iso", [("2026-09-05", "2026-09-05"), ("9/5/2026", "2026-09-05"), ("09/05/2026", "2026-09-05"),
                                     ("2026/09/05", "2026-09-05"), ("2026-9-5", "2026-09-05")])
def test_normalise_date_accepts_the_four_export_formats(raw, iso):
    assert normalise_date(raw) == iso


def test_parse_csv_writes_iso_date_and_keys_on_it():
    us = parse_csv("meta", "f.csv", HEAD + "9/25/2026,Dallas,1.00,10,1\n", generation=1)
    iso = parse_csv("meta", "f.csv", HEAD + "2026-09-25,Dallas,1.00,10,1\n", generation=1)
    assert us[0].payload["date"] == "2026-09-25" and us[0].key == iso[0].key


@pytest.mark.parametrize("bad", ["25/09/2026", "Sep 25, 2026", "2026-13-01", "26-09-25"])
def test_unparseable_date_rejects_the_whole_file_naming_file_row_and_value(bad):
    text = HEAD + "2026-09-24,Dallas,1.00,10,1\n" + f"\"{bad}\",Dallas,1.00,10,1\n"
    with pytest.raises(ValueError) as e:
        parse_csv("meta", "spend/meta/sep.csv", text, generation=1)
    msg = str(e.value)
    assert "spend/meta/sep.csv" in msg and "row 3" in msg and repr(bad) in msg


def test_rows_with_empty_campaign_name_are_skipped_and_counted():
    text = HEAD + "2026-09-25,Dallas,1.00,10,1\n,,1.00,10,1\n2026-09-25,,5.00,50,5\n"
    rows, skipped = parse_csv_counted("meta", "f.csv", text, generation=1)
    assert len(rows) == 1 and skipped == 2


@pytest.mark.parametrize("bad", ["12,5", "1.234,56", "(12.00)", "$(5.00)"])
def test_num_rejects_decimal_comma_and_accounting_negatives(bad):
    with pytest.raises(ValueError):
        _num(bad)


def test_num_keeps_us_thousands_separators():
    assert _num("$1,234.56") == 1234.56 and _num("12,000") == 12000 and _num("1,000,000") == 1_000_000 and _num("") == 0.0


def test_decimal_comma_rejects_the_file_naming_row():
    with pytest.raises(ValueError, match=r"f\.csv: row 2: .*'12,5'"):
        parse_csv("meta", "f.csv", HEAD + '2026-09-25,Dallas,"12,5",10,1\n', generation=1)


class _MemState:
    def __init__(self): self.logs = []; self.marks = {}
    def get(self, source, entity): return self.marks.get(entity)
    def set(self, source, entity, updated_at, cursor=None): self.marks[entity] = None
    def log(self, run_id, step, status, rows, message=""): self.logs.append((step, status, rows, message))


class _DeniedStorage:
    def list_blobs(self, bucket, prefix=""):
        raise PermissionError(f"403 storage.objects.list denied on {bucket}")


def test_listing_failure_is_a_step_error_per_platform_not_an_exception():
    s = Settings.from_env({"CMS_BASE_URL": "x"}); st = _MemState()
    res = load_spend_csv(s, RawWriter(FakeBqClient(), "sipandscript", "r"), st, storage=_DeniedStorage())
    assert [(r.step, r.status) for r in res] == [("spend.list.meta", "error"), ("spend.list.pinterest", "error")]
    assert "403" in res[0].message


def test_skipped_rows_are_counted_in_the_step_message_and_bad_file_is_a_step_error():
    s = Settings.from_env({"CMS_BASE_URL": "x"}); st = _MemState(); bq = FakeBqClient()
    blobs = [FakeBucketBlob("spend/meta/ok.csv", 1, HEAD + "2026-09-25,Dallas,1.00,10,1\n,,1.00,10,1\n"),
             FakeBucketBlob("spend/meta/bad.csv", 2, HEAD + "31/12/2026,Dallas,1.00,10,1\n")]
    res = load_spend_csv(s, RawWriter(bq, "sipandscript", "r"), st, storage=FakeStorageClient(blobs))
    by = {r.step: r for r in res}
    assert by["spend.list.meta"].rows == 2 and by["spend.list.pinterest"].rows == 0
    assert by["spend.spend/meta/ok.csv"].status == "ok" and by["spend.spend/meta/ok.csv"].rows == 1
    assert "skipped 1 row" in by["spend.spend/meta/ok.csv"].message
    assert by["spend.spend/meta/bad.csv"].status == "error" and "row 2" in by["spend.spend/meta/bad.csv"].message
    assert len(bq.loads) == 1                                     # the bad file wrote nothing
