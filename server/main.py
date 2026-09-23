"""Belgelik calisma sunucusu. Uygulama kurulumu + router baglama.
Is mantigi core.py ve routers/ altinda. Testler `import main` ile
main.app, main.PROFILES, main.doc_id_for vb.ye erisir (core star import).
"""
from fastapi import FastAPI
from core import *  # noqa: F401,F403  (testler icin re-export)
from routers import library, documents, videos, sync, tasks, misc, legislation


@asynccontextmanager
async def lifespan(app: FastAPI):
    threading.Thread(target=_startup_reindex, daemon=True).start()
    threading.Thread(target=_startup_warm, daemon=True).start()
    threading.Thread(target=_startup_cleanup, daemon=True).start()
    yield


app = FastAPI(title="Belgelik Calisma Sunucusu", lifespan=lifespan)


app.include_router(misc.router)
app.include_router(library.router)
app.include_router(documents.router)
app.include_router(videos.router)
app.include_router(sync.router)
app.include_router(tasks.router)
app.include_router(legislation.router)
