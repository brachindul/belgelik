"""Jenerik sync v2: v1 ile parite (ayni LWW/tombstone/pull sonuclari)."""
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
    return prof


def _v2_push(ops):
    return client.post("/sync/v2/push", headers=HEADERS, json={"device_id": "dev-a", "ops": ops})


def test_v2_push_pull_roundtrip(temp_lib):
    ops = [
        {"entity": "position", "data": {"doc_id": "d1", "page": 7, "updated_at_ms": 5000, "updated_by_device": "dev-a", "deleted_at_ms": None}},
        {"entity": "bookmark", "data": {"bookmark_uuid": "bm1", "doc_id": "d1", "page": 2, "label": "X", "updated_at_ms": 6000, "updated_by_device": "dev-a", "deleted_at_ms": None}},
        {"entity": "pomodoro", "data": {"session_uuid": "p1", "date": "2026-07-04", "subject": "İYUK", "phase": "work", "minutes": 25, "started_at_ms": 1, "updated_at_ms": 7000, "updated_by_device": "dev-a", "deleted_at_ms": None}},
    ]
    r = _v2_push(ops)
    assert r.status_code == 200 and r.json()["accepted"] == 3

    pulled = client.get("/sync/v2/pull?since_ms=0", headers=HEADERS).json()
    by_entity = {}
    for op in pulled["ops"]:
        by_entity.setdefault(op["entity"], []).append(op["data"])
    assert by_entity["position"][0]["page"] == 7
    assert by_entity["bookmark"][0]["bookmark_uuid"] == "bm1"
    assert by_entity["pomodoro"][0]["minutes"] == 25


def test_v2_lww_matches_v1(temp_lib):
    # Yeni sonra eski: eski reddedilir (v1 ile ayni kural)
    assert _v2_push([{"entity": "position", "data": {"doc_id": "d1", "page": 9, "updated_at_ms": 5000, "updated_by_device": "dev-a"}}]).json()["accepted"] == 1
    assert _v2_push([{"entity": "position", "data": {"doc_id": "d1", "page": 1, "updated_at_ms": 3000, "updated_by_device": "dev-b"}}]).json()["accepted"] == 0
    with main.use_profile(temp_lib), main.db() as conn:
        assert conn.execute("SELECT page FROM positions WHERE doc_id='d1'").fetchone()["page"] == 9


def test_v1_and_v2_interoperate(temp_lib):
    # v1 ile yaz, v2 ile cek
    client.post("/sync/push", headers=HEADERS, json={
        "device_id": "dev-a",
        "positions": [{"doc_id": "d2", "page": 4, "updated_at_ms": 8000, "updated_by_device": "dev-a", "deleted_at_ms": None}],
    })
    pulled = client.get("/sync/v2/pull?since_ms=0", headers=HEADERS).json()
    pos = [op["data"] for op in pulled["ops"] if op["entity"] == "position"]
    assert pos and pos[0]["doc_id"] == "d2" and pos[0]["page"] == 4


def test_v2_unknown_entity_ignored(temp_lib):
    r = _v2_push([{"entity": "bogus", "data": {"x": 1}}])
    assert r.status_code == 200 and r.json()["accepted"] == 0
