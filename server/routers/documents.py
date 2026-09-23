from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Request
from fastapi.responses import FileResponse, Response
from core import *  # noqa: F401,F403

router = APIRouter()


@router.get("/pdfs/{doc_id}/file", dependencies=[Depends(check_auth)])
def get_pdf_file(doc_id: str):
    path = find_pdf_by_id(doc_id)
    if path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")
    return FileResponse(path, media_type="application/pdf", filename=path.name)


@router.put("/pdfs/{doc_id}/file", dependencies=[Depends(check_auth)])
async def upload_pdf_file(doc_id: str, request: Request):
    path = find_pdf_by_id(doc_id)
    if path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")
    data = await request.body()
    _validate_pdf_upload(data)
    path.write_bytes(data)
    try:
        index_pdf(path)
    except Exception:
        pass
    return {"ok": True, "size": len(data)}


@router.post("/pdfs/upload", dependencies=[Depends(check_auth)])
async def upload_new_pdf(name: str, request: Request, folder: str = ""):
    # Yol kac (path traversal) onleme: sadece dosya adi
    safe = Path(name).name.strip()
    if not safe:
        raise HTTPException(status_code=400, detail="Gecersiz dosya adi")
    if not safe.lower().endswith(".pdf"):
        safe += ".pdf"

    dest_dir = safe_library_path(folder if folder else None)
    if not dest_dir.exists() or not dest_dir.is_dir():
        raise HTTPException(status_code=404, detail="Hedef klasor bulunamadi")
    target = dest_dir / safe
    # Ayni ad varsa: ad(1).pdf, ad(2).pdf ...
    if target.exists():
        stem = target.stem
        i = 1
        while target.exists():
            target = dest_dir / f"{stem}({i}).pdf"
            i += 1

    data = await request.body()
    _validate_pdf_upload(data)
    target.write_bytes(data)

    try:
        index_pdf(target)
    except Exception:
        pass

    rel = target.relative_to(pdf_dir()).as_posix()
    return {"id": doc_id_for(rel), "name": target.stem, "relative_path": rel}


@router.post("/pdfs/{doc_id}/move", dependencies=[Depends(check_auth)])
def move_pdf(doc_id: str, body: PdfMoveCopyIn):
    pdf_path = find_pdf_by_id(doc_id)
    if pdf_path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")

    dest_dir = safe_library_path(body.target_folder if body.target_folder else None)
    if not dest_dir.exists() or not dest_dir.is_dir():
        raise HTTPException(status_code=404, detail="Hedef klasor bulunamadi")

    # Build target path with unique name
    target = dest_dir / pdf_path.name
    if target.resolve() == pdf_path.resolve():
        return {"ok": True, "item": _pdf_to_dict(pdf_path)}

    if target.exists():
        stem = target.stem
        i = 1
        while target.exists():
            target = dest_dir / f"{stem}({i}).pdf"
            i += 1

    # Move file
    pdf_path.rename(target)

    # Calculate new doc_id
    new_rel = target.relative_to(pdf_dir()).as_posix()
    new_id = doc_id_for(new_rel)

    with db() as conn:
        _transfer_doc_id(conn, doc_id, new_id, new_rel, target.stem)

    return {"ok": True, "item": _pdf_to_dict(target)}


@router.post("/pdfs/{doc_id}/copy", dependencies=[Depends(check_auth)])
def copy_pdf(doc_id: str, body: PdfMoveCopyIn):
    pdf_path = find_pdf_by_id(doc_id)
    if pdf_path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")

    dest_dir = safe_library_path(body.target_folder if body.target_folder else None)
    if not dest_dir.exists() or not dest_dir.is_dir():
        raise HTTPException(status_code=404, detail="Hedef klasor bulunamadi")

    target = dest_dir / pdf_path.name
    if target.exists():
        stem = target.stem
        i = 1
        while target.exists():
            target = dest_dir / f"{stem}({i}).pdf"
            i += 1

    # Copy file
    shutil.copy2(pdf_path, target)
    try:
        index_pdf(target)
    except Exception:
        pass

    new_rel = target.relative_to(pdf_dir()).as_posix()
    new_id = doc_id_for(new_rel)

    # Copy position if exists. Kopya yeni doc_id icin taze uretilir; diger
    # cihazlarin cekmesi icin updated_at_ms + received_at_ms sunucu saatiyle set edilir.
    now = int(time.time())
    now_ms = int(time.time() * 1000)
    with db() as conn:
        pos_row = conn.execute(
            "SELECT page, device FROM positions WHERE doc_id = ?", (doc_id,)
        ).fetchone()
        if pos_row:
            conn.execute(
                "INSERT OR REPLACE INTO positions (doc_id, page, updated_at, updated_at_ms, updated_by_device, received_at_ms, device) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (new_id, pos_row["page"], now, now_ms, pos_row["device"] or "", now_ms, pos_row["device"]),
            )
        # Copy all annotations
        anno_rows = conn.execute(
            "SELECT page, kind, color, width, points, text, font_size, font_family, device FROM annotations WHERE doc_id = ?",
            (doc_id,),
        ).fetchall()
        for a in anno_rows:
            conn.execute(
                "INSERT INTO annotations (stroke_uuid, doc_id, page, kind, color, width, points, text, font_size, font_family, updated_at, updated_at_ms, updated_by_device, received_at_ms, device) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (f"copy-{secrets.token_hex(16)}", new_id, a["page"], a["kind"], a["color"], a["width"], a["points"], a["text"], a["font_size"], a["font_family"], now, now_ms, a["device"] or "", now_ms, a["device"]),
            )
        bookmark_rows = conn.execute(
            """
            SELECT page, label, updated_at_ms, updated_by_device, deleted_at_ms
            FROM bookmarks WHERE doc_id = ?
            """,
            (doc_id,),
        ).fetchall()
        for b in bookmark_rows:
            conn.execute(
                """
                INSERT INTO bookmarks
                    (bookmark_uuid, doc_id, page, label, updated_at_ms, updated_by_device, received_at_ms, deleted_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    f"copy-{secrets.token_hex(16)}",
                    new_id,
                    b["page"],
                    b["label"],
                    now_ms,
                    b["updated_by_device"],
                    now_ms,
                    b["deleted_at_ms"],
                ),
            )

    return {"ok": True, "item": _pdf_to_dict(target)}


@router.delete("/pdfs/{doc_id}", dependencies=[Depends(check_auth)])
def delete_pdf(doc_id: str):
    pdf_path = find_pdf_by_id(doc_id)
    if pdf_path is None:
        raise HTTPException(status_code=404, detail="PDF bulunamadi")

    pdf_path.unlink()

    deleted_at_ms = int(time.time() * 1000)
    with db() as conn:
        _delete_doc_data(conn, doc_id, deleted_at_ms)

    return {"ok": True}


@router.get("/notes", dependencies=[Depends(check_auth)])
def list_notes():
    # Tum .belge dosyalarini tara; tabloya guvenmeden dosya yetkili kaynaktir.
    items = []
    for path in sorted(pdf_dir().rglob(f"*{NOTE_EXT}"), key=lambda p: p.name.lower()):
        items.append(_note_item(path))
    return {"items": items}


@router.post("/notes", dependencies=[Depends(check_auth)])
def create_note(name: str, folder: str = ""):
    safe = Path(name).name.strip()
    if not safe:
        raise HTTPException(status_code=400, detail="Gecersiz dosya adi")
    stem = Path(safe).stem.strip()
    if not stem:
        stem = "not"
    dest_dir = safe_library_path(folder if folder else None)
    if not dest_dir.exists() or not dest_dir.is_dir():
        raise HTTPException(status_code=404, detail="Hedef klasor bulunamadi")
    target = _unique_target(dest_dir, stem, NOTE_EXT)
    rel = target.relative_to(pdf_dir()).as_posix()
    doc_id = doc_id_for(rel)
    now = int(time.time() * 1000)
    content = {
        "schema": 1,
        "id": doc_id,
        "title": target.stem,
        "updated_at_ms": now,
        "blocks": [],
    }
    text = json.dumps(content, ensure_ascii=False, indent=2)
    target.write_text(text, encoding="utf-8")
    _note_upsert(doc_id, rel, target.stem, text, now)
    return _note_item(target)


@router.get("/notes/{doc_id}", dependencies=[Depends(check_auth)])
def get_note(doc_id: str):
    path = find_note_by_id(doc_id)
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Not bulunamadi")
    # Cift-depo: once tablo content'ini oku (yetkili); yoksa dosyadan okuyup senkla.
    text = None
    with db() as conn:
        row = conn.execute(
            "SELECT content, updated_at_ms FROM notes WHERE note_doc_id = ? AND deleted_at_ms IS NULL",
            (doc_id,),
        ).fetchone()
        if row:
            text = row["content"]
    if text is None:
        try:
            text = path.read_text(encoding="utf-8")
        except Exception:
            raise HTTPException(status_code=500, detail="Not okunamadi")
        _note_sync_from_file(path, doc_id)
    return Response(content=text.encode("utf-8"), media_type="application/json")


@router.put("/notes/{doc_id}", dependencies=[Depends(check_auth)])
async def update_note(doc_id: str, request: Request):
    path = find_note_by_id(doc_id)
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Not bulunamadi")
    raw = await request.body()
    try:
        data = json.loads(raw.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Gecersiz JSON govdesi")
    now = int(time.time() * 1000)
    client_uam = data.get("updated_at_ms")
    # LWW: istemciden updated_at_ms gelirse mevcut tablo degeriyle karsilastir;
    # istemci degeri daha eskiyse reddet (coklu cihaz cakismasinda kayip onleme).
    with db() as conn:
        row = conn.execute(
            "SELECT updated_at_ms FROM notes WHERE note_doc_id = ? AND deleted_at_ms IS NULL",
            (doc_id,),
        ).fetchone()
        existing_uam = row["updated_at_ms"] if row else None
    if (
        client_uam is not None
        and existing_uam is not None
        and int(client_uam) < int(existing_uam)
    ):
        raise HTTPException(status_code=409, detail="Not daha yeni surumu var (LWW)")
    final_uam = int(client_uam) if client_uam is not None else now
    data["updated_at_ms"] = final_uam
    data.setdefault("schema", 1)
    data.setdefault("id", doc_id)
    title = data.get("title", "") or path.stem
    text = json.dumps(data, ensure_ascii=False, indent=2)
    path.write_text(text, encoding="utf-8")
    rel = path.relative_to(pdf_dir()).as_posix()
    _note_upsert(doc_id, rel, title, text, final_uam)
    return {"ok": True, "updated_at_ms": final_uam}


@router.delete("/notes/{doc_id}", dependencies=[Depends(check_auth)])
def delete_note(doc_id: str):
    path = find_note_by_id(doc_id)
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Not bulunamadi")
    path.unlink()
    deleted_at_ms = int(time.time() * 1000)
    with db() as conn:
        # DOC_ID_TABLES notes icerir -> _delete_doc_data tabloyu siler ve
        # deleted_docs'a yazar; boylece E.4 LWW sync silmeyi yayabilir.
        _delete_doc_data(conn, doc_id, deleted_at_ms)
    return {"ok": True}


@router.post("/notes/{doc_id}/move", dependencies=[Depends(check_auth)])
def move_note(doc_id: str, body: PdfMoveCopyIn):
    # Notu hedef klasore tasi. move_pdf desenini mirrorlar; _transfer_doc_id
    # notes tablosunun PK'ini (note_doc_id) gunceller (DOC_ID_PK'ta kayitli).
    path = find_note_by_id(doc_id)
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Not bulunamadi")
    dest_dir = safe_library_path(body.target_folder if body.target_folder else None)
    if not dest_dir.exists() or not dest_dir.is_dir():
        raise HTTPException(status_code=404, detail="Hedef klasor bulunamadi")
    target = dest_dir / path.name
    if target.resolve() == path.resolve():
        return {"ok": True, "item": _note_item(path)}
    # Cakisan ad varsa benzersiz yap (not(1).belge, ...).
    target = _unique_target(dest_dir, target.stem, NOTE_EXT)
    path.rename(target)
    new_rel = target.relative_to(pdf_dir()).as_posix()
    new_id = doc_id_for(new_rel)
    with db() as conn:
        _transfer_doc_id(conn, doc_id, new_id, new_rel, target.stem)
    return {"ok": True, "item": _note_item(target)}
