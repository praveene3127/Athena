from contextlib import asynccontextmanager
import json
import logging
import os
import re
import time
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.config import is_llm_configured
from app.db import init_db
from app.errors import AppException, app_exception_handler, generic_exception_handler
from app.routers import ask, cards, documents, settings, updates
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
app.include_router(updates.router)



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
    """Returns pairing metadata and host IPs for wireless phone and web client pairing."""
    import socket

    lan_ip = "127.0.0.1"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            lan_ip = s.getsockname()[0]
    except Exception:
        pass

    tunnel_url = os.environ.get("TUNNEL_URL") or os.environ.get("CLOUDFLARE_URL")
    return {
        "status": "ok",
        "lan_ip": lan_ip,
        "api_port": 8000,
        "web_port": 8080,
        "base_url": f"http://{lan_ip}:8000",
        "phone_wifi_url": f"http://{lan_ip}:8000",
        "desktop_url": "http://127.0.0.1:8080",
        "tunnel_url": tunnel_url,
    }


_ROOT_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..")
)
_RELEASES_DIR = os.path.join(_ROOT_DIR, "releases")
_VERSION_FILE = os.path.join(_ROOT_DIR, "scripts", "version.json")
if not os.path.isfile(_VERSION_FILE):
    _VERSION_FILE = os.path.join(_ROOT_DIR, "version.json")


@app.get("/download", response_class=HTMLResponse)
def get_download_page():
    """Serves the responsive 1-click mobile installer and package download hub."""
    html_content = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Athena &mdash; Mobile App Downloads</title>
  <style>
    :root {
      --bg: #FBF9F5;
      --card-bg: #FFFFFF;
      --border: #E5E2DA;
      --ink: #161615;
      --muted: #6B6860;
      --accent: #C84B31;
      --accent-subtle: #F4EBE8;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #141413;
        --card-bg: #1C1B19;
        --border: #2E2D2A;
        --ink: #F2EFE9;
        --muted: #9E9B93;
        --accent: #D95D43;
        --accent-subtle: #2B1D1A;
      }
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      padding: 36px 18px 48px;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
    }
    .container {
      max-width: 560px;
      margin: 0 auto;
    }
    .header {
      margin-bottom: 28px;
    }
    .kicker {
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 1.2px;
      text-transform: uppercase;
      color: var(--accent);
      margin-bottom: 8px;
    }
    h1 {
      font-size: 26px;
      font-weight: 600;
      letter-spacing: -0.4px;
      margin-bottom: 6px;
    }
    .subtitle {
      font-size: 14px;
      color: var(--muted);
    }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 20px;
      margin-bottom: 16px;
      transition: border-color 0.15s ease;
    }
    .card.highlight {
      border-color: var(--accent);
      box-shadow: 0 0 0 1px var(--accent);
    }
    .badge {
      display: inline-block;
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
      font-size: 10px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.6px;
      background: var(--accent-subtle);
      color: var(--accent);
      padding: 2px 7px;
      border-radius: 3px;
      margin-bottom: 10px;
    }
    .card-title {
      font-size: 16px;
      font-weight: 600;
      margin-bottom: 4px;
    }
    .card-desc {
      font-size: 13px;
      color: var(--muted);
      margin-bottom: 14px;
    }
    .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 100%;
      padding: 12px 18px;
      font-size: 13.5px;
      font-weight: 600;
      text-decoration: none;
      border-radius: 4px;
      cursor: pointer;
      transition: opacity 0.15s ease;
    }
    .btn:hover { opacity: 0.92; }
    .btn-primary {
      background: var(--ink);
      color: var(--bg);
    }
    .btn-secondary {
      background: transparent;
      color: var(--ink);
      border: 1px solid var(--border);
    }
    .instructions {
      margin-top: 32px;
      border-top: 1px solid var(--border);
      padding-top: 24px;
    }
    .instructions h2 {
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 1px;
      text-transform: uppercase;
      color: var(--muted);
      margin-bottom: 16px;
    }
    .instruction-item {
      margin-bottom: 16px;
      font-size: 13px;
      color: var(--muted);
    }
    .instruction-item strong {
      color: var(--ink);
      display: block;
      margin-bottom: 3px;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div class="kicker">Athena Mobile Release</div>
      <h1>Download Athena</h1>
      <p class="subtitle">Direct, 1-click native packages and local client streaming.</p>
    </div>

    <div class="card" id="android-card">
      <div id="android-badge" style="display:none;" class="badge">Current Device</div>
      <div class="card-title">Athena for Android</div>
      <p class="card-desc">Compiled standalone APK with local network discovery and in-app updates.</p>
      <a class="btn btn-primary" href="/api/download/android">Download Athena-Android.apk</a>
    </div>

    <div class="card" id="ios-card">
      <div id="ios-badge" style="display:none;" class="badge">Current Device</div>
      <div class="card-title">Athena for iOS (iPhone &amp; iPad)</div>
      <p class="card-desc">Universal iOS package for Sideloadly, AltStore, or SideStore installation.</p>
      <a class="btn btn-primary" href="/api/download/ios">Download Athena-iOS.ipa</a>
    </div>

    <div class="card">
      <div class="card-title">Athena Web Reader</div>
      <p class="card-desc">Read directly in any modern browser without installing native binaries.</p>
      <a class="btn btn-secondary" href="/">Open Web Reader</a>
    </div>

    <div class="instructions">
      <h2>Installation Reference</h2>
      <div class="instruction-item">
        <strong>Android</strong>
        Download Athena-Android.apk and tap to install. Supports automatic tracking and updates via Obtainium.
      </div>
      <div class="instruction-item">
        <strong>iOS Native Sideloading (No Mac or Xcode Required)</strong>
        Download Athena-iOS.ipa to your PC and install using free Sideloadly or AltStore via USB with a standard Apple ID.
      </div>
      <div class="instruction-item">
        <strong>iOS Instant Home Screen App</strong>
        Open this server address in mobile Safari, tap Share, and select &ldquo;Add to Home Screen&rdquo; for a persistent, standalone fullscreen reading mode.
      </div>
    </div>
  </div>

  <script>
    (function() {
      var ua = navigator.userAgent || navigator.vendor || window.opera;
      if (/android/i.test(ua)) {
        var c = document.getElementById('android-card');
        var b = document.getElementById('android-badge');
        if (c) c.classList.add('highlight');
        if (b) b.style.display = 'inline-block';
      } else if (/iPad|iPhone|iPod/.test(ua) && !window.MSStream) {
        var c = document.getElementById('ios-card');
        var b = document.getElementById('ios-badge');
        if (c) c.classList.add('highlight');
        if (b) b.style.display = 'inline-block';
      }
    })();
  </script>
</body>
</html>"""
    return HTMLResponse(content=html_content, status_code=200)


@app.get("/api/version")
def get_app_version():
    """Returns the current deployed version and release metadata."""
    data = {
        "version": "0.1.1",
        "build_number": 2,
        "title": "Athena v0.1.1 Update",
        "release_notes": "Zero-keyword structural document bouncer, BYOK awakening screen, and one-click Android APK & iOS IPA downloads.",
        "published_at": "2026-10-24T17:50:00Z",
        "download_url_apk": "/api/download/android",
        "download_url_ipa": "/api/download/ios",
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
    return data


# Flutter Web (app/build/web) is served from the same origin as /api/*
# so phones on LAN IP or a tunnel never hit mixed-content or CORS.
_web_static = (
    StaticFiles(directory=_WEB_BUILD_DIR, html=True)
    if os.path.isdir(_WEB_BUILD_DIR)
    else None
)


@app.get("/{full_path:path}")
async def serve_static_or_spa(full_path: str, request: Request):
    if full_path.startswith("api/") or full_path == "api":
        return JSONResponse(status_code=404, content={"error": "Not found"})

    if full_path.startswith("releases/"):
        rel_sub = full_path.replace("releases/", "", 1).lstrip(r"\/")
        rel_file = os.path.join(_RELEASES_DIR, rel_sub)
        if os.path.isfile(rel_file):
            return FileResponse(rel_file)

    global _web_static
    if _web_static is None and os.path.isdir(_WEB_BUILD_DIR):
        _web_static = StaticFiles(directory=_WEB_BUILD_DIR, html=True)

    if _web_static is not None:
        try:
            return await _web_static.get_response(full_path, request.scope)
        except StarletteHTTPException:
            index_html = os.path.join(_WEB_BUILD_DIR, "index.html")
            if os.path.isfile(index_html):
                return FileResponse(index_html)
            return JSONResponse(status_code=404, content={"error": "Not found"})

    return JSONResponse(status_code=404, content={"error": "Not found"})


