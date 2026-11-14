from typing import Generator
from sqlmodel import SQLModel, create_engine, Session
from sqlalchemy import event
from sqlalchemy.engine import Engine
from app.config import DB_PATH
import logging

logger = logging.getLogger("athena.db")

# Format SQLite URL; ensure forward slashes on Windows
_db_url = f"sqlite:///{DB_PATH.as_posix()}"

engine = create_engine(
    _db_url,
    connect_args={"check_same_thread": False, "timeout": 15},
)


@event.listens_for(Engine, "connect")
def set_sqlite_pragma(dbapi_connection, connection_record):
    """Enforce WAL mode, busy timeout, and concurrency pragmas on every connection."""
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA journal_mode = WAL;")
    cursor.execute("PRAGMA synchronous = NORMAL;")
    cursor.execute("PRAGMA busy_timeout = 10000;")
    cursor.execute("PRAGMA wal_autocheckpoint = 1000;")
    cursor.execute("PRAGMA foreign_keys = ON;")
    cursor.close()


def _migrate_columns():
    """Adds missing columns dynamically to existing SQLite tables."""
    from sqlalchemy import text
    with engine.begin() as conn:
        # Check documents columns
        doc_cols = {r[1] for r in conn.execute(text("PRAGMA table_info(documents)")).fetchall()}
        if doc_cols:
            if "extracted_text_sha256" not in doc_cols:
                conn.execute(text("ALTER TABLE documents ADD COLUMN extracted_text_sha256 TEXT DEFAULT NULL"))
            if "canonical_sha256" not in doc_cols:
                conn.execute(text("ALTER TABLE documents ADD COLUMN canonical_sha256 TEXT DEFAULT NULL"))
            if "repairs_count" not in doc_cols:
                conn.execute(text("ALTER TABLE documents ADD COLUMN repairs_count INTEGER DEFAULT 0"))
            if "processed_page" not in doc_cols:
                conn.execute(text("ALTER TABLE documents ADD COLUMN processed_page INTEGER DEFAULT 0"))

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
            if "document_title" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN document_title TEXT DEFAULT NULL"))
            if "section_title" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN section_title TEXT DEFAULT NULL"))
            if "page_reference" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN page_reference TEXT DEFAULT NULL"))
            if "support_status" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN support_status TEXT DEFAULT 'fully_supported'"))
            if "support_tier" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN support_tier TEXT DEFAULT 'verified_external'"))
            if "canonical_sha256" not in cc_cols:
                conn.execute(text("ALTER TABLE context_cards ADD COLUMN canonical_sha256 TEXT DEFAULT NULL"))


def _ensure_indexes() -> None:
    """Adds missing performance indexes via CREATE INDEX IF NOT EXISTS (strictly no ALTER TABLE)."""
    from sqlalchemy import text
    with engine.begin() as conn:
        conn.execute(text("CREATE INDEX IF NOT EXISTS idx_chunks_doc_seq ON reading_chunks(document_id, sequence)"))
        conn.execute(text("CREATE INDEX IF NOT EXISTS idx_cards_doc_chunk ON context_cards(document_id, source_chunk_id)"))


def _ensure_fts() -> None:
    """Creates SQLite C-engine FTS5 virtual table for sub-millisecond lexical search with auto-sync triggers."""
    from sqlalchemy import text
    with engine.begin() as conn:
        try:
            conn.execute(text(
                "CREATE VIRTUAL TABLE IF NOT EXISTS reading_chunks_fts "
                "USING fts5(chunk_id UNINDEXED, document_id UNINDEXED, sequence UNINDEXED, section_title, raw_text, "
                "tokenize='porter unicode61 remove_diacritics 2');"
            ))
            conn.execute(text("""
                CREATE TRIGGER IF NOT EXISTS reading_chunks_ai AFTER INSERT ON reading_chunks BEGIN
                    INSERT INTO reading_chunks_fts(chunk_id, document_id, sequence, section_title, raw_text)
                    VALUES (new.id, new.document_id, new.sequence, new.section_title, new.raw_text);
                END;
            """))
            conn.execute(text("""
                CREATE TRIGGER IF NOT EXISTS reading_chunks_ad AFTER DELETE ON reading_chunks BEGIN
                    DELETE FROM reading_chunks_fts WHERE chunk_id = old.id;
                END;
            """))
            conn.execute(text("""
                CREATE TRIGGER IF NOT EXISTS reading_chunks_au AFTER UPDATE ON reading_chunks BEGIN
                    DELETE FROM reading_chunks_fts WHERE chunk_id = old.id;
                    INSERT INTO reading_chunks_fts(chunk_id, document_id, sequence, section_title, raw_text)
                    VALUES (new.id, new.document_id, new.sequence, new.section_title, new.raw_text);
                END;
            """))
        except Exception as exc:
            logger.warning("SQLite FTS5 unavailable; lexical search index was not initialized: %s", exc)


def init_db() -> None:
    """Creates all database tables defined in SQLModel metadata and ensures performance indexes."""
    import app.models  # noqa: F401
    SQLModel.metadata.create_all(engine)
    _migrate_columns()
    _ensure_indexes()
    _ensure_fts()




def get_session() -> Generator[Session, None, None]:
    """Dependency for providing a fresh database session per request."""
    with Session(engine) as session:
        yield session
