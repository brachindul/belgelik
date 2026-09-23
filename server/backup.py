"""Belgelik calisma sunucusu - yedekleme (coklu profil).
- Her profilin app.db'sini tutarli sekilde kopyalar (SQLite backup API).
- Her profilin PDF kutuphanesini zip'ler (opsiyonel, --pdfs ile).
- backups/ altinda gunluk klasor; her profil kendi alt klasorune yazilir.
- N gunden eski yedekleri siler (KEEP_COUNT).
Kullanim:
  python backup.py            # sadece DB (tum profiller)
  python backup.py --pdfs     # DB + PDF zip (tum profiller)

Yedek duzeni:
  backups/YYYY-MM-DD/<profil-id>/app.db
  backups/YYYY-MM-DD/<profil-id>/pdf-kutuphane.zip   (--pdfs ile)
  backups/YYYY-MM-DD/_legacy/app.db                  (eski tekil data/app.db varsa)
"""
import json
import sqlite3
import sys
import shutil
import zipfile
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parent
# Yalnizca en yeni N yedek klasoru tutulur. Bilincli olarak 1: yedekler ayrica
# Google Drive'da tutuluyor, yerelde tek gunluk kopya yeterli.
KEEP_COUNT = 1


def load_profiles(base: Path = BASE) -> list[dict]:
    """data/config.json'dan profilleri, cozulmus db/pdf yollariyla dondur.

    main.py'deki _resolve_dir mantiginin aynisi: mutlak yol aynen, degilse
    base altinda cozulur. Config yoksa bos liste doner (cagiran legacy'ye duser).
    """
    cfg_path = base / "data" / "config.json"
    if not cfg_path.exists():
        return []
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    raw = cfg.get("profiles")
    if not raw:
        return []
    profiles = []
    for r in raw:
        pid = r["id"]
        pdf_dir = Path(r.get("pdf_dir", f"pdf-{pid}"))
        profiles.append(
            {
                "id": pid,
                "db": base / "data" / pid / "app.db",
                "pdf_dir": pdf_dir if pdf_dir.is_absolute() else base / pdf_dir,
            }
        )
    return profiles


def backup_db(src_db: Path, dest_dir: Path) -> bool:
    if not src_db.exists():
        print(f"  {src_db} yok, atlandi")
        return False
    dest_dir.mkdir(parents=True, exist_ok=True)
    out = dest_dir / "app.db"
    src = sqlite3.connect(src_db)
    dst = sqlite3.connect(out)
    try:
        with dst:
            src.backup(dst)
    finally:
        src.close()
        dst.close()
    print(f"  DB yedeklendi -> {out}")
    return True


def backup_pdfs(pdf_dir: Path, dest_dir: Path) -> bool:
    if not pdf_dir.exists():
        print(f"  {pdf_dir} yok, atlandi")
        return False
    dest_dir.mkdir(parents=True, exist_ok=True)
    out = dest_dir / "pdf-kutuphane.zip"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in pdf_dir.rglob("*"):
            if p.is_file():
                z.write(p, p.relative_to(pdf_dir))
    print(f"  PDF'ler zip'lendi -> {out}")
    return True


def rotate(base: Path = BASE):
    backups = base / "backups"
    if not backups.exists():
        return
    # Tarih formatli (YYYY-MM-DD) yedek klasorlerini topla, en yenisi disinda hepsini sil.
    dirs = []
    for d in backups.iterdir():
        if not d.is_dir():
            continue
        try:
            day = datetime.strptime(d.name, "%Y-%m-%d")
        except ValueError:
            continue
        dirs.append((day, d))
    dirs.sort(key=lambda x: x[0], reverse=True)  # en yeni once
    for _, d in dirs[KEEP_COUNT:]:
        shutil.rmtree(d, ignore_errors=True)
        print(f"Eski yedek silindi: {d.name}")


def run_backup(base: Path = BASE, include_pdfs: bool = False):
    today = datetime.now().strftime("%Y-%m-%d")
    day_dir = base / "backups" / today

    profiles = load_profiles(base)
    if profiles:
        for prof in profiles:
            print(f"Profil: {prof['id']}")
            dest = day_dir / prof["id"]
            backup_db(prof["db"], dest)
            if include_pdfs:
                backup_pdfs(prof["pdf_dir"], dest)
    else:
        # Config yok/bos: eski tekil duzene dus.
        print("config.json yok veya bos; eski tekil duzene dusuluyor.")
        backup_db(base / "data" / "app.db", day_dir)
        if include_pdfs:
            backup_pdfs(base / "pdf-kutuphane", day_dir)

    # Eski tekil data/app.db profillerin yaninda hala duruyorsa sigorta olarak al.
    legacy_db = base / "data" / "app.db"
    if profiles and legacy_db.exists():
        print("Profil: _legacy (eski data/app.db)")
        backup_db(legacy_db, day_dir / "_legacy")

    rotate(base)
    print("Yedekleme tamam.")


def main():
    run_backup(BASE, include_pdfs="--pdfs" in sys.argv)


if __name__ == "__main__":
    main()
