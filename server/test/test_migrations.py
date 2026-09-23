"""Numarali migrasyon (PRAGMA user_version) testleri."""
import sqlite3

import pytest
import core


@pytest.fixture
def temp_prof(tmp_path, monkeypatch):
    prof = core.PROFILES[0]
    monkeypatch.setattr(prof, "db_path", tmp_path / "app.db")
    return prof


def test_init_sets_user_version_and_tables(temp_prof):
    with core.use_profile(temp_prof):
        core.init_db()
        with core.db() as conn:
            assert conn.execute("PRAGMA user_version").fetchone()[0] == len(core.MIGRATIONS)
            # birkac tablo gercekten kuruldu mu?
            names = {
                r[0] for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
    assert {"positions", "annotations", "bookmarks", "notes"} <= names


def test_migrations_idempotent(temp_prof):
    with core.use_profile(temp_prof):
        core.init_db()
        # Veri ekle
        with core.db() as conn:
            conn.execute(
                "INSERT INTO positions (doc_id, page, updated_at, updated_at_ms, received_at_ms) "
                "VALUES ('d1', 3, 1, 1000, 1000)"
            )
        # Ikinci init: migrasyon tekrar CALISMAMALI (user_version=1), veri durur
        core.init_db()
        with core.db() as conn:
            assert conn.execute("PRAGMA user_version").fetchone()[0] == len(core.MIGRATIONS)
            row = conn.execute("SELECT page FROM positions WHERE doc_id='d1'").fetchone()
        assert row["page"] == 3


def test_run_migrations_second_call_noop(temp_prof):
    with core.use_profile(temp_prof):
        core.init_db()
        with core.db() as conn:
            before = conn.execute("PRAGMA user_version").fetchone()[0]
            core.run_migrations(conn)  # tekrar
            after = conn.execute("PRAGMA user_version").fetchone()[0]
    assert before == after == len(core.MIGRATIONS)
