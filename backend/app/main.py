from contextlib import asynccontextmanager
import json
import logging
import os
import re
import time
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.db import init_db
from app.errors import AppException, app_exception_handler, generic_exception_handler
from app.routers import ask, cards, documents, settings, updates
from app.services.ingestion.jobs import cleanup_interrupted_jobs
from app.services.marginalia.pipeline import ReadAheadPipeline

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
    version="1.1.0",
    license_info={
        "name": "GNU General Public License v3.0",
        "url": "https://www.gnu.org/licenses/gpl-3.0.html",
    },
    lifespan=lifespan,
)

# Browser clients run locally, over Wi-Fi LAN, or via public online tunnels.
_ALLOWED_ORIGIN = re.compile(
    r"^https?://(?:localhost|127\.0\.0\.1|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)(?::\d+)?$"
)

_EXPLICIT_ALLOWED_ORIGINS = {
    origin.strip().rstrip("/")
    for origin in os.environ.get("ATHENA_ALLOWED_ORIGINS", "").split(",")
    if origin.strip()
}


@app.middleware("http")
async def require_lan_pairing_token(request: Request, call_next):
    pairing_token = os.environ.get("ATHENA_PAIRING_TOKEN", "").strip()
    if pairing_token:
        client_host = getattr(request.client, "host", "") if request.client else ""
        is_loopback = client_host in {"127.0.0.1", "::1", "localhost", "testclient"}
        path = request.url.path
        is_exempt = path in {"/api/health", "/api/pair-info", "/api/version", "/health", "/api"} or not path.startswith("/api/")
        if not is_loopback and not is_exempt:
            token = request.headers.get("X-Athena-Pairing-Token", "").strip()
            import secrets
            if not token or not secrets.compare_digest(token, pairing_token):
                return JSONResponse(
                    status_code=401,
                    content={
                        "error": {
                            "code": "UNAUTHORIZED_PAIRING",
                            "message": "Valid X-Athena-Pairing-Token header is required for remote LAN access.",
                        }
                    },
                )
    return await call_next(request)


@app.middleware("http")
async def reject_untrusted_browser_mutations(request, call_next):
    origin = request.headers.get("origin")
    host = request.headers.get("host")
    if origin and request.method not in {"GET", "HEAD", "OPTIONS"}:
        is_same_origin = host and (origin.endswith(f"://{host}") or origin == f"http://{host}" or origin == f"https://{host}")
        if not is_same_origin and not _ALLOWED_ORIGIN.fullmatch(origin) and origin.rstrip("/") not in _EXPLICIT_ALLOWED_ORIGINS:
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
async def add_security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response


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
    allow_origins=sorted(_EXPLICIT_ALLOWED_ORIGINS),
    allow_origin_regex=_ALLOWED_ORIGIN.pattern,
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD"],
    allow_headers=["Content-Type", "X-Athena-Context-Token", "X-Athena-Pairing-Token", "Authorization", "Accept"],
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
    """Liveness & readiness check; verifies SQLite reachability."""
    from app.services.edge.novelty import embedding_readiness
    db_status = "ok"
    try:
        from app.db import engine
        from sqlalchemy import text
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception as db_err:
        logger.warning("Database health check failed: %s", db_err)
        db_status = "error"

    model_status = embedding_readiness()

    return {
        "status": "ok" if db_status == "ok" else "degraded",
        "database": db_status,
        "model_status": model_status,
        "llm_configured": any(os.environ.get(name, "").strip() for name in (
            "LLM_API_KEY", "GEMINI_API_KEY_PRIMARY", "GEMINI_API_KEY_SECONDARY"
        )),
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
    try:
        api_port = int(os.environ.get("ATHENA_PORT", "8000"))
    except ValueError:
        api_port = 8000
    try:
        web_port = int(os.environ.get("ATHENA_WEB_PORT", "8080"))
    except ValueError:
        web_port = 8080

    return {
        "status": "ok",
        "lan_ip": lan_ip,
        "api_port": api_port,
        "web_port": web_port,
        "base_url": f"http://{lan_ip}:{api_port}",
        "phone_wifi_url": f"http://{lan_ip}:{api_port}",
        "desktop_url": f"http://127.0.0.1:{web_port}",
        "tunnel_url": tunnel_url,
        "pairing_required": bool(os.environ.get("ATHENA_PAIRING_TOKEN", "").strip()),
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
    import socket

    lan_ip = "127.0.0.1"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            lan_ip = s.getsockname()[0]
    except Exception:
        pass
    lan_url = f"http://{lan_ip}:8000"

    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Athena &mdash; Mobile App Downloads</title>
  <style>
    :root {{
      --bg: #FBF9F5;
      --card-bg: #FFFFFF;
      --border: #E5E2DA;
      --ink: #161615;
      --muted: #6B6860;
      --accent: #C84B31;
      --accent-subtle: #F4EBE8;
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --bg: #141413;
        --card-bg: #1C1B19;
        --border: #2E2D2A;
        --ink: #F2EFE9;
        --muted: #9E9B93;
        --accent: #D95D43;
        --accent-subtle: #2B1D1A;
      }}
    }}
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      background: var(--bg);
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      padding: 36px 18px 48px;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
    }}
    .container {{
      max-width: 560px;
      margin: 0 auto;
    }}
    .header {{
      margin-bottom: 28px;
    }}
    .kicker {{
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 1.2px;
      text-transform: uppercase;
      color: var(--accent);
      margin-bottom: 8px;
    }}
    h1 {{
      font-size: 26px;
      font-weight: 600;
      letter-spacing: -0.4px;
      margin-bottom: 6px;
    }}
    .subtitle {{
      font-size: 14px;
      color: var(--muted);
    }}
    .card {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 20px;
      margin-bottom: 16px;
      transition: border-color 0.15s ease;
    }}
    .card.highlight {{
      border-color: var(--accent);
      box-shadow: 0 0 0 1px var(--accent);
    }}
    .badge {{
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
    }}
    .card-title {{
      font-size: 16px;
      font-weight: 600;
      margin-bottom: 4px;
    }}
    .card-desc {{
      font-size: 13px;
      color: var(--muted);
      margin-bottom: 14px;
    }}
    .btn {{
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
    }}
    .btn:hover {{ opacity: 0.92; }}
    .btn-primary {{
      background: var(--ink);
      color: var(--bg);
    }}
    .btn-secondary {{
      background: transparent;
      color: var(--ink);
      border: 1px solid var(--border);
    }}
    .instructions {{
      margin-top: 32px;
      border-top: 1px solid var(--border);
      padding-top: 24px;
    }}
    .instructions h2 {{
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 1px;
      text-transform: uppercase;
      color: var(--muted);
      margin-bottom: 16px;
    }}
    .instruction-item {{
      margin-bottom: 16px;
      font-size: 13px;
      color: var(--muted);
    }}
    .instruction-item strong {{
      color: var(--ink);
      display: block;
      margin-bottom: 3px;
    }}
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div class="kicker">Athena Mobile Release</div>
      <h1>Download Athena</h1>
      <p class="subtitle">Direct, 1-click native packages and local client streaming.</p>
    </div>

    <div style="background: rgba(45, 106, 79, 0.08); border: 1px solid #2D6A4F; border-radius: 6px; padding: 14px 16px; margin-bottom: 20px;">
      <div style="font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.8px; color: #2D6A4F; margin-bottom: 4px;">Athena Server Address</div>
      <div style="font-family: monospace; font-size: 15px; font-weight: 600; color: var(--ink); margin-bottom: 4px;">{lan_url}</div>
      <div style="font-size: 12px; color: var(--muted);">The APK is pre-configured to automatically connect to this address over Wi-Fi.</div>
    </div>

    <div class="card" id="android-card">
      <div id="android-badge" style="display:none;" class="badge">Current Device</div>
      <div class="card-title">Athena for Android</div>
      <p class="card-desc">Compiled standalone APK with local network discovery and in-app updates.</p>
      <a class="btn btn-primary" href="/api/download/android">Download Athena-Android.apk</a>
    </div>

    <div class="card">
      <div class="card-title">Athena Web Reader</div>
      <p class="card-desc">Read directly in any modern browser without installing native binaries.</p>
      <a class="btn btn-secondary" href="/">Open Web Reader</a>
      <a href="/api/download/ios" style="display:none;" aria-hidden="true">Athena-iOS.ipa</a>
    </div>

    <div class="instructions">
      <h2>Installation Reference</h2>
      <div class="instruction-item">
        <strong>Android</strong>
        Download Athena-Android.apk and tap to install. Supports automatic tracking and updates via Obtainium.
      </div>
      <div class="instruction-item">
        <strong>Web &amp; PWA (Any Device)</strong>
        Open this server address in your browser, tap Share/Options, and select &ldquo;Add to Home Screen&rdquo; for a persistent, standalone fullscreen reading mode.
      </div>
    </div>
  </div>

  <script>
    (function() {{
      var ua = navigator.userAgent || navigator.vendor || window.opera;
      if (/android/i.test(ua)) {{
        var c = document.getElementById('android-card');
        var b = document.getElementById('android-badge');
        if (c) c.classList.add('highlight');
        if (b) b.style.display = 'inline-block';
      }}
    }})();
  </script>
</body>
</html>"""
    return HTMLResponse(content=html_content, status_code=200)


@app.get("/api/version")
def get_app_version():
    """Returns the current deployed version and release metadata."""
    data = {
        "version": "1.1.0",
        "build_number": 2,
        "title": "Athena v1.1.0 Release",
        "release_notes": "Clean high-performance reading engine with verified academic marginalia.",
        "published_at": "2026-10-28T00:00:00Z",
        "download_url_apk": "/api/download/android",
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
        raw_name = full_path.replace("releases/", "", 1)
        if ".." in raw_name or "/" in raw_name or "\\" in raw_name:
            return JSONResponse(status_code=400, content={"error": "Invalid release artifact path"})
        base_dir = Path(_RELEASES_DIR).resolve()
        target_path = (base_dir / Path(raw_name).name).resolve()
        if not target_path.is_relative_to(base_dir) or not target_path.is_file():
            return JSONResponse(status_code=404, content={"error": "Release artifact not found"})
        return FileResponse(target_path)

    global _web_static
    if _web_static is None and os.path.isdir(_WEB_BUILD_DIR):
        _web_static = StaticFiles(directory=_WEB_BUILD_DIR, html=True)

    if _web_static is not None:
        try:
            response = await _web_static.get_response(full_path, request.scope)
            response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
            response.headers["Pragma"] = "no-cache"
            response.headers["Expires"] = "0"
            return response
        except StarletteHTTPException:
            if Path(full_path).suffix.lower() in {".js", ".mjs", ".css", ".wasm", ".png", ".jpg", ".jpeg", ".svg", ".ico", ".ttf", ".woff", ".woff2", ".json"}:
                return JSONResponse(status_code=404, content={"error": "Not found"})
            index_html = os.path.join(_WEB_BUILD_DIR, "index.html")
            if os.path.isfile(index_html):
                response = FileResponse(index_html)
                response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
                response.headers["Pragma"] = "no-cache"
                response.headers["Expires"] = "0"
                return response
            return JSONResponse(status_code=404, content={"error": "Not found"})

    return JSONResponse(status_code=404, content={"error": "Not found"})


