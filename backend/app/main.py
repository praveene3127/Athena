from contextlib import asynccontextmanager
import logging
import os
import re
import time
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

from app.config import is_llm_configured
from app.db import init_db
from app.errors import AppException, app_exception_handler, generic_exception_handler
from app.routers import ask, cards, documents, settings
from app.services.jobs import cleanup_interrupted_jobs
from app.services.pipeline import ReadAheadPipeline

logger = logging.getLogger("athena.api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialize DB schema on startup
    init_db()
    # Mark any stale queued/processing jobs as INTERRUPTED
    cleanup_interrupted_jobs()
    # Start Viewport-Driven Read-Ahead Priority Pipeline
    pipeline = ReadAheadPipeline()
    pipeline.start()
    app.state.pipeline = pipeline
    yield
    await pipeline.stop()


app = FastAPI(
    title="Athena Backend",
    description="Preserves source text fidelity and document order. Context is separate and grounded.",
    version="0.1.0",
    lifespan=lifespan,
)

# Browser clients run locally, over Wi-Fi LAN, or via public online tunnels.
_ALLOWED_ORIGIN = re.compile(
    r"^https?://(?:localhost|127\.0\.0\.1|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+|.*\.loca\.lt|.*\.pinggy\.link|.*\.pinggy\.io|.*\.trycloudflare\.com|.*\.localhost\.run|.*\.serveo\.net|.*\.ngrok-free\.app|.*\.ngrok\.io)(?::\d+)?$"
)


@app.middleware("http")
async def reject_untrusted_browser_mutations(request, call_next):
    origin = request.headers.get("origin")
    host = request.headers.get("host")
    if origin and request.method not in {"GET", "HEAD", "OPTIONS"}:
        is_same_origin = host and (origin.endswith(f"://{host}") or origin == f"http://{host}" or origin == f"https://{host}")
        if not is_same_origin and not _ALLOWED_ORIGIN.fullmatch(origin):
            return JSONResponse(
                status_code=403,
                content={
                    "error": {
                        "code": "FORBIDDEN_ORIGIN",
                        "message": "This Athena endpoint only accepts actions from trusted local and online app origins.",
                    }
                },
            )
    return await call_next(request)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    t0 = time.time()
    response = await call_next(request)
    duration = time.time() - t0
    path = request.url.path
    if path.startswith("/api") or response.status_code >= 400:
        logger.info("%s %s -> %s (%.3fs)", request.method, path, response.status_code, duration)
    return response


app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=_ALLOWED_ORIGIN.pattern,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD"],
    allow_headers=["Content-Type", "X-Athena-Context-Token", "Authorization", "Accept"],
)

# Exception handlers
app.add_exception_handler(AppException, app_exception_handler)
app.add_exception_handler(Exception, generic_exception_handler)

# Include Routers
app.include_router(documents.router)
app.include_router(cards.router)
app.include_router(ask.router)
app.include_router(settings.router)



_WEB_BUILD_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "app", "build", "web")
)


@app.get("/api")
def get_api_root():
    """Root API index explaining available routes."""
    return {
        "app": "Athena Backend",
        "status": "ok",
        "docs": "/docs",
        "health": "/api/health",
        "documents": "/api/documents",
    }


@app.get("/")
def get_root():
    """Serves the Flutter Web UI if built, or returns API index."""
    index_html = os.path.join(_WEB_BUILD_DIR, "index.html")
    if os.path.isfile(index_html):
        return FileResponse(index_html)
    return {
        "app": "Athena Backend",
        "status": "ok",
        "docs": "/docs",
        "health": "/api/health",
        "documents": "/api/documents",
    }


@app.get("/health")
@app.get("/api/health")
def get_health():
    """Health check endpoint proving the backend is alive, DB reachable, and models configured."""
    db_status = "unreachable"
    try:
        from app.db import engine
        from sqlmodel import Session, text
        with Session(engine) as session:
            session.exec(text("SELECT 1"))
            db_status = "reachable"
    except Exception as e:
        logger.warning("DB health check failed: %s", e)
        db_status = f"unreachable: {type(e).__name__}"

    model_status = "ready"
    try:
        from app.services.edge_ai import _get_embedder
        emb = _get_embedder()
        model_status = "ready" if emb is not None else "unavailable"
    except Exception:
        model_status = "unavailable"

    return {
        "status": "ok",
        "database": db_status,
        "model_status": model_status,
        "llm_configured": is_llm_configured(),
    }


@app.get("/api/pair-info")
def get_pair_info():
    """Returns pairing metadata and host IPs for wireless Android and Web client connection."""
    import socket

    lan_ip = "127.0.0.1"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            lan_ip = s.getsockname()[0]
    except Exception:
        pass
    return {
        "status": "ok",
        "lan_ip": lan_ip,
        "api_port": 8000,
        "web_port": 8080,
        "base_url": f"http://{lan_ip}:8000",
    }


_ROOT_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..")
)
_RELEASES_DIR = os.path.join(_ROOT_DIR, "releases")
_VERSION_FILE = os.path.join(_ROOT_DIR, "version.json")


@app.get("/api/version")
@app.get("/api/app-update")
def get_app_update():
    """Returns the current deployed version, update release notes, and download links."""
    data = {
        "version": "0.1.1",
        "build_number": 2,
        "title": "Athena v0.1.1 Update",
        "release_notes": "Zero-keyword structural document bouncer, BYOK awakening screen, and one-click Android APK & iOS IPA downloads.",
        "published_at": "2026-10-24T17:50:00Z",
        "download_url_apk": "/releases/athena-release.apk",
        "download_url_ipa": "/releases/athena-ios-release.ipa",
        "download_url_web": "/",
    }
    if os.path.isfile(_VERSION_FILE):
        try:
            with open(_VERSION_FILE, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    data.update(loaded)
        except Exception:
            pass

    # Check APK file status
    apk_path = os.path.join(_RELEASES_DIR, "athena-release.apk")
    if os.path.isfile(apk_path):
        data["has_apk"] = True
        data["apk_size_bytes"] = os.path.getsize(apk_path)
        data["apk_size_mb"] = round(os.path.getsize(apk_path) / (1024 * 1024), 1)

    # Check IPA file status
    ipa_path = os.path.join(_RELEASES_DIR, "athena-ios-release.ipa")
    if os.path.isfile(ipa_path):
        data["has_ipa"] = True
        data["ipa_size_bytes"] = os.path.getsize(ipa_path)
        data["ipa_size_mb"] = round(os.path.getsize(ipa_path) / (1024 * 1024), 1)

    return data


# Fallback route for SPA client-side routing & static assets
@app.get("/{full_path:path}")
async def serve_static_or_spa(full_path: str):
    # Check if requested from releases directory
    if full_path.startswith("releases/"):
        rel_sub = full_path.replace("releases/", "", 1).lstrip(r"\/")
        rel_file = os.path.join(_RELEASES_DIR, rel_sub)
        if os.path.isfile(rel_file):
            return FileResponse(rel_file)

    # Security check: normalize and strip leading slashes
    safe_path = os.path.normpath(full_path).lstrip(r"\/")
    file_path = os.path.join(_WEB_BUILD_DIR, safe_path)
    if os.path.isfile(file_path):
        return FileResponse(file_path)
    # If file doesn't exist, route to index.html for Flutter Web client-side router
    index_html = os.path.join(_WEB_BUILD_DIR, "index.html")
    if os.path.isfile(index_html):
        return FileResponse(index_html)
    return JSONResponse(status_code=404, content={"error": "Not found"})


