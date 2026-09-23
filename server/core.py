import hashlib
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime, timezone
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path

import fitz  # PyMuPDF
from fastapi import BackgroundTasks, Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
CONFIG_PATH = DATA_DIR / "config.json"

DATA_DIR.mkdir(exist_ok=True)

# Desteklenen video uzantilari (Android ExoPlayer native: mp4/H.264+AAC onerilir).
VIDEO_EXTS = {".mp4", ".m4v", ".mov", ".webm", ".mkv"}
# Not belgeleri icin uzanti. Klasorde PDF'lerle yan yana durur.
NOTE_EXT = ".belge"
START_TIME = time.time()

# Profil ozellikleri: hangi sekmeler/yetkiler acik. Uygulama /profile'dan okur.
ALL_FEATURES = ["library", "videos", "program", "pomodoro"]


@dataclass
class Profile:
    id: str
    name: str
    token: str
    pdf_dir: Path
    video_dir: Path
    db_path: Path
    features: list[str]


def _resolve_dir(value: str) -> Path:
    """Mutlak yol verilmisse oldugu gibi, degilse BASE_DIR altinda cozulur."""
    p = Path(value)
    return p if p.is_absolute() else (BASE_DIR / value)


def load_or_create_config() -> dict:
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    config = {
        "profiles": [
            {
                "id": "default",
                "name": "Varsayilan",
                "token": secrets.token_urlsafe(24),
                "pdf_dir": "pdf-kutuphane",
                "video_dir": "video-kutuphane",
                "features": ALL_FEATURES,
            }
        ]
    }
    CONFIG_PATH.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return config


def _build_profiles(config: dict) -> list[Profile]:
    raw = config.get("profiles")
    # Geriye uyum: eski {"token": "..."} (opsiyonel video_dir) tek profile cevrilir.
    if not raw:
        token = config.get("token") or secrets.token_urlsafe(24)
        raw = [
            {
                "id": "default",
                "name": "Varsayilan",
                "token": token,
                "pdf_dir": "pdf-kutuphane",
                "video_dir": config.get("video_dir") or "video-kutuphane",
                "features": ALL_FEATURES,
            }
        ]
    profiles: list[Profile] = []
    for r in raw:
        pid = r["id"]
        profiles.append(
            Profile(
                id=pid,
                name=r.get("name", pid),
                token=r["token"],
                pdf_dir=_resolve_dir(r.get("pdf_dir", f"pdf-{pid}")),
                video_dir=_resolve_dir(r.get("video_dir", f"video-{pid}")),
                db_path=DATA_DIR / pid / "app.db",
                features=r.get("features", ALL_FEATURES),
            )
        )
    return profiles


CONFIG = load_or_create_config()
PROFILES = _build_profiles(CONFIG)

# Her profilin kutuphane klasorlerini ve veri dizinini hazirla.
for _p in PROFILES:
    _p.pdf_dir.mkdir(parents=True, exist_ok=True)
    _p.video_dir.mkdir(parents=True, exist_ok=True)
    _p.db_path.parent.mkdir(parents=True, exist_ok=True)

# Istek basina aktif profil (check_auth tarafindan set edilir).
_current_profile: ContextVar[Profile | None] = ContextVar(
    "current_profile", default=None
)


def current_profile() -> Profile:
    p = _current_profile.get()
    if p is None:
        raise HTTPException(status_code=401, detail="Profil cozulemedi")
    return p


def pdf_dir() -> Path:
    return current_profile().pdf_dir


def video_dir() -> Path:
    return current_profile().video_dir


@contextmanager
def use_profile(profile: Profile):
    """Istek disi (baslangic/arka plan) kodda aktif profili gecici olarak ayarlar."""
    token = _current_profile.set(profile)
    try:
        yield
    finally:
        _current_profile.reset(token)


DOC_ID_TABLES = ["positions", "annotations", "pdf_favorites", "pdf_recent", "reading_goals", "bookmarks", "notes"]
# notes tablosunun birincil anahtari note_doc_id (digerleri doc_id). _transfer_doc_id
# ve _delete_doc_data bu haritayi kullanir; schema breaking olmasin diye kolon adini
# yeniden adlandirmak yerine tabloya ozel kolon adini gosteririz.
DOC_ID_PK = {"notes": "note_doc_id"}
MAX_PDF_UPLOAD_BYTES = 500 * 1024 * 1024

# Uygulama ici guncelleme: surum pubspec'ten, APK flutter build ciktisindan okunur.
APP_PUBSPEC_PATH = BASE_DIR.parent / "app" / "pubspec.yaml"
APK_PATH = BASE_DIR.parent / "app" / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"


@contextmanager
def db():
    conn = sqlite3.connect(current_profile().db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def _migration_1_legacy_consolidation(conn):
    # Tek seferlik birlestirme: eski tum CREATE IF NOT EXISTS + try/except ALTER
    # + backfill'ler. Icerik idempotent oldugundan mevcut (user_version=0) DB'lerde
    # guvenle calisir; yeni kurulumda tam semayi kurar.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS positions (
            doc_id     TEXT PRIMARY KEY,
            page       INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            device     TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            date           TEXT NOT NULL,
            subject        TEXT NOT NULL,
            target_minutes INTEGER NOT NULL DEFAULT 0,
            done           INTEGER NOT NULL DEFAULT 0,
            updated_at     INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS annotations (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id     TEXT NOT NULL,
            page       INTEGER NOT NULL,
            kind       TEXT NOT NULL,
            color      INTEGER NOT NULL,
            width      REAL NOT NULL,
            points     TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            device     TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS pdf_favorites (
            doc_id     TEXT PRIMARY KEY,
            updated_at INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS pdf_recent (
            doc_id     TEXT PRIMARY KEY,
            opened_at  INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS reading_goals (
            doc_id       TEXT NOT NULL,
            date         TEXT NOT NULL,
            start_page   INTEGER NOT NULL,
            target_pages INTEGER NOT NULL,
            updated_at   INTEGER NOT NULL,
            PRIMARY KEY (doc_id, date)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS bookmarks (
            bookmark_uuid     TEXT PRIMARY KEY,
            doc_id            TEXT NOT NULL,
            page              INTEGER NOT NULL,
            label             TEXT NOT NULL DEFAULT '',
            updated_at_ms     INTEGER NOT NULL,
            updated_by_device TEXT,
            deleted_at_ms     INTEGER
        )
        """
    )


def _migration_2_legislation(conn):
    """Faz 21: canonical, versioned offline legislation storage."""
    conn.execute(
        """
        CREATE TABLE legislation (
            mevzuat_no       TEXT PRIMARY KEY,
            ad               TEXT NOT NULL,
            kisa_ad          TEXT NOT NULL DEFAULT '',
            tur              TEXT NOT NULL DEFAULT 'Kanun',
            snapshot_version TEXT NOT NULL,
            ingested_at_ms   INTEGER NOT NULL,
            raw_hash         TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE legislation_article (
            id               TEXT PRIMARY KEY,
            mevzuat_no       TEXT NOT NULL REFERENCES legislation(mevzuat_no) ON DELETE CASCADE,
            sira             INTEGER NOT NULL,
            baslik           TEXT NOT NULL DEFAULT '',
            madde_no_raw     TEXT NOT NULL,
            metin            TEXT NOT NULL,
            metadata_json    TEXT NOT NULL DEFAULT '{}',
            snapshot_version TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE legislation_snapshot (
            mevzuat_no       TEXT NOT NULL REFERENCES legislation(mevzuat_no) ON DELETE CASCADE,
            snapshot_version TEXT NOT NULL,
            raw_text         TEXT NOT NULL,
            created_at_ms    INTEGER NOT NULL,
            PRIMARY KEY (mevzuat_no, snapshot_version)
        )
        """
    )
    conn.execute(
        "CREATE INDEX idx_legislation_article_law_order "
        "ON legislation_article(mevzuat_no, sira)"
    )


def _migration_3_legislation_position(conn):
    """Faz 22: last article position for each downloaded legislation."""
    conn.execute(
        """
        CREATE TABLE legislation_positions (
            mevzuat_no       TEXT PRIMARY KEY,
            madde_ref        TEXT NOT NULL,
            updated_at_ms    INTEGER NOT NULL,
            updated_by_device TEXT,
            received_at_ms   INTEGER,
            deleted_at_ms    INTEGER
        )
        """
    )


def _migration_4_madde_notes(conn):
    """Faz 23: highlights, notes and bookmarks attached to article refs."""
    conn.execute(
        """
        CREATE TABLE madde_notes (
            note_uuid              TEXT PRIMARY KEY,
            madde_ref              TEXT NOT NULL,
            kind                   TEXT NOT NULL CHECK(kind IN ('highlight','note','bookmark')),
            renk                   INTEGER,
            secili_metin_araligi  TEXT,
            text                   TEXT NOT NULL DEFAULT '',
            updated_at_ms          INTEGER NOT NULL,
            updated_by_device      TEXT,
            received_at_ms         INTEGER,
            deleted_at_ms          INTEGER
        )
        """
    )
    conn.execute("CREATE INDEX idx_madde_notes_ref ON madde_notes(madde_ref, deleted_at_ms)")


def _migration_5_legislation_changes(conn):
    """Faz 24: article-level diffs between ingested snapshots."""
    conn.execute(
        """
        CREATE TABLE legislation_change (
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            madde_ref          TEXT NOT NULL,
            old_version       TEXT NOT NULL,
            new_version       TEXT NOT NULL,
            degisiklik_ozeti  TEXT NOT NULL,
            old_text          TEXT,
            new_text          TEXT,
            created_at_ms      INTEGER NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX idx_legislation_change_ref ON legislation_change(madde_ref, created_at_ms)")

    conn.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS pdf_text "
        "USING fts5(doc_id UNINDEXED, page UNINDEXED, content, "
        "tokenize = 'unicode61 remove_diacritics 2')"
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS pdf_index_meta (
            doc_id        TEXT PRIMARY KEY,
            relative_path TEXT NOT NULL,
            name          TEXT NOT NULL,
            size          INTEGER NOT NULL,
            modified      INTEGER NOT NULL,
            indexed_at    INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS deleted_docs (
            doc_id        TEXT PRIMARY KEY,
            deleted_at_ms INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS pomodoro_sessions (
            session_uuid     TEXT PRIMARY KEY,
            date             TEXT NOT NULL,
            subject          TEXT NOT NULL,
            phase            TEXT NOT NULL,
            minutes          INTEGER NOT NULL,
            started_at_ms    INTEGER NOT NULL,
            updated_at_ms    INTEGER NOT NULL,
            updated_by_device TEXT,
            deleted_at_ms    INTEGER
        )
        """
    )

    # Migrations for sync support (ignore if columns already exist)
    for stmt in [
        "ALTER TABLE positions ADD COLUMN updated_at_ms INTEGER",
        "ALTER TABLE positions ADD COLUMN updated_by_device TEXT",
        "ALTER TABLE positions ADD COLUMN deleted_at_ms INTEGER",
        "ALTER TABLE annotations ADD COLUMN stroke_uuid TEXT",
        "ALTER TABLE annotations ADD COLUMN updated_at_ms INTEGER",
        "ALTER TABLE annotations ADD COLUMN updated_by_device TEXT",
        "ALTER TABLE annotations ADD COLUMN deleted_at_ms INTEGER",
        "ALTER TABLE annotations ADD COLUMN text TEXT",
        "ALTER TABLE annotations ADD COLUMN font_size REAL",
        "ALTER TABLE annotations ADD COLUMN font_family TEXT",
        "ALTER TABLE pdf_favorites ADD COLUMN favorite INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE pdf_favorites ADD COLUMN updated_at_ms INTEGER",
        "ALTER TABLE pdf_favorites ADD COLUMN updated_by_device TEXT",
        "ALTER TABLE pdf_recent ADD COLUMN opened_at_ms INTEGER",
        "ALTER TABLE pdf_recent ADD COLUMN updated_by_device TEXT",
        "ALTER TABLE pdf_index_meta ADD COLUMN page_count INTEGER",
        # received_at_ms: sunucunun kaydi kabul ettigi an (SUNUCU saati).
        # /sync/pull imleci bunu kullanir; boylece istemci saati geride olsa
        # bile push edilen kayit diger cihazlarca cekilir. updated_at_ms yalniz
        # LWW cakisma cozumunde kullanilir.
        "ALTER TABLE positions ADD COLUMN received_at_ms INTEGER",
        "ALTER TABLE annotations ADD COLUMN received_at_ms INTEGER",
        "ALTER TABLE pdf_favorites ADD COLUMN received_at_ms INTEGER",
        "ALTER TABLE pdf_recent ADD COLUMN received_at_ms INTEGER",
        "ALTER TABLE reading_goals ADD COLUMN received_at_ms INTEGER",
        "ALTER TABLE bookmarks ADD COLUMN received_at_ms INTEGER",
        "ALTER TABLE pomodoro_sessions ADD COLUMN received_at_ms INTEGER",
    ]:
        try:
            conn.execute(stmt)
        except sqlite3.OperationalError:
            pass  # column already exists

    # received_at_ms backfill: mevcut kayitlar icin en iyi tahmin (legacy
    # updated_at/opened_at saniye kolonlarina kadar dus). Idempotent.
    for stmt in [
        "UPDATE positions SET received_at_ms = COALESCE(updated_at_ms, updated_at * 1000) WHERE received_at_ms IS NULL",
        "UPDATE annotations SET received_at_ms = COALESCE(updated_at_ms, updated_at * 1000) WHERE received_at_ms IS NULL",
        "UPDATE pdf_favorites SET received_at_ms = COALESCE(updated_at_ms, updated_at * 1000) WHERE received_at_ms IS NULL",
        "UPDATE pdf_recent SET received_at_ms = COALESCE(opened_at_ms, opened_at * 1000) WHERE received_at_ms IS NULL",
        "UPDATE reading_goals SET received_at_ms = COALESCE(updated_at_ms, updated_at * 1000) WHERE received_at_ms IS NULL",
        "UPDATE bookmarks SET received_at_ms = updated_at_ms WHERE received_at_ms IS NULL",
        "UPDATE pomodoro_sessions SET received_at_ms = updated_at_ms WHERE received_at_ms IS NULL",
    ]:
        try:
            conn.execute(stmt)
        except sqlite3.OperationalError:
            pass  # kolon/tablo henuz yok (sonraki CREATE'ler halleder)

    # Backfill stroke_uuid for existing annotations
    conn.execute(
        "UPDATE annotations SET stroke_uuid = 'legacy-' || id WHERE stroke_uuid IS NULL"
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_annotations_stroke_uuid ON annotations(stroke_uuid)"
    )

    # Recreate reading_goals table with sync columns if needed
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS reading_goals (
            doc_id          TEXT NOT NULL,
            date            TEXT NOT NULL,
            start_page      INTEGER NOT NULL DEFAULT 1,
            target_pages    INTEGER NOT NULL DEFAULT 0,
            updated_at_ms   INTEGER,
            updated_by_device TEXT,
            deleted_at_ms   INTEGER,
            PRIMARY KEY (doc_id, date)
        )
        """
    )

    # Add sync columns to reading_goals if missing
    for stmt in [
        "ALTER TABLE reading_goals ADD COLUMN updated_at_ms INTEGER",
        "ALTER TABLE reading_goals ADD COLUMN updated_by_device TEXT",
        "ALTER TABLE reading_goals ADD COLUMN deleted_at_ms INTEGER",
    ]:
        try:
            conn.execute(stmt)
        except sqlite3.OperationalError:
            pass

    # Not belgeleri (zengin metin + el yazisi). Icerik JSON olarak saklanir;
    # .belge dosyalari pdf_dir() altinda PDF'lerle yan yana durur. Sync icin
    # tablo yetkili kaynaktir; PUT hem tabloyu hem dosyayi yazar.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS notes (
            note_doc_id      TEXT PRIMARY KEY,
            relative_path    TEXT NOT NULL,
            title            TEXT NOT NULL DEFAULT '',
            content          TEXT NOT NULL DEFAULT '{}',
            updated_at_ms    INTEGER NOT NULL,
            updated_by_device TEXT,
            deleted_at_ms    INTEGER
        )
        """
    )


def _migration_6_cards(conn):
    """Faz 25: aralikli tekrar (spaced repetition) veri modeli.

    Uc tablo, ucu de jenerik sync registry'sine (sync.py) baglanir:
      cards         -> LWW + tombstone (deleted_at_ms), etiketler JSON dizi
      review_state  -> kart basina SM-2 durumu, LWW, tombstone yok
      review_log    -> append-only; log_uuid tekil, guncellenmez/silinmez.
                       Jenerik LWW makinesi 'updated_by_device' kolonu bekler;
                       bu tabloda o kolon fixture'daki 'device' degerini tutar.
    """
    conn.execute(
        """
        CREATE TABLE cards (
            card_uuid         TEXT PRIMARY KEY,
            tip               TEXT NOT NULL CHECK(tip IN ('qa','cloze','madde')),
            on_yuz            TEXT NOT NULL DEFAULT '',
            arka_yuz          TEXT NOT NULL DEFAULT '',
            cloze_metin       TEXT NOT NULL DEFAULT '',
            etiketler         TEXT NOT NULL DEFAULT '[]',
            kaynak_tipi       TEXT NOT NULL CHECK(kaynak_tipi IN ('pdf','madde','manuel')),
            kaynak_ref        TEXT,
            durum             TEXT NOT NULL CHECK(durum IN ('taslak','onayli','askida')),
            uretim            TEXT NOT NULL CHECK(uretim IN ('manuel','ai')),
            updated_at_ms     INTEGER NOT NULL,
            updated_by_device TEXT,
            received_at_ms    INTEGER,
            deleted_at_ms     INTEGER
        )
        """
    )
    conn.execute("CREATE INDEX idx_cards_durum ON cards(durum, deleted_at_ms)")
    conn.execute(
        """
        CREATE TABLE review_state (
            card_uuid         TEXT PRIMARY KEY,
            due_at_ms         INTEGER NOT NULL,
            interval_gun      INTEGER NOT NULL DEFAULT 0,
            ease              REAL NOT NULL DEFAULT 2.5,
            tekrar_sayisi     INTEGER NOT NULL DEFAULT 0,
            lapse_sayisi      INTEGER NOT NULL DEFAULT 0,
            updated_at_ms     INTEGER NOT NULL,
            updated_by_device TEXT,
            received_at_ms    INTEGER
        )
        """
    )
    conn.execute("CREATE INDEX idx_review_state_due ON review_state(due_at_ms)")
    conn.execute(
        """
        CREATE TABLE review_log (
            log_uuid          TEXT PRIMARY KEY,
            card_uuid         TEXT NOT NULL,
            cevap             INTEGER NOT NULL,
            cevap_suresi_ms   INTEGER NOT NULL DEFAULT 0,
            reviewed_at_ms    INTEGER NOT NULL,
            updated_by_device TEXT,
            received_at_ms    INTEGER
        )
        """
    )
    conn.execute("CREATE INDEX idx_review_log_card ON review_log(card_uuid, reviewed_at_ms)")


# Numarali migrasyonlar. Yeni sema degisikligi = listeye YENI bir
# _migration_N fonksiyonu ekle. Bir migrasyon yalnizca BIR kez calisir;
# artik try/except ALTER desenine gerek yok, ciplak ALTER yeterli.
def _migration_7_drop_cards(conn):
    """Kart modulu sokuldu (2026-07-24): kullanici bilgi karti projesini iptal
    etti (muessir PDF'leri zaten cikmis soru bankasi). Migration 6'nin kurdugu
    tablolar tum veriyle birlikte dusurulur; migration zinciri bozulmasin diye
    6 numara tarihte kalir (yeni DB'de kur-ve-dusur, ucuz ve idempotent).
    """
    for t in ("cards", "review_state", "review_log"):
        conn.execute(f"DROP TABLE IF EXISTS {t}")


MIGRATIONS = [
    _migration_1_legacy_consolidation,
    _migration_2_legislation,
    _migration_3_legislation_position,
    _migration_4_madde_notes,
    _migration_5_legislation_changes,
    _migration_6_cards,
    _migration_7_drop_cards,
]


def run_migrations(conn):
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    for i, mig in enumerate(MIGRATIONS[current:], start=current + 1):
        mig(conn)
        conn.execute(f"PRAGMA user_version = {i}")


def init_db():
    with db() as conn:
        run_migrations(conn)
# Her profilin veritabanini ayri ayri olustur/migrate et.
for _p in PROFILES:
    with use_profile(_p):
        init_db()


def safe_folder_name(name: str) -> str:
    """Validate and return a single folder name. Reject slashes, backslashes, control chars, '..'."""
    if not name or not name.strip():
        raise HTTPException(status_code=400, detail="Bos klasor adi")
    if any(c in name for c in "/\\"):
        raise HTTPException(status_code=400, detail="Gecersiz klasor adi: / veya \\ iceremez")
    if any(ord(c) < 32 for c in name):
        raise HTTPException(status_code=400, detail="Gecersiz klasor adi: kontrol karakteri iceremez")
    if name == ".." or name.startswith("../") or name.startswith("..\\"):
        raise HTTPException(status_code=400, detail="Gecersiz klasor adi")
    return name.strip()


def safe_library_path(relative: str | None = None) -> Path:
    """Resolve relative path under pdf_dir(). Reject path traversal attempts."""
    if relative is None or relative == "":
        return pdf_dir()
    if relative.startswith("/") or relative.startswith("\\") or "\\" in relative:
        raise HTTPException(status_code=400, detail="Gecersiz yol")
    if ".." in Path(relative).parts:
        raise HTTPException(status_code=400, detail="Gecersiz yol: .. iceremez")
    target = (pdf_dir() / relative).resolve()
    try:
        target.relative_to(pdf_dir().resolve())
    except ValueError:
        raise HTTPException(status_code=400, detail="Gecersiz yol: PDF kutuphanesi disina cikamaz")
    return target


def safe_video_path(relative: str | None = None) -> Path:
    """Resolve relative path under video_dir(). Reject path traversal attempts."""
    if relative is None or relative == "":
        return video_dir()
    if relative.startswith("/") or relative.startswith("\\") or "\\" in relative:
        raise HTTPException(status_code=400, detail="Gecersiz yol")
    if ".." in Path(relative).parts:
        raise HTTPException(status_code=400, detail="Gecersiz yol: .. iceremez")
    target = (video_dir() / relative).resolve()
    try:
        target.relative_to(video_dir().resolve())
    except ValueError:
        raise HTTPException(status_code=400, detail="Gecersiz yol: video kutuphanesi disina cikamaz")
    return target


def _video_item(path: Path) -> dict:
    """Return standard video item dict (id, name, relative_path, size, modified)."""
    rel = path.relative_to(video_dir()).as_posix()
    stat = path.stat()
    return {
        "id": doc_id_for(rel),
        "name": path.stem,
        "relative_path": rel,
        "size": stat.st_size,
        "modified": int(stat.st_mtime),
    }


# Video sure (saniye) cache'i: rel -> (mtime, size, duration). ffprobe pahali
# oldugu icin dosya degismedikce tekrar olculmez.
FFPROBE = shutil.which("ffprobe")
_VIDEO_DURATION_CACHE: dict[str, tuple[float, int, float]] = {}


def _video_duration(path: Path) -> float | None:
    if not FFPROBE:
        return None
    try:
        stat = path.stat()
    except OSError:
        return None
    # Cache anahtari profil id + goreli yol (profiller arasi yol cakismasini onler).
    rel = f"{current_profile().id}/{path.relative_to(video_dir()).as_posix()}"
    cached = _VIDEO_DURATION_CACHE.get(rel)
    if cached and cached[0] == stat.st_mtime and cached[1] == stat.st_size:
        return cached[2]
    try:
        out = subprocess.run(
            [
                FFPROBE, "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            capture_output=True, text=True, timeout=20,
        )
        dur = float(out.stdout.strip())
    except (ValueError, subprocess.SubprocessError, OSError):
        return None
    _VIDEO_DURATION_CACHE[rel] = (stat.st_mtime, stat.st_size, dur)
    return dur


def _warm_video_durations() -> None:
    """Acilista sureleri olcup cache'e doldur (ilk /videos hizli donsun)."""
    for path in video_dir().rglob("*"):
        if path.is_file() and path.suffix.lower() in VIDEO_EXTS:
            _video_duration(path)


FFMPEG = shutil.which("ffmpeg")


def _faststart_video(profile: Profile, target: Path) -> None:
    """Arka planda mp4/m4v icin faststart remux uygula (seek akicilassin).

    ffmpeg yoksa veya islem basarisizsa sessizce atla; hedef dosyaya dokunmaz.
    Profil contextvar'ini garantilemek icin use_profile ile sarmali.
    """
    if not FFMPEG:
        return
    if target.suffix.lower() not in (".mp4", ".m4v"):
        return
    with use_profile(profile):
        if not target.exists():
            return
        tmp = target.with_suffix(target.suffix + ".faststart.tmp")
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                return
        try:
            result = subprocess.run(
                [
                    FFMPEG, "-y", "-i", str(target),
                    "-c", "copy", "-movflags", "+faststart",
                    str(tmp),
                ],
                capture_output=True, timeout=60 * 30,
            )
        except (subprocess.SubprocessError, OSError):
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass
            return
        if result.returncode != 0 or not tmp.exists():
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass
            return
        try:
            # Orijinal boyut/konteksti korumak icin tmp -> target tasi.
            os.replace(tmp, target)
        except OSError:
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass


def find_video_by_id(doc_id: str) -> Path | None:
    for path in video_dir().rglob("*"):
        if path.is_file() and path.suffix.lower() in VIDEO_EXTS:
            rel = path.relative_to(video_dir()).as_posix()
            if doc_id_for(rel) == doc_id:
                return path
    return None


def _startup_reindex() -> None:
    for p in PROFILES:
        with use_profile(p):
            reindex_all()


def _startup_warm() -> None:
    for p in PROFILES:
        with use_profile(p):
            _warm_video_durations()


# 90 gunden eski tombstone'lar temizlenir. Bilinen odun: 90+ gun cevrimdisi
# kalan bir cihaz silinmis kaydi "diriltebilir". Tek kullanici + 2 dk sync
# araligi icin kabul edilebilir.
TOMBSTONE_TTL_MS = 90 * 24 * 60 * 60 * 1000


def cleanup_tombstones(now_ms: int | None = None) -> None:
    esik = (now_ms if now_ms is not None else int(time.time() * 1000)) - TOMBSTONE_TTL_MS
    with db() as conn:
        conn.execute("DELETE FROM deleted_docs WHERE deleted_at_ms < ?", (esik,))
        for table in ("bookmarks", "pomodoro_sessions", "annotations"):
            conn.execute(
                f"DELETE FROM {table} WHERE deleted_at_ms IS NOT NULL AND deleted_at_ms < ?",
                (esik,),
            )


def _startup_cleanup() -> None:
    for p in PROFILES:
        with use_profile(p):
            cleanup_tombstones()


def doc_id_for(relative_path: str) -> str:
    return hashlib.sha1(relative_path.encode("utf-8")).hexdigest()[:16]


async def check_auth(x_auth_token: str = Header(default="")) -> Profile:
    # Async oldugu icin contextvar olay dongusu (event loop) baglaminda set edilir;
    # FastAPI sync endpoint'i threadpool'a aktarirken bu baglami kopyalar, boylece
    # db()/pdf_dir()/video_dir() dogru profili gorur.
    for p in PROFILES:
        if secrets.compare_digest(x_auth_token, p.token):
            _current_profile.set(p)
            return p
    raise HTTPException(status_code=401, detail="Gecersiz token")


def find_pdf_by_id(doc_id: str) -> Path | None:
    with db() as conn:
        row = conn.execute(
            "SELECT relative_path FROM pdf_index_meta WHERE doc_id = ?",
            (doc_id,),
        ).fetchone()
    if row:
        path = pdf_dir() / row["relative_path"]
        if path.exists():
            return path
    for path in pdf_dir().rglob("*.pdf"):
        rel = path.relative_to(pdf_dir()).as_posix()
        if doc_id_for(rel) == doc_id:
            return path
    return None


def find_note_by_id(doc_id: str) -> Path | None:
    # Cift-depo: once notes tablosundan relative_path ile hizli cozum (deleted degil).
    with db() as conn:
        row = conn.execute(
            "SELECT relative_path FROM notes WHERE note_doc_id = ? AND deleted_at_ms IS NULL",
            (doc_id,),
        ).fetchone()
    if row:
        path = pdf_dir() / row["relative_path"]
        if path.exists():
            return path
    # Tablo yoksaysa (yeni/manuel eklenen) dosya taramasi: yetkili kaynak dosyadir.
    for path in pdf_dir().rglob(f"*{NOTE_EXT}"):
        rel = path.relative_to(pdf_dir()).as_posix()
        if doc_id_for(rel) == doc_id:
            return path
    return None


def _pdf_paths_by_doc_ids(doc_ids: list[str]) -> dict[str, Path]:
    if not doc_ids:
        return {}
    wanted = set(doc_ids)
    found: dict[str, Path] = {}
    placeholders = ",".join("?" for _ in doc_ids)
    with db() as conn:
        rows = conn.execute(
            f"SELECT doc_id, relative_path FROM pdf_index_meta WHERE doc_id IN ({placeholders})",
            doc_ids,
        ).fetchall()
    for row in rows:
        path = pdf_dir() / row["relative_path"]
        if path.exists():
            found[row["doc_id"]] = path
    missing = wanted - set(found)
    if missing:
        for path in pdf_dir().rglob("*.pdf"):
            rel = path.relative_to(pdf_dir()).as_posix()
            did = doc_id_for(rel)
            if did in missing:
                found[did] = path
                missing.remove(did)
                if not missing:
                    break
    return found


def _transfer_doc_id(conn: sqlite3.Connection, old_id: str, new_id: str, new_rel: str, new_name: str) -> None:
    for table in DOC_ID_TABLES:
        pk = DOC_ID_PK.get(table, "doc_id")
        conn.execute(f"UPDATE {table} SET {pk} = ? WHERE {pk} = ?", (new_id, old_id))
    conn.execute("UPDATE pdf_text SET doc_id = ? WHERE doc_id = ?", (new_id, old_id))
    conn.execute(
        "UPDATE pdf_index_meta SET doc_id = ?, relative_path = ?, name = ? WHERE doc_id = ?",
        (new_id, new_rel, new_name, old_id),
    )


def _delete_doc_data(conn: sqlite3.Connection, doc_id: str, deleted_at_ms: int | None = None) -> None:
    for table in DOC_ID_TABLES:
        pk = DOC_ID_PK.get(table, "doc_id")
        conn.execute(f"DELETE FROM {table} WHERE {pk} = ?", (doc_id,))
    conn.execute("DELETE FROM pdf_text WHERE doc_id = ?", (doc_id,))
    conn.execute("DELETE FROM pdf_index_meta WHERE doc_id = ?", (doc_id,))
    if deleted_at_ms is not None:
        conn.execute(
            "INSERT OR REPLACE INTO deleted_docs (doc_id, deleted_at_ms) VALUES (?, ?)",
            (doc_id, deleted_at_ms),
        )


def _validate_pdf_upload(data: bytes) -> None:
    if not data:
        raise HTTPException(status_code=400, detail="Bos dosya")
    if len(data) > MAX_PDF_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="PDF cok buyuk")
    if not data.startswith(b"%PDF"):
        raise HTTPException(status_code=400, detail="Gecersiz PDF")


def _unique_target(folder: Path, name: str, ext: str) -> Path:
    """Return a non-existent path under folder with the given extension.

    Name collisions get (1), (2), ... suffixes. `ext` must include the leading
    dot (e.g. ".pdf", ".mp4") and is enforced on the resulting file name.
    """
    safe = Path(name).name.strip()
    stem = Path(safe).stem if safe else "dosya"
    if not stem:
        stem = "dosya"
    target = folder / f"{stem}{ext}"
    if not target.exists():
        return target
    i = 1
    while True:
        target = folder / f"{stem}({i}){ext}"
        if not target.exists():
            return target
        i += 1


def _unique_pdf_target(folder: Path, name: str) -> Path:
    """Return a non-existent PDF path under folder. Name collisions get (1), (2), etc."""
    return _unique_target(folder, name, ".pdf")


def _pdf_item(path: Path) -> dict:
    """Return standard PDF item dict (id, name, relative_path, size, modified)."""
    rel = path.relative_to(pdf_dir()).as_posix()
    stat = path.stat()
    return {
        "id": doc_id_for(rel),
        "name": path.stem,
        "relative_path": rel,
        "size": stat.st_size,
        "modified": int(stat.st_mtime),
    }


def _doc_progress_maps(conn: sqlite3.Connection) -> tuple[dict[str, int], dict[str, int]]:
    page_counts = {
        row["doc_id"]: row["page_count"]
        for row in conn.execute(
            "SELECT doc_id, page_count FROM pdf_index_meta WHERE page_count IS NOT NULL"
        ).fetchall()
    }
    current_pages = {
        row["doc_id"]: row["page"]
        for row in conn.execute(
            "SELECT doc_id, page FROM positions WHERE deleted_at_ms IS NULL"
        ).fetchall()
    }
    return page_counts, current_pages


def _pdf_item_with_meta(
    path: Path,
    favorite_ids: set[str] | None = None,
    page_counts: dict[str, int] | None = None,
    current_pages: dict[str, int] | None = None,
) -> dict:
    item = _pdf_to_dict(path)
    doc_id = item["id"]
    item["favorite"] = doc_id in (favorite_ids or set())
    item["page_count"] = (page_counts or {}).get(doc_id)
    item["current_page"] = (current_pages or {}).get(doc_id)
    return item


def index_pdf(path: Path) -> None:
    """Tek bir PDF'i (yeniden) indeksler."""
    rel = path.relative_to(pdf_dir()).as_posix()
    doc_id = doc_id_for(rel)
    stat = path.stat()
    try:
        doc = fitz.open(path)
    except Exception:
        return
    try:
        with db() as conn:
            conn.execute("DELETE FROM pdf_text WHERE doc_id = ?", (doc_id,))
            for i in range(doc.page_count):
                text = doc.load_page(i).get_text("text")
                if text and text.strip():
                    conn.execute(
                        "INSERT INTO pdf_text (doc_id, page, content) VALUES (?, ?, ?)",
                        (doc_id, i + 1, text),
                    )
            conn.execute(
                """
                INSERT INTO pdf_index_meta (doc_id, relative_path, name, size, modified, indexed_at, page_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(doc_id) DO UPDATE SET
                    relative_path=excluded.relative_path, name=excluded.name,
                    size=excluded.size, modified=excluded.modified,
                    indexed_at=excluded.indexed_at, page_count=excluded.page_count
                """,
                (doc_id, rel, path.stem, stat.st_size, int(stat.st_mtime), int(time.time()), doc.page_count),
            )
    finally:
        doc.close()


def reindex_all() -> dict:
    """Yeni/degisen PDF'leri indeksler, silinmis olanlari temizler."""
    seen = set()
    indexed = 0
    for pdf_path in pdf_dir().rglob("*.pdf"):
        rel = pdf_path.relative_to(pdf_dir()).as_posix()
        did = doc_id_for(rel)
        seen.add(did)
        stat = pdf_path.stat()
        with db() as conn:
            row = conn.execute(
                "SELECT size, modified, page_count FROM pdf_index_meta WHERE doc_id = ?", (did,)
            ).fetchone()
        if row is None or row["size"] != stat.st_size or row["modified"] != int(stat.st_mtime) or row["page_count"] is None:
            index_pdf(pdf_path)
            indexed += 1
    with db() as conn:
        rows = conn.execute("SELECT doc_id FROM pdf_index_meta").fetchall()
        for r in rows:
            if r["doc_id"] not in seen:
                conn.execute("DELETE FROM pdf_text WHERE doc_id = ?", (r["doc_id"],))
                conn.execute("DELETE FROM pdf_index_meta WHERE doc_id = ?", (r["doc_id"],))
    return {"indexed": indexed, "total": len(seen)}


def _fts_query(q: str) -> str:
    """Kullanici girdisini guvenli FTS5 sorgusuna cevirir."""
    terms = [t for t in q.replace('"', " ").split() if t]
    if not terms:
        return ""
    return " ".join(f'"{t}"*' for t in terms)


class PositionIn(BaseModel):
    page: int
    device: str | None = None


class TaskIn(BaseModel):
    date: str
    subject: str
    target_minutes: int = 0


class TaskUpdate(BaseModel):
    subject: str | None = None
    target_minutes: int | None = None
    done: bool | None = None


class AnnotationIn(BaseModel):
    page: int
    kind: str
    color: int
    width: float
    points: list[list[float]]
    text: str | None = None
    font_size: float | None = None
    font_family: str | None = None
    device: str | None = None
    stroke_uuid: str | None = None


class FolderCreateIn(BaseModel):
    path: str = ""
    name: str


class FolderRenameIn(BaseModel):
    path: str
    new_name: str


class PdfMoveCopyIn(BaseModel):
    target_folder: str = ""


class FavoriteIn(BaseModel):
    favorite: bool


class ReadingGoalIn(BaseModel):
    start_page: int
    target_pages: int = 50


class SyncPositionPush(BaseModel):
    doc_id: str
    page: int
    updated_at_ms: int
    updated_by_device: str
    deleted_at_ms: int | None = None


class SyncAnnotationPush(BaseModel):
    stroke_uuid: str
    doc_id: str
    page: int
    kind: str
    color: int
    width: float
    points: list[list[float]]
    text: str | None = None
    font_size: float | None = None
    font_family: str | None = None
    updated_at_ms: int
    updated_by_device: str
    deleted_at_ms: int | None = None


class SyncFavoritePush(BaseModel):
    doc_id: str
    favorite: bool
    updated_at_ms: int
    updated_by_device: str


class SyncRecentPush(BaseModel):
    doc_id: str
    opened_at_ms: int
    updated_by_device: str


class SyncGoalPush(BaseModel):
    doc_id: str
    date: str
    start_page: int
    target_pages: int
    updated_at_ms: int
    updated_by_device: str
    deleted_at_ms: int | None = None


class SyncBookmarkPush(BaseModel):
    bookmark_uuid: str
    doc_id: str
    page: int
    label: str = ''
    updated_at_ms: int
    updated_by_device: str
    deleted_at_ms: int | None = None


class SyncPomodoroPush(BaseModel):
    session_uuid: str
    date: str
    subject: str
    phase: str
    minutes: int
    started_at_ms: int
    updated_at_ms: int
    updated_by_device: str
    deleted_at_ms: int | None = None


class SyncLegislationPositionPush(BaseModel):
    mevzuat_no: str
    madde_ref: str
    updated_at_ms: int
    updated_by_device: str
    deleted_at_ms: int | None = None


class SyncMaddeNotePush(BaseModel):
    note_uuid: str
    madde_ref: str
    kind: str
    renk: int | None = None
    secili_metin_araligi: str | None = None
    text: str = ''
    updated_at_ms: int
    updated_by_device: str
    deleted_at_ms: int | None = None


class SyncPushBody(BaseModel):
    device_id: str
    positions: list[SyncPositionPush] = []
    annotations: list[SyncAnnotationPush] = []
    favorites: list[SyncFavoritePush] = []
    recent: list[SyncRecentPush] = []
    reading_goals: list[SyncGoalPush] = []
    bookmarks: list[SyncBookmarkPush] = []
    pomodoro_sessions: list[SyncPomodoroPush] = []
    legislation_positions: list[SyncLegislationPositionPush] = []
    madde_notes: list[SyncMaddeNotePush] = []


def _reindex_profile(profile: Profile) -> None:
    with use_profile(profile):
        reindex_all()


def _reading_goal_to_dict(row) -> dict:
    return {
        "doc_id": row["doc_id"],
        "date": row["date"],
        "start_page": row["start_page"],
        "target_pages": row["target_pages"],
        "updated_at": row["updated_at"],
        "updated_at_ms": row["updated_at_ms"] or row["updated_at"] * 1000,
        "updated_by_device": row["updated_by_device"],
        "deleted_at_ms": row["deleted_at_ms"],
    }


def _pdf_to_dict(pdf_path: Path) -> dict:
    rel = pdf_path.relative_to(pdf_dir()).as_posix()
    stat = pdf_path.stat()
    return {
        "id": doc_id_for(rel),
        "name": pdf_path.stem,
        "relative_path": rel,
        "size": stat.st_size,
        "modified": int(stat.st_mtime),
        "kind": "pdf",
    }


def _note_item(path: Path) -> dict:
    # .belge dosyasi icin kutuphane listesi ogesi. title dosyadaki JSON'dan okunur;
    # bozuk dosyada bos title ile duser (liste yine de gosterir).
    rel = path.relative_to(pdf_dir()).as_posix()
    stat = path.stat()
    title = ""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        title = data.get("title", "") or ""
    except Exception:
        pass
    return {
        "id": doc_id_for(rel),
        "name": path.stem,
        "relative_path": rel,
        "size": stat.st_size,
        "modified": int(stat.st_mtime),
        "title": title,
        "kind": "note",
    }


def _note_upsert(doc_id: str, rel: str, title: str, content_text: str, updated_at_ms: int, updated_by_device: str | None = None) -> None:
    # Cift-depo yazimi: notes tablosuna UPSERT. Dosyaya yazma cagiranda yapilir;
    # bu fonksiyon yalnizca tabloyu gunceller (deleted_at_ms'i temizler).
    with db() as conn:
        conn.execute(
            """
            INSERT INTO notes (note_doc_id, relative_path, title, content, updated_at_ms, updated_by_device, deleted_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(note_doc_id) DO UPDATE SET
                relative_path=excluded.relative_path, title=excluded.title,
                content=excluded.content, updated_at_ms=excluded.updated_at_ms,
                updated_by_device=excluded.updated_by_device, deleted_at_ms=NULL
            """,
            (doc_id, rel, title, content_text, updated_at_ms, updated_by_device),
        )


def _note_sync_from_file(path: Path, doc_id: str) -> None:
    # Tablo yoksussa/yanciysa dosyayi yetkili kaynak kabul edip senkla. Dosya
    # bozuksa title/stem ve mtime ile duser; icerik birebir tabloya yazilir.
    rel = path.relative_to(pdf_dir()).as_posix()
    try:
        text = path.read_text(encoding="utf-8")
        data = json.loads(text)
        title = data.get("title", "") or path.stem
        uam = int(data.get("updated_at_ms", int(path.stat().st_mtime * 1000)))
    except Exception:
        text = path.read_text(encoding="utf-8")
        title = path.stem
        uam = int(path.stat().st_mtime * 1000)
    _note_upsert(doc_id, rel, title, text, uam)


def _task_row_to_dict(row) -> dict:
    return {
        "id": row["id"],
        "date": row["date"],
        "subject": row["subject"],
        "target_minutes": row["target_minutes"],
        "done": bool(row["done"]),
        "updated_at": row["updated_at"],
    }


def _app_version_info() -> dict:
    version = None
    build = None
    if APP_PUBSPEC_PATH.exists():
        m = re.search(
            r"^version:\s*([0-9][0-9.]*)\+(\d+)",
            APP_PUBSPEC_PATH.read_text(encoding="utf-8"),
            re.MULTILINE,
        )
        if m:
            version = m.group(1)
            build = int(m.group(2))
    info = {"version": version, "build": build, "apk_exists": APK_PATH.exists()}
    if info["apk_exists"]:
        stat = APK_PATH.stat()
        info["apk_size"] = stat.st_size
        info["apk_modified"] = int(stat.st_mtime)
    return info


# Alt cizgili yardimcilar dahil her seyi disari ac; routerlar tek
# 'from core import *' ile kullanir.
__all__ = [n for n in dir() if not n.startswith('__')]
