"""Sync LWW + pull imleci (received_at_ms) regresyon testleri.

Ana senaryo: istemci saati geride olsa bile push edilen kayit diger cihazlarca
cekilebilmeli. Duzeltme oncesi pull filtresi istemcinin updated_at_ms'ine
bakiyordu; artik sunucunun received_at_ms'ine bakiyor.
"""
import pytest
from fastapi.testclient import TestClient
import main

client = TestClient(main.app)
TOKEN = main.PROFILES[0].token
HEADERS = {"X-Auth-Token": TOKEN}


@pytest.fixture
def temp_lib(tmp_path, monkeypatch):
    prof = main.PROFILES[0]
    pdf_dir = tmp_path / "pdf-kutuphane"
    pdf_dir.mkdir()
    monkeypatch.setattr(prof, "pdf_dir", pdf_dir)
    monkeypatch.setattr(prof, "db_path", tmp_path / "app.db")
    with main.use_profile(prof):
        main.init_db()
    return pdf_dir


def _push_position(doc_id, page, updated_at_ms, device, deleted_at_ms=None):
    return client.post(
        "/sync/push",
        headers=HEADERS,
        json={
            "device_id": device,
            "positions": [{
                "doc_id": doc_id,
                "page": page,
                "updated_at_ms": updated_at_ms,
                "updated_by_device": device,
                "deleted_at_ms": deleted_at_ms,
            }],
        },
    )


def test_pull_uses_server_clock_not_client_clock(temp_lib):
    """Asil hata: saati geride cihazin push'i imlecin gerisinde kalmamali."""
    # dev-b saati cok geride: updated_at_ms = 1000 (~1970)
    r = _push_position("d1", 5, 1000, "dev-b")
    assert r.status_code == 200
    assert r.json()["accepted"]["positions"] == 1

    # dev-a imleci 1970'ten ileride ama sunucu saatinin (now) gerisinde.
    # Duzeltme oncesi filtre (updated_at_ms > since_ms) bu kaydi ATLARDI.
    pulled = client.get("/sync/pull?since_ms=1000000000", headers=HEADERS).json()
    ids = [p["doc_id"] for p in pulled["positions"]]
    assert "d1" in ids, "geride saatli cihazin kaydi pull'dan dustu (regresyon)"


def test_lww_newer_wins_older_rejected(temp_lib):
    assert _push_position("d1", 5, 5000, "dev-a").json()["accepted"]["positions"] == 1
    # Daha eski updated_at_ms reddedilmeli
    r = _push_position("d1", 9, 3000, "dev-b")
    assert r.json()["accepted"]["positions"] == 0
    with main.use_profile(main.PROFILES[0]), main.db() as conn:
        row = conn.execute("SELECT page, updated_at_ms FROM positions WHERE doc_id='d1'").fetchone()
    assert row["page"] == 5 and row["updated_at_ms"] == 5000


def test_lww_equal_timestamp_device_tiebreak(temp_lib):
    assert _push_position("d1", 5, 5000, "dev-a").json()["accepted"]["positions"] == 1
    # Ayni zaman damgasi: alfabetik buyuk device kazanir (dev-z > dev-a)
    assert _push_position("d1", 9, 5000, "dev-z").json()["accepted"]["positions"] == 1
    with main.use_profile(main.PROFILES[0]), main.db() as conn:
        row = conn.execute("SELECT page, updated_by_device FROM positions WHERE doc_id='d1'").fetchone()
    assert row["page"] == 9 and row["updated_by_device"] == "dev-z"
    # Kucuk device geri gelirse reddedilir
    assert _push_position("d1", 1, 5000, "dev-a").json()["accepted"]["positions"] == 0


def test_deleted_doc_rejects_stale_push(temp_lib):
    (temp_lib / "A.pdf").write_bytes(b"%PDF-1.4\n%%EOF")
    doc_id = main.doc_id_for("A.pdf")
    assert client.delete(f"/pdfs/{doc_id}", headers=HEADERS).status_code == 200
    deleted = client.get("/sync/pull?since_ms=0", headers=HEADERS).json()["deleted_docs"]
    deleted_at = deleted[0]["deleted_at_ms"]
    # Silinme aninin oncesine ait push reddedilir
    r = _push_position(doc_id, 5, deleted_at - 1, "dev-a")
    assert r.json()["accepted"]["positions"] == 0
    with main.use_profile(main.PROFILES[0]), main.db() as conn:
        assert conn.execute("SELECT 1 FROM positions WHERE doc_id=?", (doc_id,)).fetchone() is None


def test_pull_cursor_advances(temp_lib):
    _push_position("d1", 5, 5000, "dev-a")
    r1 = client.get("/sync/pull?since_ms=0", headers=HEADERS).json()
    assert "d1" in [p["doc_id"] for p in r1["positions"]]
    cursor = r1["server_time_ms"]
    # Ayni imlecle tekrar cekince kayit gelmez (received_at_ms < cursor)
    r2 = client.get(f"/sync/pull?since_ms={cursor}", headers=HEADERS).json()
    assert "d1" not in [p["doc_id"] for p in r2["positions"]]
