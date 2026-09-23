from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Request
from fastapi.responses import FileResponse, Response
from core import *  # noqa: F401,F403
import core

router = APIRouter()


@router.get("/health")
def health():
    # Public endpoint (auth yok): tum profillerin db boyutlari ve pdf sayilari toplanir.
    db_size = 0
    pdf_count = 0
    pdf_total_bytes = 0
    indexed_docs = 0
    for p in PROFILES:
        for path in (p.db_path, Path(str(p.db_path) + "-wal")):
            if path.exists():
                db_size += path.stat().st_size
        with use_profile(p):
            with db() as conn:
                row = conn.execute(
                    """
                    SELECT COUNT(*) AS pdf_count,
                           COALESCE(SUM(size), 0) AS pdf_total_bytes,
                           SUM(CASE WHEN page_count IS NOT NULL THEN 1 ELSE 0 END) AS indexed_docs
                    FROM pdf_index_meta
                    """
                ).fetchone()
        pdf_count += int(row["pdf_count"] or 0)
        pdf_total_bytes += int(row["pdf_total_bytes"] or 0)
        indexed_docs += int(row["indexed_docs"] or 0)
    backups_dir = BASE_DIR / "backups"
    last_backup = None
    if backups_dir.exists():
        candidates = [p for p in backups_dir.iterdir()]
        if candidates:
            newest = max(candidates, key=lambda p: p.stat().st_mtime)
            last_backup = datetime.fromtimestamp(
                newest.stat().st_mtime,
                tz=timezone.utc,
            ).isoformat()
    return {
        "status": "ok",
        "service": "belgelik",
        "faz": 4,
        "server_time_ms": int(time.time() * 1000),
        "uptime_s": int(time.time() - START_TIME),
        "db_size_bytes": db_size,
        "pdf_count": pdf_count,
        "pdf_total_bytes": pdf_total_bytes,
        "indexed_docs": indexed_docs,
        "last_backup": last_backup,
    }


@router.post("/reindex", dependencies=[Depends(check_auth)])
def reindex(background_tasks: BackgroundTasks):
    background_tasks.add_task(_reindex_profile, current_profile())
    return {"ok": True, "status": "started"}


@router.post("/backup", dependencies=[Depends(check_auth)])
def trigger_backup(background_tasks: BackgroundTasks):
    background_tasks.add_task(
        lambda: subprocess.run([sys.executable, str(BASE_DIR / "backup.py"), "--pdfs"])
    )
    return {"ok": True}


@router.get("/profile", dependencies=[Depends(check_auth)])
def get_profile():
    p = current_profile()
    return {"id": p.id, "name": p.name, "features": p.features}


@router.get("/app/version", dependencies=[Depends(check_auth)])
def app_version():
    return _app_version_info()


@router.get("/app/apk")
def app_apk(token: str = "", x_auth_token: str = Header(default="")):
    # Uygulama acilamayacak kadar bozuksa OTA calisamaz; tarayicidan elle
    # indirme icin header'a ek olarak ?token= sorgu parametresi de kabul edilir.
    supplied = x_auth_token or token
    if not any(secrets.compare_digest(supplied, p.token) for p in PROFILES):
        raise HTTPException(status_code=401, detail="Gecersiz token")
    if not core.APK_PATH.exists():
        raise HTTPException(status_code=404, detail="APK bulunamadi")
    return FileResponse(
        core.APK_PATH,
        media_type="application/vnd.android.package-archive",
        filename="belgelik.apk",
    )
