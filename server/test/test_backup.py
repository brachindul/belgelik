"""backup.py coklu profil yedekleme testleri."""
import json
import sqlite3
import zipfile
from datetime import datetime, timedelta

import backup


def _make_db(path, marker):
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE t (x TEXT)")
    conn.execute("INSERT INTO t (x) VALUES (?)", (marker,))
    conn.commit()
    conn.close()


def _setup_base(tmp_path):
    """İki profilli sahte sunucu dizini kurar; base dondurur."""
    base = tmp_path
    data = base / "data"
    data.mkdir()
    config = {
        "profiles": [
            {"id": "profil1", "pdf_dir": "pdf-kutuphane"},
            {"id": "profil2", "pdf_dir": "pdf-profil2"},
        ]
    }
    (data / "config.json").write_text(json.dumps(config), encoding="utf-8")
    _make_db(data / "profil1" / "app.db", "profil1-db")
    _make_db(data / "profil2" / "app.db", "profil2-db")
    # Kutuphaneler + birer sahte PDF
    (base / "pdf-kutuphane").mkdir()
    (base / "pdf-kutuphane" / "a.pdf").write_bytes(b"%PDF-profil1")
    (base / "pdf-profil2").mkdir()
    (base / "pdf-profil2" / "b.pdf").write_bytes(b"%PDF-profil2")
    return base


def test_backup_all_profiles(tmp_path):
    base = _setup_base(tmp_path)
    backup.run_backup(base, include_pdfs=True)

    today = datetime.now().strftime("%Y-%m-%d")
    day = base / "backups" / today
    for pid, marker in [("profil1", "profil1-db"), ("profil2", "profil2-db")]:
        db_out = day / pid / "app.db"
        zip_out = day / pid / "pdf-kutuphane.zip"
        assert db_out.exists(), f"{pid} db yedeklenmedi"
        assert zip_out.exists(), f"{pid} pdf zip yok"
        # Yedeklenen DB icerigi dogru profile ait mi?
        conn = sqlite3.connect(db_out)
        row = conn.execute("SELECT x FROM t").fetchone()
        conn.close()
        assert row[0] == marker
        # Zip icinde PDF var mi?
        with zipfile.ZipFile(zip_out) as z:
            assert z.namelist(), f"{pid} zip bos"


def test_backup_db_only(tmp_path):
    base = _setup_base(tmp_path)
    backup.run_backup(base, include_pdfs=False)
    today = datetime.now().strftime("%Y-%m-%d")
    day = base / "backups" / today
    assert (day / "profil1" / "app.db").exists()
    assert not (day / "profil1" / "pdf-kutuphane.zip").exists()


def test_legacy_db_backed_up(tmp_path):
    base = _setup_base(tmp_path)
    _make_db(base / "data" / "app.db", "legacy-db")  # eski tekil db
    backup.run_backup(base, include_pdfs=False)
    today = datetime.now().strftime("%Y-%m-%d")
    legacy = base / "backups" / today / "_legacy" / "app.db"
    assert legacy.exists()
    conn = sqlite3.connect(legacy)
    assert conn.execute("SELECT x FROM t").fetchone()[0] == "legacy-db"
    conn.close()


def test_no_config_falls_back(tmp_path):
    base = tmp_path
    (base / "data").mkdir()
    _make_db(base / "data" / "app.db", "single-db")
    backup.run_backup(base, include_pdfs=False)
    today = datetime.now().strftime("%Y-%m-%d")
    assert (base / "backups" / today / "app.db").exists()


def test_rotate_keeps_only_newest(tmp_path):
    base = tmp_path
    backups = base / "backups"
    backups.mkdir()
    days = [
        (datetime.now() - timedelta(days=n)).strftime("%Y-%m-%d") for n in range(3)
    ]
    for d in days:
        (backups / d).mkdir()
    backup.rotate(base)
    remaining = sorted(p.name for p in backups.iterdir() if p.is_dir())
    assert remaining == [days[0]], f"beklenen {[days[0]]}, gelen {remaining}"
