"""Ingest full legislation through the installed Emsal-mcp source adapter.

This module has no HTTP scraper.  It uses Emsal-mcp's own search and source
client interfaces, stores the raw snapshot, and refuses incomplete documents.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from mevzuat_parser import PARSER_VERSION, article_to_row, parse_legislation

DEFAULT_LAWS = {
    "2709": ("Türkiye Cumhuriyeti Anayasası", "Anayasa"),
    "4721": ("Türk Medeni Kanunu", "TMK"),
    "6098": ("Türk Borçlar Kanunu", "TBK"),
    "6102": ("Türk Ticaret Kanunu", "TTK"),
    "6100": ("Hukuk Muhakemeleri Kanunu", "HMK"),
    "5237": ("Türk Ceza Kanunu", "TCK"),
    "5271": ("Ceza Muhakemesi Kanunu", "CMK"),
    "2577": ("İdari Yargılama Usulü Kanunu", "İYUK"),
    "2004": ("İcra ve İflas Kanunu", "İİK"),
    "4857": ("İş Kanunu", "İşK"),
    "5718": ("Milletlerarası Özel Hukuk ve Usul Hukuku Hakkında Kanun", "MÖHUK"),
}

# Official terminal article numbers. This is a completeness gate, not an
# inferred article count: extra/temporary/lettered articles may make the parsed
# row count larger, but a document ending before this number is incomplete.
OFFICIAL_FINAL_ARTICLE = {
    "2709": 177, "4721": 1030, "6098": 649, "6102": 1535, "6100": 452,
    "5237": 345, "5271": 335, "2577": 65, "2004": 370,
    "4857": 122, "5718": 66,
}


def _search_document_id(mevzuat_no: str, emsal_command: str = "emsal-mcp") -> tuple[str, dict[str, Any]]:
    proc = None
    for attempt in range(4):
        proc = subprocess.run(
            [emsal_command, "legislation", "search", mevzuat_no, "--limit", "20", "--json"],
            capture_output=True, text=True, encoding="utf-8", check=False,
        )
        if proc.returncode == 0 and "429" not in proc.stdout:
            break
        if attempt < 3 and "429" in (proc.stdout + proc.stderr):
            time.sleep(min(60, 2 ** (attempt + 2)))
            continue
        break
    assert proc is not None
    if proc.returncode != 0:
        raise RuntimeError(f"Emsal-mcp search başarısız ({mevzuat_no}): {proc.stderr.strip()}")
    payload = json.loads(proc.stdout)
    candidates = [
        item for item in payload.get("results", [])
        if str(item.get("legislation_no", "")) == mevzuat_no
        and "YÜRÜRLÜKTEN KALDIRILMIŞ" not in str(item.get("title", "")).upper()
    ]
    if not candidates:
        raise RuntimeError(f"Emsal-mcp tam eşleşen mevzuat bulamadı: {mevzuat_no}")
    expected_title = DEFAULT_LAWS.get(mevzuat_no, ("", ""))[0].upper()
    candidates.sort(
        key=lambda item: (
            str(item.get("title", "")).strip().upper() != expected_title,
            str(item.get("legislation_type", "")).lower() not in {"kanun", "anayasa"},
            len(str(item.get("title", ""))),
        )
    )
    return str(candidates[0]["document_id"]), candidates[0]


async def _fetch_full_text(document_id: str) -> dict[str, Any]:
    # This is Emsal-mcp's installed adapter, not a second scraper.
    from emsal_mcp.sources.registry import get_source

    source = get_source("mevzuat")
    doc = None
    for attempt in range(4):
        try:
            doc = await source.get_document(document_id)
            break
        except Exception as exc:
            response = getattr(exc, "response", None)
            if getattr(response, "status_code", None) != 429 or attempt == 3:
                raise
            retry_after = response.headers.get("Retry-After") if response is not None else None
            delay = min(60.0, max(2.0, float(retry_after or (2 ** (attempt + 2)))))
            await asyncio.sleep(delay)
    if doc is None:
        raise RuntimeError(f"Emsal-mcp belgeyi döndürmedi: {document_id}")
    text = doc.text
    # Emsal-mcp currently converts HTML with lxml. Some very large official
    # texts contain malformed nesting; lxml closes the document early although
    # the adapter's raw base64 HTML is complete. Reparse that SAME Emsal-mcp
    # response with BeautifulSoup's tolerant stdlib-backed html.parser. This is
    # not a second scraper and performs no additional network access.
    raw = doc.raw if isinstance(doc.raw, dict) else {}
    data = raw.get("data", raw) if isinstance(raw, dict) else {}
    encoded = data.get("content") if isinstance(data, dict) else None
    if encoded:
        try:
            from bs4 import BeautifulSoup
            blob = base64.b64decode(encoded + "=" * (-len(encoded) % 4))
            html = blob.decode("utf-8", errors="replace")
            soup = BeautifulSoup(html, "html.parser")
            for tag in soup(["script", "style"]):
                tag.decompose()
            tolerant_text = "\n".join(line for line in soup.get_text("\n", strip=True).splitlines())
            if len(tolerant_text) > len(text):
                text = tolerant_text
        except Exception as exc:
            raise RuntimeError(f"Emsal-mcp ham mevzuat HTML'i dönüştürülemedi: {exc}") from exc
    return {
        "document_id": doc.document_id,
        "title": doc.title,
        "source": doc.source,
        "text": text,
        "content_status": getattr(doc.content_status, "value", str(doc.content_status)),
        "content_hash": hashlib.sha256(text.encode("utf-8")).hexdigest() if text else None,
        "metadata": doc.metadata,
    }


def fetch_full_text(document_id: str) -> dict[str, Any]:
    return asyncio.run(_fetch_full_text(document_id))


def _add_emsal_python_paths(emsal_command: str) -> None:
    """Allow the server venv to use a separately installed emsal-mcp CLI."""
    try:
        import emsal_mcp  # noqa: F401
        return
    except ImportError:
        pass
    executable = shutil.which(emsal_command) or emsal_command
    exe_path = Path(executable).resolve()
    candidates = [
        Path(os.environ["EMSAL_MCP_SOURCE"]) / "src"
        if os.environ.get("EMSAL_MCP_SOURCE") else None,
        Path.home() / "Emsal-mcp" / "src",
        exe_path.parent.parent / "Lib" / "site-packages",
    ]
    for candidate in candidates:
        if candidate and candidate.exists() and str(candidate) not in sys.path:
            sys.path.insert(0, str(candidate))
    try:
        import emsal_mcp  # noqa: F401
    except ImportError as exc:
        raise RuntimeError(
            "emsal_mcp Python paketi bulunamadı; EMSAL_MCP_SOURCE veya EMSAL_MCP_PYTHON ayarlayın"
        ) from exc


def ingest_one(
    conn,
    mevzuat_no: str,
    *,
    emsal_command: str = "emsal-mcp",
    fixture_dir: Path | None = None,
) -> dict[str, Any]:
    if fixture_dir is not None:
        fixture_path = fixture_dir / f"{mevzuat_no}.txt"
        golden_path = fixture_dir / f"{mevzuat_no}.json"
        if not fixture_path.is_file() or not golden_path.is_file():
            raise RuntimeError(f"Sabit mevzuat fixture'ı bulunamadı: {mevzuat_no}")
        golden = json.loads(golden_path.read_text(encoding="utf-8"))
        text = fixture_path.read_text(encoding="utf-8").strip()
        actual_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if actual_hash != golden.get("text_sha256"):
            raise RuntimeError(f"Fixture hash doğrulaması başarısız: {mevzuat_no}")
        document_id = str(golden["document_id"])
        search_meta = {
            "title": DEFAULT_LAWS[mevzuat_no][0],
            "legislation_type": "Anayasa" if mevzuat_no == "2709" else "Kanun",
        }
        document = {"document_id": document_id, "text": text, "content_status": "full"}
    else:
        _add_emsal_python_paths(emsal_command)
        document_id, search_meta = _search_document_id(mevzuat_no, emsal_command)
        document = fetch_full_text(document_id)
    text = str(document.get("text") or "")
    status = str(document.get("content_status") or "")
    if not text.strip() or status in {"metadata_only", "unavailable"}:
        raise RuntimeError(f"Tam metin yok, ingest reddedildi: {mevzuat_no} ({document_id}, {status})")
    parsed = parse_legislation(text, mevzuat_no)
    if parsed.errors:
        raise RuntimeError(f"Parser hatası {mevzuat_no}: " + " | ".join(parsed.errors[:10]))
    numeric = [
        int(component)
        for article in parsed.articles
        for component in [article.id.split("/m.", 1)[1]]
        if component.isdigit()
    ]
    expected_final = OFFICIAL_FINAL_ARTICLE[mevzuat_no]
    if not numeric or max(numeric) < expected_final:
        raise RuntimeError(
            f"Eksik mevzuat metni reddedildi: {mevzuat_no} son sayısal madde "
            f"{max(numeric) if numeric else 'yok'}, beklenen en az {expected_final}"
        )

    now_ms = int(time.time() * 1000)
    # Parser surumu hash'e katilir: ayni resmi metin, ayristirma duzeltmesi
    # sonrasi yeni snapshot olarak yayimlanir ve istemciler guncellemeyi gorur.
    snapshot_version = hashlib.sha256(
        f"p{PARSER_VERSION}|".encode("utf-8") + text.encode("utf-8")
    ).hexdigest()[:16]
    title = search_meta.get("title") or document.get("title") or DEFAULT_LAWS[mevzuat_no][0]
    short_name = DEFAULT_LAWS.get(mevzuat_no, (title, ""))[1]
    old_version_row = conn.execute("SELECT snapshot_version FROM legislation WHERE mevzuat_no = ?", (mevzuat_no,)).fetchone()
    old_articles = {r["id"]: r["metin"] for r in conn.execute("SELECT id, metin FROM legislation_article WHERE mevzuat_no = ?", (mevzuat_no,)).fetchall()}
    conn.execute(
        "INSERT INTO legislation(mevzuat_no, ad, kisa_ad, tur, snapshot_version, ingested_at_ms, raw_hash) "
        "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(mevzuat_no) DO UPDATE SET "
        "ad=excluded.ad, kisa_ad=excluded.kisa_ad, tur=excluded.tur, snapshot_version=excluded.snapshot_version, "
        "ingested_at_ms=excluded.ingested_at_ms, raw_hash=excluded.raw_hash",
        (mevzuat_no, title, short_name, search_meta.get("legislation_type", "Kanun"), snapshot_version, now_ms, hashlib.sha256(text.encode()).hexdigest()),
    )
    conn.execute("DELETE FROM legislation_article WHERE mevzuat_no = ?", (mevzuat_no,))
    changed = 0
    for order, article in enumerate(parsed.articles, start=1):
        row = article_to_row(article)
        conn.execute(
            "INSERT INTO legislation_article(id, mevzuat_no, sira, baslik, madde_no_raw, metin, metadata_json, snapshot_version) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (row["id"], mevzuat_no, order, row["baslik"], row["madde_no_raw"], row["metin"], json.dumps(row["metadata_json"], ensure_ascii=False), snapshot_version),
        )
        if old_version_row:
            if row["id"] not in old_articles:
                conn.execute("INSERT INTO legislation_change(madde_ref, old_version, new_version, degisiklik_ozeti, old_text, new_text, created_at_ms) VALUES (?, ?, ?, ?, NULL, ?, ?)", (row["id"], old_version_row["snapshot_version"], snapshot_version, "Madde eklendi", row["metin"], now_ms))
                changed += 1
            elif old_articles[row["id"]] != row["metin"]:
                conn.execute("INSERT INTO legislation_change(madde_ref, old_version, new_version, degisiklik_ozeti, old_text, new_text, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)", (row["id"], old_version_row["snapshot_version"], snapshot_version, "Madde metni değişti", old_articles[row["id"]], row["metin"], now_ms))
                changed += 1
    for removed_ref, old_text in old_articles.items():
        if not any(a.id == removed_ref for a in parsed.articles) and old_version_row:
            conn.execute("INSERT INTO legislation_change(madde_ref, old_version, new_version, degisiklik_ozeti, old_text, new_text, created_at_ms) VALUES (?, ?, ?, ?, ?, NULL, ?)", (removed_ref, old_version_row["snapshot_version"], snapshot_version, "Madde kaldırıldı", old_text, now_ms))
            changed += 1
    conn.execute(
        "INSERT OR REPLACE INTO legislation_snapshot(mevzuat_no, snapshot_version, raw_text, created_at_ms) VALUES (?, ?, ?, ?)",
        (mevzuat_no, snapshot_version, text, now_ms),
    )
    return {"mevzuat_no": mevzuat_no, "document_id": document_id, "articles": len(parsed.articles), "snapshot_version": snapshot_version, "changed_articles": changed, "warnings": parsed.warnings}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Emsal-mcp üzerinden mevzuat ingest")
    parser.add_argument("--mevzuat-no", action="append", dest="numbers", help="Tekrarlanabilir mevzuat numarası")
    parser.add_argument("--db", type=Path, help="Hedef SQLite DB; verilmezse profil DB'leri kullanılır")
    parser.add_argument("--fixture-dir", type=Path, help="Hash doğrulamalı sabit gerçek metinleri ağ yerine kullan")
    parser.add_argument("--emsal-command", default=os.environ.get("EMSAL_MCP", "emsal-mcp"))
    args = parser.parse_args(argv)
    numbers = args.numbers or list(DEFAULT_LAWS)
    unknown = [number for number in numbers if number not in DEFAULT_LAWS]
    if unknown:
        parser.error("Desteklenmeyen başlangıç mevzuat numarası: " + ", ".join(unknown))

    if args.db:
        import sqlite3
        conn = sqlite3.connect(args.db)
        try:
            # Standalone DB use still gets the complete canonical schema.
            from core import run_migrations
            run_migrations(conn)
            for number in numbers:
                with conn:
                    result = ingest_one(conn, number, emsal_command=args.emsal_command, fixture_dir=args.fixture_dir)
                print(json.dumps(result, ensure_ascii=True))
        finally:
            conn.close()
    else:
        import core
        for profile in core.PROFILES:
            with core.use_profile(profile), core.db() as conn:
                for number in numbers:
                    with conn:
                        result = ingest_one(conn, number, emsal_command=args.emsal_command, fixture_dir=args.fixture_dir)
                    print(json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
