import json

import main
import mevzuat_ingest
import pytest
from fastapi.testclient import TestClient


client = TestClient(main.app)
HEADERS = {"X-Auth-Token": main.PROFILES[0].token}


@pytest.fixture
def temp_legislation(tmp_path, monkeypatch):
    profile = main.PROFILES[0]
    monkeypatch.setattr(profile, "db_path", tmp_path / "app.db")
    with main.use_profile(profile):
        main.init_db()
        with main.db() as conn:
            conn.execute("INSERT INTO legislation VALUES ('6098','Türk Borçlar Kanunu','TBK','Kanun','v1',1,'hash')")
            conn.execute("INSERT INTO legislation_article VALUES ('6098/m.77','6098',1,'Sebepsiz zenginleşme','77','Haklı bir sebep olmaksızın zenginleşen kişi, bunu geri vermekle yükümlüdür.','{}','v1')")
    return profile


def test_legislation_list_and_bundle(temp_legislation):
    listing = client.get("/legislation", headers=HEADERS)
    assert listing.status_code == 200
    assert listing.json()["items"][0]["article_count"] == 1
    bundle = client.get("/legislation/6098/bundle", headers=HEADERS)
    assert bundle.status_code == 200
    assert bundle.json()["articles"][0]["id"] == "6098/m.77"


def test_legislation_position_v2_sync(temp_legislation):
    pushed = client.post("/sync/v2/push", headers=HEADERS, json={"device_id": "test", "ops": [{"entity": "legislation_position", "data": {"mevzuat_no": "6098", "madde_ref": "6098/m.77", "updated_at_ms": 1000, "updated_by_device": "test", "deleted_at_ms": None}}]})
    assert pushed.status_code == 200
    pulled = client.get("/sync/v2/pull?since_ms=0", headers=HEADERS)
    assert any(op["entity"] == "legislation_position" and op["data"]["madde_ref"] == "6098/m.77" for op in pulled.json()["ops"])


def test_legislation_changes_are_exposed(temp_legislation):
    with main.use_profile(temp_legislation), main.db() as conn:
        conn.execute("INSERT INTO legislation_change(madde_ref, old_version, new_version, degisiklik_ozeti, old_text, new_text, created_at_ms) VALUES ('6098/m.77','v1','v2','Madde metni değişti','eski','yeni',2)")
    response = client.get("/legislation/changes?mevzuat_no=6098", headers=HEADERS)
    assert response.status_code == 200
    assert response.json()["items"][0]["madde_ref"] == "6098/m.77"
    bundle = client.get("/legislation/6098/bundle", headers=HEADERS).json()
    assert bundle["changes"][0]["new_text"] == "yeni"


def test_ingest_records_article_diff_without_scraping(temp_legislation, monkeypatch):
    with main.use_profile(temp_legislation), main.db() as conn:
        conn.execute("UPDATE legislation SET snapshot_version = 'old' WHERE mevzuat_no = '6098'")
        conn.execute("UPDATE legislation_article SET metin = 'eski metin' WHERE id = '6098/m.77'")
        monkeypatch.setattr(mevzuat_ingest, "_search_document_id", lambda *_args, **_kwargs: ("fake", {"title": "Türk Borçlar Kanunu", "legislation_type": "Kanun"}))
        monkeypatch.setattr(mevzuat_ingest, "fetch_full_text", lambda *_args, **_kwargs: {"text": "MADDE 77 - Yeni metin", "content_status": "html_markdown", "title": "TBK"})
        monkeypatch.setitem(mevzuat_ingest.OFFICIAL_FINAL_ARTICLE, "6098", 77)
        result = mevzuat_ingest.ingest_one(conn, "6098")
        row = conn.execute("SELECT old_version, new_version, old_text, new_text FROM legislation_change WHERE madde_ref = '6098/m.77'").fetchone()
    assert result["changed_articles"] == 1
    assert row["old_version"] == "old"
    assert row["old_text"] == "eski metin"
    assert row["new_text"] == "Yeni metin"


def _mock_ingest(monkeypatch, text, final_article):
    monkeypatch.setattr(mevzuat_ingest, "_search_document_id", lambda *_args, **_kwargs: ("fake", {"title": "Türk Borçlar Kanunu", "legislation_type": "Kanun"}))
    monkeypatch.setattr(mevzuat_ingest, "fetch_full_text", lambda *_args, **_kwargs: {"text": text, "content_status": "html_markdown", "title": "TBK"})
    monkeypatch.setitem(mevzuat_ingest.OFFICIAL_FINAL_ARTICLE, "6098", final_article)


def test_ingest_records_added_article(temp_legislation, monkeypatch):
    _mock_ingest(monkeypatch, "MADDE 77 - eski metin\nMADDE 78 - eklenen metin", 78)
    with main.use_profile(temp_legislation), main.db() as conn:
        conn.execute("UPDATE legislation SET snapshot_version='old' WHERE mevzuat_no='6098'")
        conn.execute("UPDATE legislation_article SET metin='eski metin' WHERE id='6098/m.77'")
        result = mevzuat_ingest.ingest_one(conn, "6098")
        change = conn.execute("SELECT * FROM legislation_change WHERE madde_ref='6098/m.78'").fetchone()
    assert result["changed_articles"] == 1
    assert change["degisiklik_ozeti"] == "Madde eklendi"
    assert change["old_text"] is None


def test_ingest_records_removed_article(temp_legislation, monkeypatch):
    _mock_ingest(monkeypatch, "MADDE 77 - eski metin", 77)
    with main.use_profile(temp_legislation), main.db() as conn:
        conn.execute("UPDATE legislation SET snapshot_version='old' WHERE mevzuat_no='6098'")
        conn.execute("UPDATE legislation_article SET metin='eski metin' WHERE id='6098/m.77'")
        conn.execute("INSERT INTO legislation_article VALUES ('6098/m.78','6098',2,'','78','kaldırılacak','{}','old')")
        result = mevzuat_ingest.ingest_one(conn, "6098")
        change = conn.execute("SELECT * FROM legislation_change WHERE madde_ref='6098/m.78'").fetchone()
    assert result["changed_articles"] == 1
    assert change["degisiklik_ozeti"] == "Madde kaldırıldı"
    assert change["new_text"] is None


def test_ingest_unchanged_snapshot_creates_no_diff(temp_legislation, monkeypatch):
    _mock_ingest(monkeypatch, "MADDE 77 - eski metin", 77)
    with main.use_profile(temp_legislation), main.db() as conn:
        conn.execute("UPDATE legislation_article SET metin='eski metin' WHERE id='6098/m.77'")
        result = mevzuat_ingest.ingest_one(conn, "6098")
        count = conn.execute("SELECT COUNT(*) FROM legislation_change").fetchone()[0]
    assert result["changed_articles"] == 0
    assert count == 0


def test_incomplete_source_is_rejected_before_db_write(temp_legislation, monkeypatch):
    _mock_ingest(monkeypatch, "MADDE 77 - eksik metin", 649)
    with main.use_profile(temp_legislation), main.db() as conn:
        with pytest.raises(RuntimeError, match="Eksik mevzuat metni"):
            mevzuat_ingest.ingest_one(conn, "6098")
        row = conn.execute("SELECT snapshot_version FROM legislation WHERE mevzuat_no='6098'").fetchone()
    assert row["snapshot_version"] == "v1"
