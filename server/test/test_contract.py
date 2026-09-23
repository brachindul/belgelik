"""Sozlesme (contract) testleri: sunucu v2 pull cikti alan-kumesi contract/
fixture'lariyla birebir esler. Bir alan eklenir/silinirse test kirmizi olur
ve istemci ile sessiz ayrisma PR'da yakalanir.
"""
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
import main

client = TestClient(main.app)
TOKEN = main.PROFILES[0].token
HEADERS = {"X-Auth-Token": TOKEN}

CONTRACT = Path(__file__).resolve().parents[2] / "contract"
# entity (v2 tekil ad) -> fixture dosyasi
SYNC_ENTITIES = {
    "position": "position.json",
    "annotation": "annotation.json",
    "favorite": "favorite.json",
    "recent": "recent.json",
    "reading_goal": "reading_goal.json",
    "bookmark": "bookmark.json",
    "pomodoro": "pomodoro.json",
    "madde_note": "madde_note.json",
}


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


@pytest.mark.parametrize("entity,fname", SYNC_ENTITIES.items())
def test_v2_pull_matches_contract(entity, fname, temp_lib):
    fixture = json.loads((CONTRACT / fname).read_text(encoding="utf-8"))
    # Fixture'i push et
    r = client.post(
        "/sync/v2/push",
        headers=HEADERS,
        json={"device_id": "cihaz-1", "ops": [{"entity": entity, "data": fixture}]},
    )
    assert r.status_code == 200, r.text
    # Pull edip ayni entity'nin data alan-kumesini karsilastir
    pulled = client.get("/sync/v2/pull?since_ms=0", headers=HEADERS).json()
    datas = [op["data"] for op in pulled["ops"] if op["entity"] == entity]
    assert datas, f"{entity} pull'da yok"
    assert set(datas[0].keys()) == set(fixture.keys()), (
        f"{entity} alan-kumesi contract'tan farkli: "
        f"sunucu={sorted(datas[0])} fixture={sorted(fixture)}"
    )
