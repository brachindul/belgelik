"""Tombstone temizligi (cleanup_tombstones) testleri."""
import time

import pytest
import main


@pytest.fixture
def temp_lib(tmp_path, monkeypatch):
    prof = main.PROFILES[0]
    pdf_dir = tmp_path / "pdf-kutuphane"
    pdf_dir.mkdir()
    monkeypatch.setattr(prof, "pdf_dir", pdf_dir)
    monkeypatch.setattr(prof, "db_path", tmp_path / "app.db")
    with main.use_profile(prof):
        main.init_db()
    yield prof


def test_cleanup_removes_old_keeps_recent(temp_lib):
    now_ms = int(time.time() * 1000)
    old = now_ms - main.TOMBSTONE_TTL_MS - 1000  # 90 gunden eski
    recent = now_ms - 1000  # yeni
    with main.use_profile(temp_lib), main.db() as conn:
        conn.execute(
            "INSERT INTO deleted_docs (doc_id, deleted_at_ms) VALUES ('old', ?), ('new', ?)",
            (old, recent),
        )
        conn.execute(
            """INSERT INTO bookmarks (bookmark_uuid, doc_id, page, label, updated_at_ms, deleted_at_ms)
               VALUES ('bm-old', 'd', 1, '', ?, ?), ('bm-new', 'd', 1, '', ?, ?), ('bm-live', 'd', 1, '', ?, NULL)""",
            (old, old, recent, recent, now_ms),
        )

    with main.use_profile(temp_lib):
        main.cleanup_tombstones(now_ms)

    with main.use_profile(temp_lib), main.db() as conn:
        docs = {r["doc_id"] for r in conn.execute("SELECT doc_id FROM deleted_docs").fetchall()}
        bms = {r["bookmark_uuid"] for r in conn.execute("SELECT bookmark_uuid FROM bookmarks").fetchall()}
    assert docs == {"new"}
    assert bms == {"bm-new", "bm-live"}  # eski tombstone gitti, yeni + canli kaldi
