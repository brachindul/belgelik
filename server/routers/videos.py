from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Request
from fastapi.responses import FileResponse, Response
from core import *  # noqa: F401,F403

router = APIRouter()


@router.get("/videos", dependencies=[Depends(check_auth)])
def list_videos():
    with db() as conn:
        pos_rows = conn.execute(
            "SELECT doc_id, page, updated_at FROM positions"
        ).fetchall()
    positions = {r["doc_id"]: (r["page"], r["updated_at"]) for r in pos_rows}
    items = []
    for path in sorted(video_dir().rglob("*")):
        if path.is_file() and path.suffix.lower() in VIDEO_EXTS:
            item = _video_item(path)
            dur = _video_duration(path)
            if dur is not None:
                item["duration_sec"] = int(dur)
            p = positions.get(item["id"])
            if p:
                item["position_sec"] = p[0]
                item["position_updated_at"] = p[1]
            items.append(item)
    return {"items": items}


@router.get("/video-library", dependencies=[Depends(check_auth)])
def list_video_library(path: str = ""):
    target = safe_video_path(path)
    if not target.exists():
        raise HTTPException(status_code=404, detail="Klasor bulunamadi")
    if not target.is_dir():
        raise HTTPException(status_code=400, detail="Belirtilen yol bir klasor degil")

    folders = []
    videos = []
    for item in sorted(target.iterdir(), key=lambda x: x.name.lower()):
        if item.is_dir():
            rel = item.relative_to(video_dir()).as_posix()
            folders.append({"name": item.name, "path": rel})
        elif item.is_file() and item.suffix.lower() in VIDEO_EXTS:
            videos.append(_video_item(item))

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
        "videos": videos,
    }


@router.get("/videos/{doc_id}/file", dependencies=[Depends(check_auth)])
def get_video_file(doc_id: str):
    path = find_video_by_id(doc_id)
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Video bulunamadi")
    # FileResponse (Starlette) Range isteklerini otomatik destekler -> seek/akis calisir.
    return FileResponse(path, media_type="video/mp4", filename=path.name)


@router.post("/videos/upload", dependencies=[Depends(check_auth)])
async def upload_new_video(
    name: str,
    request: Request,
    background_tasks: BackgroundTasks,
    folder: str = "",
):
    # Yol kac (path traversal) onleme: sadece dosya adi. Uzanti kontrolu:
    # VIDEO_EXTS icinde degilse .mp4 varsay; boshafizada 400.
    safe = Path(name).name.strip()
    if not safe:
        raise HTTPException(status_code=400, detail="Gecersiz dosya adi")
    ext = Path(safe).suffix.lower()
    if ext not in VIDEO_EXTS:
        ext = ".mp4"
    stem = Path(safe).stem.strip()
    if not stem:
        stem = "video"

    dest_dir = safe_video_path(folder if folder else None)
    if not dest_dir.exists() or not dest_dir.is_dir():
        raise HTTPException(status_code=404, detail="Hedef klasor bulunamadi")
    target = _unique_target(dest_dir, stem, ext)

    # Akisla diske yaz (buyuk dosyalarda bellege ALMA).
    with open(target, "wb") as f:
        async for chunk in request.stream():
            if chunk:
                f.write(chunk)

    # Arka planda faststart remux (yalniz mp4/m4v, ffmpeg varsa). Profil
    # contextvar'ini sarmalla; kullanilan helper zaten use_profile kullanir.
    try:
        _video_duration(target)
    except Exception:
        pass
    background_tasks.add_task(_faststart_video, current_profile(), target)

    rel = target.relative_to(video_dir()).as_posix()
    return {"id": doc_id_for(rel), "name": target.stem, "relative_path": rel}
