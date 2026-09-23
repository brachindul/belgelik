import json

from fastapi import APIRouter, Depends, HTTPException

from core import check_auth, db

router = APIRouter()


@router.get("/legislation", dependencies=[Depends(check_auth)])
def list_legislation():
    with db() as conn:
        rows = conn.execute(
            """
            SELECT l.*, COUNT(a.id) AS article_count,
                   COALESCE(SUM(length(a.metin)), 0) AS text_bytes
            FROM legislation l
            LEFT JOIN legislation_article a ON a.mevzuat_no = l.mevzuat_no
            GROUP BY l.mevzuat_no
            ORDER BY l.ad COLLATE NOCASE
            """
        ).fetchall()
    return {
        "items": [
            {
                "mevzuat_no": r["mevzuat_no"],
                "ad": r["ad"],
                "kisa_ad": r["kisa_ad"],
                "tur": r["tur"],
                "snapshot_version": r["snapshot_version"],
                "article_count": r["article_count"],
                "size": r["text_bytes"],
                "ingested_at_ms": r["ingested_at_ms"],
            }
            for r in rows
        ]
    }


@router.get("/legislation/{mevzuat_no}/bundle", dependencies=[Depends(check_auth)])
def legislation_bundle(mevzuat_no: str):
    with db() as conn:
        law = conn.execute(
            "SELECT * FROM legislation WHERE mevzuat_no = ?", (mevzuat_no,)
        ).fetchone()
        if law is None:
            raise HTTPException(status_code=404, detail="Mevzuat bulunamadı")
        articles = conn.execute(
            "SELECT * FROM legislation_article WHERE mevzuat_no = ? ORDER BY sira",
            (mevzuat_no,),
        ).fetchall()
        changes = conn.execute("SELECT madde_ref, old_version, new_version, degisiklik_ozeti, old_text, new_text, created_at_ms FROM legislation_change WHERE madde_ref LIKE ? ORDER BY created_at_ms DESC", (f"{mevzuat_no}/%",)).fetchall()
    return {
        "mevzuat": {
            "mevzuat_no": law["mevzuat_no"],
            "ad": law["ad"],
            "kisa_ad": law["kisa_ad"],
            "tur": law["tur"],
            "snapshot_version": law["snapshot_version"],
            "ingested_at_ms": law["ingested_at_ms"],
            "raw_hash": law["raw_hash"],
        },
        "articles": [
            {
                "id": r["id"],
                "sira": r["sira"],
                "baslik": r["baslik"],
                "madde_no_raw": r["madde_no_raw"],
                "metin": r["metin"],
                "metadata": json.loads(r["metadata_json"]),
                "snapshot_version": r["snapshot_version"],
            }
            for r in articles
        ],
        "changes": [dict(r) for r in changes],
    }


@router.get("/legislation/changes", dependencies=[Depends(check_auth)])
def legislation_changes(mevzuat_no: str | None = None):
    with db() as conn:
        if mevzuat_no:
            rows = conn.execute("SELECT * FROM legislation_change WHERE madde_ref LIKE ? ORDER BY created_at_ms DESC", (f"{mevzuat_no}/%",)).fetchall()
        else:
            rows = conn.execute("SELECT * FROM legislation_change ORDER BY created_at_ms DESC").fetchall()
    return {"items": [dict(r) for r in rows]}
