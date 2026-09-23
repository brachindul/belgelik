from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Request
from fastapi.responses import FileResponse, Response
from core import *  # noqa: F401,F403

router = APIRouter()


@router.get("/search", dependencies=[Depends(check_auth)])
def search(q: str, limit: int = 50):
    match = _fts_query(q)
    if not match:
        return {"items": []}
    sql = """
        SELECT t.doc_id AS doc_id, t.page AS page,
               snippet(pdf_text, 2, '[', ']', '…', 12) AS snippet,
               m.name AS name, m.relative_path AS relative_path,
               m.size AS size, m.modified AS modified
        FROM pdf_text t
        JOIN pdf_index_meta m ON m.doc_id = t.doc_id
        WHERE pdf_text MATCH ?
        ORDER BY rank
        LIMIT ?
    """
    with db() as conn:
        rows = conn.execute(sql, (match, limit)).fetchall()
    return {
        "items": [
            {
                "doc_id": r["doc_id"],
                "page": r["page"],
                "snippet": r["snippet"],
                "name": r["name"],
                "relative_path": r["relative_path"],
                "size": r["size"],
                "modified": r["modified"],
            }
            for r in rows
        ]
    }


@router.get("/library", dependencies=[Depends(check_auth)])
def list_library(path: str = ""):
    target = safe_library_path(path)
    if not target.exists():
        raise HTTPException(status_code=404, detail="Klasor bulunamadi")
    if not target.is_dir():
        raise HTTPException(status_code=400, detail="Belirtilen yol bir klasor degil")

    with db() as conn:
        favorite_ids = {
            row["doc_id"]
            for row in conn.execute(
                "SELECT doc_id FROM pdf_favorites WHERE favorite = 1"
            ).fetchall()
        }
        page_counts, current_pages = _doc_progress_maps(conn)

    folders = []
    pdfs = []
    for item in sorted(target.iterdir(), key=lambda x: x.name.lower()):
        if item.is_dir():
            rel = item.relative_to(pdf_dir()).as_posix()
            folders.append({"name": item.name, "path": rel})
        elif item.is_file() and item.suffix.lower() == ".pdf":
            pdfs.append(_pdf_item_with_meta(item, favorite_ids, page_counts, current_pages))
        elif item.is_file() and item.suffix.lower() == NOTE_EXT:
            pdfs.append(_note_item(item))

    parent = None
    if path != "":
        parent = str(Path(path).parent) if Path(path).parent != Path(".") else None
        if parent == "" or parent == ".":
            parent = None
        elif parent is not None:
            parent = parent.replace("\\", "/")

    return {
        "path": path if path else "",
        "parent": parent if parent and parent != "" else "",
        "folders": folders,
        "pdfs": pdfs,
    }


@router.get("/pdfs", dependencies=[Depends(check_auth)])
def list_pdfs():
    with db() as conn:
        favorite_ids = {
            row["doc_id"]
            for row in conn.execute(
                "SELECT doc_id FROM pdf_favorites WHERE favorite = 1"
            ).fetchall()
        }
        page_counts, current_pages = _doc_progress_maps(conn)
    items = []
    for path in sorted(pdf_dir().rglob("*.pdf"), key=lambda p: p.name.lower()):
        items.append(_pdf_item_with_meta(path, favorite_ids, page_counts, current_pages))
    for path in sorted(pdf_dir().rglob(f"*{NOTE_EXT}"), key=lambda p: p.name.lower()):
        items.append(_note_item(path))
    return {"items": items}


@router.post("/folders", dependencies=[Depends(check_auth)])
def create_folder(body: FolderCreateIn):
    name = safe_folder_name(body.name)
    parent = safe_library_path(body.path if body.path else None)
    if not parent.exists():
        raise HTTPException(status_code=404, detail="Ust klasor bulunamadi")
    target = parent / name
    if target.exists():
        return {"ok": True}
    target.mkdir(parents=False)
    return {"ok": True}


@router.put("/folders/rename", dependencies=[Depends(check_auth)])
def rename_folder(body: FolderRenameIn):
    if not body.path or body.path == "":
        raise HTTPException(status_code=400, detail="Kok klasor yeniden adlandirilamaz")
    old_target = safe_library_path(body.path)
    if not old_target.exists() or not old_target.is_dir():
        raise HTTPException(status_code=404, detail="Klasor bulunamadi")
    new_name = safe_folder_name(body.new_name)
    parent = old_target.parent
    new_target = parent / new_name
    if new_target.exists():
        raise HTTPException(status_code=409, detail="Bu isimde bir klasor zaten var")

    # Collect old doc_ids for position/annotation transfer
    old_doc_ids = {}
    for pdf_file in old_target.rglob("*.pdf"):
        old_rel = pdf_file.relative_to(pdf_dir()).as_posix()
        old_id = doc_id_for(old_rel)
        new_rel = (new_target / pdf_file.relative_to(old_target)).relative_to(pdf_dir()).as_posix()
        old_doc_ids[old_id] = (doc_id_for(new_rel), new_rel, Path(new_rel).stem)

    old_target.rename(new_target)

    # Transfer positions and annotations
    with db() as conn:
        for old_id, (new_id, new_rel, new_name) in old_doc_ids.items():
            _transfer_doc_id(conn, old_id, new_id, new_rel, new_name)

    return {"ok": True}


@router.delete("/folders", dependencies=[Depends(check_auth)])
def delete_folder(path: str):
    if not path or path == "":
        raise HTTPException(status_code=400, detail="Kok klasor silinemez")
    target = safe_library_path(path)
    if not target.exists() or not target.is_dir():
        raise HTTPException(status_code=404, detail="Klasor bulunamadi")

    # Collect doc_ids to delete
    doc_ids = []
    for pdf_file in target.rglob("*.pdf"):
        rel = pdf_file.relative_to(pdf_dir()).as_posix()
        doc_ids.append(doc_id_for(rel))

    # Delete folder and contents
    shutil.rmtree(target)

    deleted_at_ms = int(time.time() * 1000)
    with db() as conn:
        for did in doc_ids:
            _delete_doc_data(conn, did, deleted_at_ms)

    return {"ok": True}
