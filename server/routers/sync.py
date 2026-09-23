from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Request
from fastapi.responses import FileResponse, Response
from core import *  # noqa: F401,F403

router = APIRouter()


@router.get("/favorites", dependencies=[Depends(check_auth)])
def list_favorites():
    with db() as conn:
        rows = conn.execute(
            "SELECT doc_id FROM pdf_favorites WHERE favorite = 1 ORDER BY updated_at DESC"
        ).fetchall()
        page_counts, current_pages = _doc_progress_maps(conn)
    doc_ids = [row["doc_id"] for row in rows]
    paths = _pdf_paths_by_doc_ids(doc_ids)
    items = []
    stale = []
    for doc_id in doc_ids:
        pdf_path = paths.get(doc_id)
        if pdf_path is None:
            stale.append(doc_id)
            continue
        items.append(_pdf_item_with_meta(pdf_path, {doc_id}, page_counts, current_pages))
    if stale:
        with db() as conn:
            for doc_id in stale:
                conn.execute("DELETE FROM pdf_favorites WHERE doc_id = ?", (doc_id,))
    return {"items": items}


@router.put("/favorites/{doc_id}", dependencies=[Depends(check_auth)])
def set_favorite(doc_id: str, body: FavoriteIn):
    pdf_path = find_pdf_by_id(doc_id)
    if pdf_path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")
    now = int(time.time())
    now_ms = int(time.time() * 1000)
    with db() as conn:
        conn.execute(
            """
            INSERT OR REPLACE INTO pdf_favorites
                (doc_id, favorite, updated_at, updated_at_ms, updated_by_device, received_at_ms)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (doc_id, 1 if body.favorite else 0, now, now_ms, "", now_ms),
        )
    return {"ok": True}


@router.get("/recent", dependencies=[Depends(check_auth)])
def list_recent(limit: int = 5):
    if limit < 1:
        limit = 1
    if limit > 20:
        limit = 20
    with db() as conn:
        rows = conn.execute(
            "SELECT doc_id FROM pdf_recent ORDER BY opened_at DESC LIMIT ?",
            (limit,),
        ).fetchall()
        page_counts, current_pages = _doc_progress_maps(conn)
    doc_ids = [row["doc_id"] for row in rows]
    paths = _pdf_paths_by_doc_ids(doc_ids)
    items = []
    stale = []
    for doc_id in doc_ids:
        pdf_path = paths.get(doc_id)
        if pdf_path is None:
            stale.append(doc_id)
            continue
        items.append(_pdf_item_with_meta(pdf_path, page_counts=page_counts, current_pages=current_pages))
    if stale:
        with db() as conn:
            for doc_id in stale:
                conn.execute("DELETE FROM pdf_recent WHERE doc_id = ?", (doc_id,))
    return {"items": items}


@router.post("/recent/{doc_id}", dependencies=[Depends(check_auth)])
def mark_recent(doc_id: str):
    pdf_path = find_pdf_by_id(doc_id)
    if pdf_path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")
    now = int(time.time())
    now_ms = int(time.time() * 1000)
    with db() as conn:
        conn.execute(
            """
            INSERT OR REPLACE INTO pdf_recent
                (doc_id, opened_at, opened_at_ms, updated_by_device, received_at_ms)
            VALUES (?, ?, ?, ?, ?)
            """,
            (doc_id, now, now_ms, "", now_ms),
        )
        # Keep only last 20
        conn.execute(
            "DELETE FROM pdf_recent WHERE doc_id NOT IN (SELECT doc_id FROM pdf_recent ORDER BY opened_at DESC LIMIT 20)"
        )
    return {"ok": True}


@router.delete("/recent/{doc_id}", dependencies=[Depends(check_auth)])
def delete_recent(doc_id: str):
    with db() as conn:
        conn.execute("DELETE FROM pdf_recent WHERE doc_id = ?", (doc_id,))
    return {"ok": True}


@router.get("/reading-goal/{doc_id}", dependencies=[Depends(check_auth)])
def get_reading_goal(doc_id: str, date: str):
    if find_pdf_by_id(doc_id) is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")
    with db() as conn:
        row = conn.execute(
            "SELECT * FROM reading_goals WHERE doc_id = ? AND date = ?",
            (doc_id, date),
        ).fetchone()
    return {"goal": _reading_goal_to_dict(row) if row else None}


@router.put("/reading-goal/{doc_id}", dependencies=[Depends(check_auth)])
def put_reading_goal(doc_id: str, date: str, body: ReadingGoalIn):
    if find_pdf_by_id(doc_id) is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")
    if body.start_page < 1:
        raise HTTPException(status_code=400, detail="Baslangic sayfasi 1 veya daha buyuk olmali")
    if body.target_pages < 1:
        raise HTTPException(status_code=400, detail="Hedef sayfa 1 veya daha buyuk olmali")
    now = int(time.time())
    now_ms = int(time.time() * 1000)
    with db() as conn:
        conn.execute(
            """
            INSERT INTO reading_goals
                (doc_id, date, start_page, target_pages, updated_at, updated_at_ms, updated_by_device, received_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(doc_id, date) DO UPDATE SET
                start_page = excluded.start_page,
                target_pages = excluded.target_pages,
                updated_at = excluded.updated_at,
                updated_at_ms = excluded.updated_at_ms,
                updated_by_device = excluded.updated_by_device,
                received_at_ms = excluded.received_at_ms,
                deleted_at_ms = NULL
            """,
            (doc_id, date, body.start_page, body.target_pages, now, now_ms, "", now_ms),
        )
        row = conn.execute(
            "SELECT * FROM reading_goals WHERE doc_id = ? AND date = ?",
            (doc_id, date),
        ).fetchone()
    return {"goal": _reading_goal_to_dict(row)}


@router.get("/position/{doc_id}", dependencies=[Depends(check_auth)])
def get_position(doc_id: str):
    with db() as conn:
        row = conn.execute(
            "SELECT page, updated_at, device FROM positions WHERE doc_id = ?",
            (doc_id,),
        ).fetchone()
    if row is None:
        return {"position": None}
    return {
        "position": {
            "page": row["page"],
            "updated_at": row["updated_at"],
            "device": row["device"],
        }
    }


@router.put("/position/{doc_id}", dependencies=[Depends(check_auth)])
def put_position(doc_id: str, body: PositionIn):
    now = int(time.time())
    now_ms = int(time.time() * 1000)
    with db() as conn:
        conn.execute(
            """
            INSERT INTO positions (doc_id, page, updated_at, updated_at_ms, updated_by_device, received_at_ms, device)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(doc_id) DO UPDATE SET
                page = excluded.page,
                updated_at = excluded.updated_at,
                updated_at_ms = excluded.updated_at_ms,
                updated_by_device = excluded.updated_by_device,
                received_at_ms = excluded.received_at_ms,
                device = excluded.device
            """,
            (doc_id, body.page, now, now_ms, body.device or "", now_ms, body.device),
        )
    return {"ok": True, "updated_at": now}


@router.get("/annotations/{doc_id}", dependencies=[Depends(check_auth)])
def list_annotations(doc_id: str):
    with db() as conn:
        rows = conn.execute(
            """
            SELECT * FROM annotations
            WHERE doc_id = ? AND deleted_at_ms IS NULL
            ORDER BY id
            """,
            (doc_id,),
        ).fetchall()
    return {
        "items": [
            {
                "id": r["id"],
                "stroke_uuid": r["stroke_uuid"],
                "page": r["page"],
                "kind": r["kind"],
                "color": r["color"],
                "width": r["width"],
                "points": json.loads(r["points"]),
                "text": r["text"],
                "font_size": r["font_size"],
                "font_family": r["font_family"],
                "updated_at_ms": r["updated_at_ms"] or r["updated_at"] * 1000,
                "updated_by_device": r["updated_by_device"] or r["device"],
                "deleted_at_ms": r["deleted_at_ms"],
            }
            for r in rows
        ]
    }


@router.post("/annotations/{doc_id}", dependencies=[Depends(check_auth)])
def add_annotation(doc_id: str, body: AnnotationIn):
    now = int(time.time())
    now_ms = int(time.time() * 1000)
    stroke_uuid = body.stroke_uuid or f"server-{now_ms}-{secrets.token_hex(6)}"
    with db() as conn:
        cur = conn.execute(
            """
            INSERT INTO annotations
                (stroke_uuid, doc_id, page, kind, color, width, points,
                 text, font_size, font_family,
                 updated_at, updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms, device)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
            """,
            (
                stroke_uuid,
                doc_id,
                body.page,
                body.kind,
                body.color,
                body.width,
                json.dumps(body.points),
                body.text,
                body.font_size,
                body.font_family,
                now,
                now_ms,
                body.device,
                now_ms,
                body.device,
            ),
        )
        new_id = cur.lastrowid
    return {"id": new_id, "stroke_uuid": stroke_uuid, "updated_at_ms": now_ms}


@router.delete("/annotations/{stroke_id}", dependencies=[Depends(check_auth)])
def delete_annotation(stroke_id: int):
    now_ms = int(time.time() * 1000)
    with db() as conn:
        conn.execute(
            """
            UPDATE annotations
            SET deleted_at_ms = ?, updated_at_ms = ?, received_at_ms = ?
            WHERE id = ?
            """,
            (now_ms, now_ms, now_ms, stroke_id),
        )
    return {"ok": True}


# --- Jenerik sync protokolu (v1 + v2 ortak registry) ---
# Veri modeli (tablolar) degismez; yalniz LWW/tombstone/pull mantigi tek yerde
# toplanir. Her varlik icin SQL ve alan eslemesi asagida acikca tanimlidir
# (davranis v1 ile birebir ayni kalsin diye).


@dataclass
class SyncSpec:
    key: str            # v1 body alani + pull yanit anahtari (cogul): 'positions'
    singular: str       # v2 entity adi (tekil): 'position'
    table: str
    pk_where: str       # 'doc_id = ?' | 'doc_id = ? AND date = ?' | 'bookmark_uuid = ?'
    ts_col: str         # mevcut kaydin LWW zaman kolonu: 'updated_at_ms' | 'opened_at_ms'
    pull_where: str     # pull filtre ifadesi (received_at_ms COALESCE)
    tombstone: bool     # deleted_docs reddi uygulanir mi
    pk: object          # dict -> pk degerleri (tuple)
    ts: object          # dict -> zaman damgasi (ms)
    device: object      # dict -> updated_by_device
    doc_id: object      # dict -> doc_id (tombstone icin) veya None
    insert_sql: str
    insert_vals: object  # (dict, now_ms) -> tuple
    pull_row: object     # sqlite row -> dict
    post_push: object = None  # conn -> None


def _trim_recent(conn):
    conn.execute(
        "DELETE FROM pdf_recent WHERE doc_id NOT IN "
        "(SELECT doc_id FROM pdf_recent ORDER BY opened_at_ms DESC, opened_at DESC LIMIT 20)"
    )


SYNC_SPECS = [
    SyncSpec(
        key="positions", singular="position", table="positions",
        pk_where="doc_id = ?", ts_col="updated_at_ms",
        pull_where="COALESCE(received_at_ms, updated_at_ms, updated_at * 1000)",
        tombstone=True,
        pk=lambda d: (d["doc_id"],), ts=lambda d: d["updated_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: d["doc_id"],
        insert_sql="INSERT OR REPLACE INTO positions (doc_id, page, updated_at, updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
        insert_vals=lambda d, now_ms: (d["doc_id"], d["page"], d["updated_at_ms"] // 1000, d["updated_at_ms"], d["updated_by_device"], now_ms, d.get("deleted_at_ms")),
        pull_row=lambda r: {
            "doc_id": r["doc_id"], "page": r["page"],
            "updated_at_ms": r["updated_at_ms"] or r["updated_at"] * 1000,
            "updated_by_device": r["updated_by_device"] or "",
            "deleted_at_ms": r["deleted_at_ms"],
        },
    ),
    SyncSpec(
        key="annotations", singular="annotation", table="annotations",
        pk_where="stroke_uuid = ?", ts_col="updated_at_ms",
        pull_where="COALESCE(received_at_ms, updated_at_ms, updated_at * 1000)",
        tombstone=True,
        pk=lambda d: (d["stroke_uuid"],), ts=lambda d: d["updated_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: d["doc_id"],
        insert_sql="""INSERT OR REPLACE INTO annotations
                       (stroke_uuid, doc_id, page, kind, color, width, points, text, font_size, font_family, updated_at, updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        insert_vals=lambda d, now_ms: (
            d["stroke_uuid"], d["doc_id"], d["page"], d["kind"], d["color"], d["width"],
            json.dumps(d["points"]), d.get("text"), d.get("font_size"), d.get("font_family"),
            d["updated_at_ms"] // 1000, d["updated_at_ms"], d["updated_by_device"], now_ms, d.get("deleted_at_ms"),
        ),
        pull_row=lambda r: {
            "stroke_uuid": r["stroke_uuid"], "doc_id": r["doc_id"], "page": r["page"],
            "kind": r["kind"], "color": r["color"], "width": r["width"],
            "points": json.loads(r["points"]), "text": r["text"],
            "font_size": r["font_size"], "font_family": r["font_family"],
            "updated_at_ms": r["updated_at_ms"] or r["updated_at"] * 1000,
            "updated_by_device": r["updated_by_device"] or "",
            "deleted_at_ms": r["deleted_at_ms"],
        },
    ),
    SyncSpec(
        key="favorites", singular="favorite", table="pdf_favorites",
        pk_where="doc_id = ?", ts_col="updated_at_ms",
        pull_where="COALESCE(received_at_ms, updated_at_ms, updated_at * 1000)",
        tombstone=True,
        pk=lambda d: (d["doc_id"],), ts=lambda d: d["updated_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: d["doc_id"],
        insert_sql="INSERT OR REPLACE INTO pdf_favorites (doc_id, favorite, updated_at, updated_at_ms, updated_by_device, received_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
        insert_vals=lambda d, now_ms: (d["doc_id"], 1 if d["favorite"] else 0, d["updated_at_ms"] // 1000, d["updated_at_ms"], d["updated_by_device"], now_ms),
        pull_row=lambda r: {
            "doc_id": r["doc_id"], "favorite": bool(r["favorite"]),
            "updated_at_ms": r["updated_at_ms"] or r["updated_at"] * 1000,
            "updated_by_device": r["updated_by_device"] or "",
        },
    ),
    SyncSpec(
        key="recent", singular="recent", table="pdf_recent",
        pk_where="doc_id = ?", ts_col="opened_at_ms",
        pull_where="COALESCE(received_at_ms, opened_at_ms, opened_at * 1000)",
        tombstone=True,
        pk=lambda d: (d["doc_id"],), ts=lambda d: d["opened_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: d["doc_id"],
        insert_sql="INSERT OR REPLACE INTO pdf_recent (doc_id, opened_at, opened_at_ms, updated_by_device, received_at_ms) VALUES (?, ?, ?, ?, ?)",
        insert_vals=lambda d, now_ms: (d["doc_id"], d["opened_at_ms"] // 1000, d["opened_at_ms"], d["updated_by_device"], now_ms),
        pull_row=lambda r: {
            "doc_id": r["doc_id"],
            "opened_at_ms": r["opened_at_ms"] or r["opened_at"] * 1000,
            "updated_by_device": r["updated_by_device"] or "",
        },
        post_push=_trim_recent,
    ),
    SyncSpec(
        key="reading_goals", singular="reading_goal", table="reading_goals",
        pk_where="doc_id = ? AND date = ?", ts_col="updated_at_ms",
        pull_where="COALESCE(received_at_ms, updated_at_ms, updated_at * 1000)",
        tombstone=True,
        pk=lambda d: (d["doc_id"], d["date"]), ts=lambda d: d["updated_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: d["doc_id"],
        insert_sql="""INSERT OR REPLACE INTO reading_goals
                       (doc_id, date, start_page, target_pages, updated_at, updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        insert_vals=lambda d, now_ms: (d["doc_id"], d["date"], d["start_page"], d["target_pages"], d["updated_at_ms"] // 1000, d["updated_at_ms"], d["updated_by_device"], now_ms, d.get("deleted_at_ms")),
        pull_row=lambda r: {
            "doc_id": r["doc_id"], "date": r["date"],
            "start_page": r["start_page"], "target_pages": r["target_pages"],
            "updated_at_ms": r["updated_at_ms"] or r["updated_at"] * 1000,
            "updated_by_device": r["updated_by_device"] or "",
            "deleted_at_ms": r["deleted_at_ms"],
        },
    ),
    SyncSpec(
        key="bookmarks", singular="bookmark", table="bookmarks",
        pk_where="bookmark_uuid = ?", ts_col="updated_at_ms",
        pull_where="COALESCE(received_at_ms, updated_at_ms)",
        tombstone=True,
        pk=lambda d: (d["bookmark_uuid"],), ts=lambda d: d["updated_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: d["doc_id"],
        insert_sql="""INSERT OR REPLACE INTO bookmarks
                       (bookmark_uuid, doc_id, page, label, updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        insert_vals=lambda d, now_ms: (d["bookmark_uuid"], d["doc_id"], d["page"], d["label"], d["updated_at_ms"], d["updated_by_device"], now_ms, d.get("deleted_at_ms")),
        pull_row=lambda r: {
            "bookmark_uuid": r["bookmark_uuid"], "doc_id": r["doc_id"], "page": r["page"],
            "label": r["label"], "updated_at_ms": r["updated_at_ms"],
            "updated_by_device": r["updated_by_device"] or "",
            "deleted_at_ms": r["deleted_at_ms"],
        },
    ),
    SyncSpec(
        key="pomodoro_sessions", singular="pomodoro", table="pomodoro_sessions",
        pk_where="session_uuid = ?", ts_col="updated_at_ms",
        pull_where="COALESCE(received_at_ms, updated_at_ms)",
        tombstone=False,
        pk=lambda d: (d["session_uuid"],), ts=lambda d: d["updated_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: None,
        insert_sql="""INSERT OR REPLACE INTO pomodoro_sessions
                       (session_uuid, date, subject, phase, minutes, started_at_ms,
                        updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        insert_vals=lambda d, now_ms: (d["session_uuid"], d["date"], d["subject"], d["phase"], d["minutes"], d["started_at_ms"], d["updated_at_ms"], d["updated_by_device"], now_ms, d.get("deleted_at_ms")),
        pull_row=lambda r: {
            "session_uuid": r["session_uuid"], "date": r["date"], "subject": r["subject"],
            "phase": r["phase"], "minutes": r["minutes"], "started_at_ms": r["started_at_ms"],
            "updated_at_ms": r["updated_at_ms"],
            "updated_by_device": r["updated_by_device"] or "",
            "deleted_at_ms": r["deleted_at_ms"],
        },
    ),
    SyncSpec(
        key="legislation_positions", singular="legislation_position", table="legislation_positions",
        pk_where="mevzuat_no = ?", ts_col="updated_at_ms",
        pull_where="COALESCE(received_at_ms, updated_at_ms)", tombstone=False,
        pk=lambda d: (d["mevzuat_no"],), ts=lambda d: d["updated_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: None,
        insert_sql="INSERT OR REPLACE INTO legislation_positions (mevzuat_no, madde_ref, updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
        insert_vals=lambda d, now_ms: (d["mevzuat_no"], d["madde_ref"], d["updated_at_ms"], d["updated_by_device"], now_ms, d.get("deleted_at_ms")),
        pull_row=lambda r: {"mevzuat_no": r["mevzuat_no"], "madde_ref": r["madde_ref"], "updated_at_ms": r["updated_at_ms"], "updated_by_device": r["updated_by_device"] or "", "deleted_at_ms": r["deleted_at_ms"]},
    ),
    SyncSpec(
        key="madde_notes", singular="madde_note", table="madde_notes",
        pk_where="note_uuid = ?", ts_col="updated_at_ms",
        pull_where="COALESCE(received_at_ms, updated_at_ms)", tombstone=True,
        pk=lambda d: (d["note_uuid"],), ts=lambda d: d["updated_at_ms"],
        device=lambda d: d["updated_by_device"], doc_id=lambda d: None,
        insert_sql="INSERT OR REPLACE INTO madde_notes (note_uuid, madde_ref, kind, renk, secili_metin_araligi, text, updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        insert_vals=lambda d, now_ms: (d["note_uuid"], d["madde_ref"], d["kind"], d.get("renk"), d.get("secili_metin_araligi"), d.get("text", ""), d["updated_at_ms"], d["updated_by_device"], now_ms, d.get("deleted_at_ms")),
        pull_row=lambda r: {"note_uuid": r["note_uuid"], "madde_ref": r["madde_ref"], "kind": r["kind"], "renk": r["renk"], "secili_metin_araligi": r["secili_metin_araligi"], "text": r["text"], "updated_at_ms": r["updated_at_ms"], "updated_by_device": r["updated_by_device"] or "", "deleted_at_ms": r["deleted_at_ms"]},
    ),
]
SYNC_BY_KEY = {s.key: s for s in SYNC_SPECS}
SYNC_BY_SINGULAR = {s.singular: s for s in SYNC_SPECS}


def _rejected_deleted(conn, doc_id, ts):
    if doc_id is None:
        return False
    row = conn.execute(
        "SELECT deleted_at_ms FROM deleted_docs WHERE doc_id = ?", (doc_id,)
    ).fetchone()
    return row is not None and ts < row["deleted_at_ms"]


def _lww_should_write(conn, spec, d):
    existing = conn.execute(
        f"SELECT {spec.ts_col} AS ts, updated_by_device FROM {spec.table} WHERE {spec.pk_where}",
        spec.pk(d),
    ).fetchone()
    if existing is None:
        return True
    old_ts = existing["ts"] or 0
    new_ts = spec.ts(d)
    return new_ts > old_ts or (
        new_ts == old_ts and spec.device(d) > (existing["updated_by_device"] or "")
    )


def upsert_lww(conn, spec, d, now_ms) -> bool:
    """Tek kaydi LWW + tombstone kurallariyla yazar. Yazildiysa True."""
    if spec.tombstone and _rejected_deleted(conn, spec.doc_id(d), spec.ts(d)):
        return False
    if _lww_should_write(conn, spec, d):
        conn.execute(spec.insert_sql, spec.insert_vals(d, now_ms))
        return True
    return False


def _pull_all(conn, since_ms) -> dict:
    out = {}
    for spec in SYNC_SPECS:
        out[spec.key] = [
            spec.pull_row(row)
            for row in conn.execute(
                f"SELECT * FROM {spec.table} WHERE {spec.pull_where} > ?", (since_ms,)
            ).fetchall()
        ]
    out["deleted_docs"] = [
        {"doc_id": row["doc_id"], "deleted_at_ms": row["deleted_at_ms"]}
        for row in conn.execute(
            "SELECT * FROM deleted_docs WHERE deleted_at_ms > ?", (since_ms,)
        ).fetchall()
    ]
    return out


def _as_dict(item):
    return item.model_dump() if hasattr(item, "model_dump") else item.dict()


@router.get("/sync/status", dependencies=[Depends(check_auth)])
def sync_status():
    return {"ok": True, "server_time_ms": int(time.time() * 1000)}


@router.get("/sync/pull", dependencies=[Depends(check_auth)])
def sync_pull(since_ms: int = 0):
    # Imleci sorgulardan ONCE al: es zamanli yazilan satirlar bir sonraki pull'da
    # (>) yakalanir. received_at_ms sunucu saatidir; istemci saati geride olsa bile
    # push edilen kayit buradan cekilir.
    cursor_ms = int(time.time() * 1000)
    with db() as conn:
        data = _pull_all(conn, since_ms)
    return {"server_time_ms": cursor_ms, "pdfs": [], **data}


@router.post("/sync/push", dependencies=[Depends(check_auth)])
def sync_push(body: SyncPushBody):
    accepted = {s.key: 0 for s in SYNC_SPECS}
    now_ms = int(time.time() * 1000)
    with db() as conn:
        for spec in SYNC_SPECS:
            for item in getattr(body, spec.key):
                if upsert_lww(conn, spec, _as_dict(item), now_ms):
                    accepted[spec.key] += 1
            if spec.post_push:
                spec.post_push(conn)
    return {"ok": True, "server_time_ms": now_ms, "accepted": accepted}


class SyncV2Op(BaseModel):
    entity: str
    data: dict


class SyncV2PushBody(BaseModel):
    device_id: str
    ops: list[SyncV2Op]


@router.post("/sync/v2/push", dependencies=[Depends(check_auth)])
def sync_v2_push(body: SyncV2PushBody):
    now_ms = int(time.time() * 1000)
    accepted = 0
    with db() as conn:
        touched = set()
        for op in body.ops:
            spec = SYNC_BY_SINGULAR.get(op.entity)
            if spec is None:
                continue
            if upsert_lww(conn, spec, op.data, now_ms):
                accepted += 1
            touched.add(spec.singular)
        for spec in SYNC_SPECS:
            if spec.post_push and spec.singular in touched:
                spec.post_push(conn)
    return {"ok": True, "server_time_ms": now_ms, "accepted": accepted}


@router.get("/sync/v2/pull", dependencies=[Depends(check_auth)])
def sync_v2_pull(since_ms: int = 0):
    cursor_ms = int(time.time() * 1000)
    with db() as conn:
        data = _pull_all(conn, since_ms)
    ops = []
    for spec in SYNC_SPECS:
        for d in data[spec.key]:
            ops.append({"entity": spec.singular, "data": d})
    return {"server_time_ms": cursor_ms, "ops": ops, "deleted_docs": data["deleted_docs"]}
