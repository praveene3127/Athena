from pathlib import Path
from typing import Optional
from dotenv import load_dotenv
from pydantic_settings import BaseSettings, SettingsConfigDict

# Load .env file from project or backend root if present; missing .env must not crash
_backend_dir = Path(__file__).resolve().parent.parent
_env_path = _backend_dir / ".env"
if _env_path.exists():
    load_dotenv(_env_path)
else:
    load_dotenv()


class Settings(BaseSettings):
    """Central production settings validated via Pydantic."""

    model_config = SettingsConfigDict(
        env_file=str(_env_path) if _env_path.exists() else None,
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Server & Paths
    DATA_DIR: str = "data"
    HOST: str = "127.0.0.1"
    PORT: int = 8000
    LOG_LEVEL: str = "INFO"

    # Ingestion & Limits
    MAX_UPLOAD_SIZE_BYTES: int = 500 * 1024 * 1024  # 500 MB
    MAX_PAGE_COUNT: int = 3000
    MIN_PROSE_WORDS: int = 350
    MIN_SENTENCE_COUNT: int = 6

    # AI & Proxy Keys
    LLM_API_KEY: Optional[str] = None
    LLM_BASE_URL: Optional[str] = None
    LLM_MODEL: Optional[str] = ""
    GEMINI_API_KEY_PRIMARY: Optional[str] = None
    GEMINI_API_KEY_SECONDARY: Optional[str] = None
    GEMINI_MODEL: str = ""
    ATHENA_CONTEXT_PROXY_TOKEN: Optional[str] = None
    WIKI_CONTACT: str = "athena-reader@example.com"
    VIBE_CHECK_TIMEOUT_S: float = 4.5


settings = Settings()

# --- Athena Ingestion & Chunking Constants ---
TARGET_CHUNK_WORDS: int = 50
MIN_CHUNK_WORDS: int = 35
MAX_CHUNK_WORDS: int = 65
MAX_CHUNK_CHARS: int = 380
CHUNK_ID_PAD_WIDTH: int = 6
SEGMENTATION_VERSION: str = "segmentation-v3"
OFFSET_PROTOCOL: str = "utf8-byte-v3"
DOCUMENT_STATES: list[str] = [
    "queued",
    "processing",
    "partially_readable",
    "paused",
    "interrupted",
    "ready",
    "failed",
    "unsupported",
    "deleted",
]
METHOD_CHANNEL_NAME: str = "athena/foreground_ingestion"
METHOD_CHANNEL_METHODS: list[str] = [
    "startForegroundService",
    "updateForegroundProgress",
    "stopForegroundService",
    "requestNotificationPermission",
]
MARGIN_FRACTION: float = 0.07

# Card Generation - Warm Start Budget (initial batch at ingestion time)
# This is NOT a whole-book limit. Full coverage is handled by ReadAheadPipeline.
WARM_START_MAX_CARDS: int = 24  # 3x previous, allows diverse initial coverage
WARM_START_WIKI_LOOKUPS: int = 24
WARM_START_CHUNK_GAP: int = 3
WARM_START_MAX_PER_SECTION: int = 5  # Per-section quota for warm start

# Card Generation - Coverage-Based Ongoing (ReadAheadPipeline)
COVERAGE_CARDS_PER_1000_WORDS: int = 4  # Target: ~1 card per 250 eligible words
COVERAGE_MIN_CHUNK_GAP: int = 3
COVERAGE_MAX_SECTION_QUOTA: int = 8  # Per-section max for ongoing generation

# Legacy aliases for backward compatibility (DEPRECATED - use warm_start/coverage constants)
MAX_CARDS_PER_DOC: int = WARM_START_MAX_CARDS
MIN_CHUNK_GAP_BETWEEN_CARDS: int = WARM_START_CHUNK_GAP
MAX_WIKI_LOOKUPS_PER_DOC: int = WARM_START_WIKI_LOOKUPS

CARD_MAX_WORDS: int = 80
ASK_MAX_QUESTION_CHARS: int = 2000
ASK_MAX_ANSWER_WORDS: int = 120
WIKI_TIMEOUT_S: float = 8.0
LLM_TIMEOUT_S: float = 20.0
STATUS_POLL_MS: int = 1500
ASK_RATE_LIMIT: int = 12  # requests per minute
MAX_UPLOAD_SIZE_BYTES: int = settings.MAX_UPLOAD_SIZE_BYTES
MAX_PAGE_COUNT: int = settings.MAX_PAGE_COUNT
MIN_PROSE_WORDS: int = settings.MIN_PROSE_WORDS
MIN_SENTENCE_COUNT: int = settings.MIN_SENTENCE_COUNT

# --- Paths & Directories ---
BASE_DIR: Path = _backend_dir
_data_dir_path = Path(settings.DATA_DIR)
DATA_DIR: Path = _data_dir_path if _data_dir_path.is_absolute() else BASE_DIR / _data_dir_path

UPLOADS_DIR: Path = DATA_DIR / "uploads"
RAW_DIR: Path = DATA_DIR / "raw"
CACHE_DIR: Path = DATA_DIR / "cache"
WIKI_CACHE_DIR: Path = CACHE_DIR / "wiki"
FASTEMBED_CACHE_DIR: Path = CACHE_DIR / "fastembed"
DB_PATH: Path = DATA_DIR / "athena.db"

def ensure_runtime_dirs() -> None:
    """Creates runtime storage directories (called during FastAPI startup)."""
    for path in (DATA_DIR, UPLOADS_DIR, RAW_DIR, CACHE_DIR, WIKI_CACHE_DIR, FASTEMBED_CACHE_DIR):
        path.mkdir(parents=True, exist_ok=True)

# Ensure runtime directories exist on import as graceful fallback
ensure_runtime_dirs()

# --- Environment Configuration Aliases ---
LLM_API_KEY: Optional[str] = settings.LLM_API_KEY
LLM_BASE_URL: Optional[str] = settings.LLM_BASE_URL
LLM_MODEL: Optional[str] = settings.LLM_MODEL
GEMINI_API_KEY_PRIMARY: Optional[str] = settings.GEMINI_API_KEY_PRIMARY
GEMINI_API_KEY_SECONDARY: Optional[str] = settings.GEMINI_API_KEY_SECONDARY
GEMINI_MODEL: str = settings.GEMINI_MODEL
ATHENA_CONTEXT_PROXY_TOKEN: Optional[str] = settings.ATHENA_CONTEXT_PROXY_TOKEN
WIKI_CONTACT: str = settings.WIKI_CONTACT


def is_llm_configured() -> bool:
    """Returns True if at least one configured provider key is non-empty (env or SQLite ai_settings)."""
    if any(key and key.strip() for key in (
        GEMINI_API_KEY_PRIMARY,
        GEMINI_API_KEY_SECONDARY,
        LLM_API_KEY,
    )):
        return True
    try:
        from app.db import engine
        from app.models import AISettings
        from sqlmodel import Session, select
        with Session(engine) as s:
            saved = s.exec(select(AISettings).where(AISettings.id == "global")).first()
            if saved and (saved.primary_api_key or saved.primary_provider == "custom"):
                return True
    except Exception:
        pass
    return False

