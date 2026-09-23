from fastapi.testclient import TestClient
import core
import main

client = TestClient(main.app)
# Coklu profil mimarisi: TOKEN global'i kaldirildi; ilk profilin token'ini kullan.
TOKEN = main.PROFILES[0].token
HEADERS = {"X-Auth-Token": TOKEN}


def use_temp_library(tmp_path, monkeypatch):
    """Ilk profili gecici bir kutuphane/DB'ye yonlendirir (test izolasyonu).

    Coklu profil mimarisinde dizinler profil nesnesinde tutulur; endpoint'ler
    check_auth uzerinden PROFILES[0]'i contextvar'a koyar. Ayni nesnenin
    pdf_dir/db_path'ini patch'leyip taze DB kurariz.
    """
    prof = main.PROFILES[0]
    pdf_dir = tmp_path / "pdf-kutuphane"
    pdf_dir.mkdir()
    monkeypatch.setattr(prof, "pdf_dir", pdf_dir)
    monkeypatch.setattr(prof, "db_path", tmp_path / "app.db")
    with main.use_profile(prof):
        main.init_db()
    return pdf_dir


def write_pdf(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"%PDF-1.4\n%%EOF")
    return path


def insert_bookmark(doc_id, uuid="bm-1"):
    with main.use_profile(main.PROFILES[0]), main.db() as conn:
        conn.execute(
            """
            INSERT INTO bookmarks
                (bookmark_uuid, doc_id, page, label, updated_at_ms, updated_by_device, deleted_at_ms)
            VALUES (?, ?, 3, 'Bolum', 1000, 'dev-a', NULL)
            """,
            (uuid, doc_id),
        )


def insert_index(doc_id, rel, text="idare hukuku"):
    with main.use_profile(main.PROFILES[0]), main.db() as conn:
        conn.execute(
            "INSERT INTO pdf_text (doc_id, page, content) VALUES (?, 1, ?)",
            (doc_id, text),
        )
        conn.execute(
            """
            INSERT INTO pdf_index_meta (doc_id, relative_path, name, size, modified, indexed_at)
            VALUES (?, ?, ?, 1, 1, 1)
            """,
            (doc_id, rel, rel.rsplit("/", 1)[-1].removesuffix(".pdf")),
        )


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"
    assert "server_time_ms" in r.json()
    assert "db_size_bytes" in r.json()


def test_auth_required():
    r = client.get("/pdfs")  # token yok
    assert r.status_code == 401


def test_auth_ok():
    r = client.get("/pdfs", headers=HEADERS)
    assert r.status_code == 200
    assert "items" in r.json()


def test_doc_id_stable():
    a = main.doc_id_for("x/Test.pdf")
    b = main.doc_id_for("x/Test.pdf")
    assert a == b and len(a) == 16


def test_fts_query():
    assert main._fts_query("idare hukuku") == '"idare"* "hukuku"*'
    assert main._fts_query("   ") == ""


def test_move_pdf_transfers_bookmarks_and_search_index(tmp_path, monkeypatch):
    pdf_dir = use_temp_library(tmp_path, monkeypatch)
    write_pdf(pdf_dir / "A.pdf")
    (pdf_dir / "Dest").mkdir()
    old_id = main.doc_id_for("A.pdf")
    insert_bookmark(old_id)
    insert_index(old_id, "A.pdf")

    r = client.post(
        f"/pdfs/{old_id}/move",
        headers=HEADERS,
        json={"target_folder": "Dest"},
    )

    assert r.status_code == 200
    new_id = main.doc_id_for("Dest/A.pdf")
    pulled = client.get("/sync/pull?since_ms=0", headers=HEADERS).json()
    assert pulled["bookmarks"][0]["doc_id"] == new_id
    search = client.get("/search?q=idare", headers=HEADERS).json()
    assert search["items"][0]["doc_id"] == new_id
    assert search["items"][0]["relative_path"] == "Dest/A.pdf"


def test_rename_folder_transfers_bookmarks(tmp_path, monkeypatch):
    pdf_dir = use_temp_library(tmp_path, monkeypatch)
    write_pdf(pdf_dir / "Old" / "A.pdf")
    old_id = main.doc_id_for("Old/A.pdf")
    insert_bookmark(old_id)

    r = client.put(
        "/folders/rename",
        headers=HEADERS,
        json={"path": "Old", "new_name": "New"},
    )

    assert r.status_code == 200
    new_id = main.doc_id_for("New/A.pdf")
    pulled = client.get("/sync/pull?since_ms=0", headers=HEADERS).json()
    assert pulled["bookmarks"][0]["doc_id"] == new_id


def test_sync_push_recent_lww_and_prunes_to_20(tmp_path, monkeypatch):
    use_temp_library(tmp_path, monkeypatch)
    body = {
        "device_id": "dev-a",
        "recent": [
            {"doc_id": f"doc-{i}", "opened_at_ms": 1000 + i, "updated_by_device": "dev-a"}
            for i in range(22)
        ],
    }
    r = client.post("/sync/push", headers=HEADERS, json=body)
    assert r.status_code == 200

    stale = {
        "device_id": "dev-b",
        "recent": [{"doc_id": "doc-21", "opened_at_ms": 1, "updated_by_device": "dev-b"}],
    }
    r = client.post("/sync/push", headers=HEADERS, json=stale)
    assert r.status_code == 200
    assert r.json()["accepted"]["recent"] == 0
    with main.use_profile(main.PROFILES[0]), main.db() as conn:
        count = conn.execute("SELECT COUNT(*) AS c FROM pdf_recent").fetchone()["c"]
        newest = conn.execute(
            "SELECT opened_at_ms FROM pdf_recent WHERE doc_id = 'doc-21'"
        ).fetchone()["opened_at_ms"]
    assert count == 20
    assert newest == 1021


def test_deleted_doc_rejects_stale_push(tmp_path, monkeypatch):
    pdf_dir = use_temp_library(tmp_path, monkeypatch)
    write_pdf(pdf_dir / "A.pdf")
    doc_id = main.doc_id_for("A.pdf")

    r = client.delete(f"/pdfs/{doc_id}", headers=HEADERS)
    assert r.status_code == 200
    deleted = client.get("/sync/pull?since_ms=0", headers=HEADERS).json()["deleted_docs"]
    deleted_at = deleted[0]["deleted_at_ms"]

    body = {
        "device_id": "dev-a",
        "positions": [{
            "doc_id": doc_id,
            "page": 5,
            "updated_at_ms": deleted_at - 1,
            "updated_by_device": "dev-a",
            "deleted_at_ms": None,
        }],
    }
    r = client.post("/sync/push", headers=HEADERS, json=body)
    assert r.status_code == 200
    assert r.json()["accepted"]["positions"] == 0
    with main.use_profile(main.PROFILES[0]), main.db() as conn:
        row = conn.execute("SELECT * FROM positions WHERE doc_id = ?", (doc_id,)).fetchone()
    assert row is None


def test_app_version_requires_auth():
    r = client.get("/app/version")
    assert r.status_code == 401


def test_app_version_reads_pubspec(tmp_path, monkeypatch):
    pubspec = tmp_path / "pubspec.yaml"
    pubspec.write_text("name: x\nversion: 1.2.3+45\n", encoding="utf-8")
    apk = tmp_path / "app-release.apk"
    monkeypatch.setattr(core, "APP_PUBSPEC_PATH", pubspec)
    monkeypatch.setattr(core, "APK_PATH", apk)

    r = client.get("/app/version", headers=HEADERS)
    assert r.status_code == 200
    body = r.json()
    assert body["version"] == "1.2.3"
    assert body["build"] == 45
    assert body["apk_exists"] is False

    apk.write_bytes(b"fake-apk")
    r = client.get("/app/version", headers=HEADERS)
    body = r.json()
    assert body["apk_exists"] is True
    assert body["apk_size"] == 8

    r = client.get("/app/apk", headers=HEADERS)
    assert r.status_code == 200
    assert r.content == b"fake-apk"


def test_app_apk_404_when_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(core, "APK_PATH", tmp_path / "yok.apk")
    r = client.get("/app/apk", headers=HEADERS)
    assert r.status_code == 404


def test_sync_push_pull_pomodoro_sessions(tmp_path, monkeypatch):
    use_temp_library(tmp_path, monkeypatch)
    body = {
        "device_id": "dev-a",
        "pomodoro_sessions": [
            {
                "session_uuid": "pom-1",
                "date": "2026-06-10",
                "subject": "İYUK",
                "phase": "work",
                "minutes": 25,
                "started_at_ms": 1000,
                "updated_at_ms": 2000,
                "updated_by_device": "dev-a",
                "deleted_at_ms": None,
            }
        ],
    }
    r = client.post("/sync/push", headers=HEADERS, json=body)
    assert r.status_code == 200
    assert r.json()["accepted"]["pomodoro_sessions"] == 1

    pulled = client.get("/sync/pull?since_ms=0", headers=HEADERS).json()
    sessions = pulled["pomodoro_sessions"]
    assert sessions[0]["session_uuid"] == "pom-1"
    assert sessions[0]["minutes"] == 25
