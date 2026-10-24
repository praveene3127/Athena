from typing import Generator
from sqlmodel import SQLModel, create_engine, Session
from sqlalchemy import event
from sqlalchemy.engine import Engine
from app.config import DB_PATH

# Format SQLite URL; ensure forward slashes on Windows
_db_url = f"sqlite:///{DB_PATH.as_posix()}"

engine = create_engine(
    _db_url,
    connect_args={"check_same_thread": False},
)


@event.listens_for(Engine, "connect")
def set_sqlite_pragma(dbapi_connection, connection_record):
    """Enforce WAL mode and 5000ms busy timeout on every connection (§4 in CLAUDE.md)."""
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA busy_timeout=5000")
    cursor.close()


def _migrate_columns():
    """Adds missing columns dynamically to existing SQLite tables."""
    from sqlalchemy import text
    with engine.begin() as conn:
        # Check reading_chunks columns
        rc_cols = {r[1] for r in conn.execute(text("PRAGMA table_info(reading_chunks)")).fetchall()}
        if rc_cols:
            if "boundary_method" not in rc_cols:
                conn.execute(text("ALTER TABLE reading_chunks ADD COLUMN boundary_method TEXT DEFAULT 'paragraph'"))
            if "canonical_sha256" not in rc_cols:
                conn.execute(text("ALTER TABLE reading_chunks ADD COLUMN canonical_sha256 TEXT DEFAULT NULL"))

        # Check context_cards columns
        cc_cols = {r[1] for r in conn.execute(text("PRAGMA table_info(context_cards)")).fetchall()}
        if cc_cols:
            if "exact_quote" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN exact_quote TEXT DEFAULT NULL"))
            if "support_status" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN support_status TEXT DEFAULT 'fully_supported'"))
            if "canonical_sha256" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN canonical_sha256 TEXT DEFAULT NULL"))


def _ensure_indexes() -> None:
    """Adds missing performance indexes via CREATE INDEX IF NOT EXISTS (strictly no ALTER TABLE)."""
    from sqlalchemy import text
    with engine.begin() as conn:
        conn.execute(text("CREATE INDEX IF NOT EXISTS idx_chunks_doc_seq ON reading_chunks(document_id, sequence)"))
        conn.execute(text("CREATE INDEX IF NOT EXISTS idx_cards_doc_chunk ON context_cards(document_id, source_chunk_id)"))


def init_db() -> None:
    """Creates all database tables defined in SQLModel metadata and ensures performance indexes."""
    import app.models  # noqa: F401
    SQLModel.metadata.create_all(engine)
    _migrate_columns()
    _ensure_indexes()




def get_session() -> Generator[Session, None, None]:
    """Dependency for providing a fresh database session per request."""
    with Session(engine) as session:
        yield session
