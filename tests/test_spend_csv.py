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


def test_spend_skip_same_generation_reload_new_generation():
    bq = FakeBqClient(); s = Settings.from_env({"CMS_BASE_URL": "x"})
    blobs = [FakeBucketBlob("spend/meta/sep.csv", 17, META), FakeBucketBlob("spend/pinterest/sep.csv", 5, PIN)]
    # first file already loaded at generation 17; second never loaded
    bq.query_results.extend([[{"watermark": dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc), "cursor": "17"}], []])
    res = load_spend_csv(s, RawWriter(bq, "sipandscript", "r"), LoadState(bq, "sipandscript"), storage=FakeStorageClient(blobs))
    assert [(r.step, r.rows) for r in res] == [("spend.spend/meta/sep.csv", 0), ("spend.spend/pinterest/sep.csv", 1)]
    # now meta file re-exported: new generation 18 -> reload
    bq2 = FakeBqClient(); bq2.query_results.extend([[{"watermark": dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc), "cursor": "17"}]])
    res2 = load_spend_csv(s, RawWriter(bq2, "sipandscript", "r"), LoadState(bq2, "sipandscript"), storage=FakeStorageClient([FakeBucketBlob("spend/meta/sep.csv", 18, META)]))
    assert res2[0].rows == 1
