"""
Pass 2 Backend Verification Suite:
- Keyset Windowed Reader Pagination (?from_seq=1&limit=200)
- Bulk SQL Deletions on Document Removal
- 6-Digit Chunk IDs ({doc_id}-c{seq:06d})
- Zero Large Text Blobs in Document Model (canonical_text & spans_json dropped from DB row)
- Unified FTS5 Schema and Triggers
"""
import pytest
from pathlib import Path
from fastapi.testclient import TestClient
from sqlmodel import Session, select, func

from app.main import app
from app.db import engine, init_db
from app.models import Document, ReadingChunk, ContextCard, DocumentChapter, ReadingState
from app.services.ingestion.chunker import chunk_document


@pytest.fixture(autouse=True)
def ensure_database():
    init_db()


def test_chunk_id_six_digit_formatting():
    """P1-01: Chunk IDs must use at least 6 zero-padded digits to support books >= 10,000 chunks."""
    doc_id = "doc_pass2_test_six_digits"
    canonical_text = "Word " * 200
    spans = [{"start": 0, "end": len(canonical_text), "page_start": 1, "page_end": 1, "type": "paragraph"}]
    chunks = chunk_document(doc_id=doc_id, canonical_text=canonical_text, spans=spans)
    assert len(chunks) > 0
    for c in chunks:
        # Expected format: doc_id-c000001
        assert f"{doc_id}-c0" in c["id"]
        # Verify exactly 6 digits after -c
        chunk_part = c["id"].split("-c")[-1]
        assert len(chunk_part) >= 6
        assert chunk_part.isdigit()


def test_reader_keyset_windowing():
    """P1-09 / P1-10: GET /api/documents/{id}/reader supports windowing with from_seq and limit."""
    client = TestClient(app)
    doc_id = "doc_pass2_windowing_test"

    # Pre-clean
    client.delete(f"/api/documents/{doc_id}")

    with Session(engine) as session:
        # Create a document with 100 chunks
        doc = Document(
            id=doc_id,
            filename="window_book.pdf",
            title="Window Book",
            status="ready",
            page_count=50,
            integrity_verified=True,
            original_checksum="fake_sha",
            reconstructed_checksum="fake_sha",
        )
        session.add(doc)

        for seq in range(1, 101):
            chunk = ReadingChunk(
                id=f"{doc_id}-c{seq:06d}",
                document_id=doc_id,
                sequence=seq,
                raw_text=f"This is chunk {seq} of the windowing test.",
                start_offset=(seq - 1) * 40,
                end_offset=seq * 40,
                checksum=f"chk_{seq}",
                source_pages_json="[1]",
            )
            session.add(chunk)

        session.commit()

    # Query with from_seq=25 and limit=10
    response = client.get(f"/api/documents/{doc_id}/reader?from_seq=25&limit=10")
    assert response.status_code == 200
    data = response.json()

    assert "document" in data
    assert "items" in data
    assert "chunks" in data
    assert "cards" in data

    chunks_returned = data["chunks"]
    assert len(chunks_returned) == 10
    assert chunks_returned[0]["sequence"] == 25
    assert chunks_returned[-1]["sequence"] == 34

    # Verify total chunk count in integrity proof is 100 (total in DB)
    assert data["document"]["integrity"]["chunk_count"] == 100

    # Clean up
    client.delete(f"/api/documents/{doc_id}")


def test_bulk_sql_delete_document():
    """P1-16: delete_document performs efficient bulk SQL deletes."""
    client = TestClient(app)
    doc_id = "doc_pass2_bulk_delete"

    # Pre-clean
    client.delete(f"/api/documents/{doc_id}")

    with Session(engine) as session:
        doc = Document(
            id=doc_id,
            filename="delete_me.pdf",
            title="Delete Me",
            status="ready",
            page_count=5,
        )
        session.add(doc)
        for seq in range(1, 20):
            session.add(ReadingChunk(
                id=f"{doc_id}-c{seq:06d}",
                document_id=doc_id,
                sequence=seq,
                raw_text=f"Chunk {seq}",
                start_offset=0,
                end_offset=10,
                checksum="chk",
            ))
        session.commit()

    del_resp = client.delete(f"/api/documents/{doc_id}")
    assert del_resp.status_code == 200
    assert del_resp.json()["status"] == "deleted"

    with Session(engine) as session:
        remaining_chunks = session.exec(
            select(func.count(ReadingChunk.id)).where(ReadingChunk.document_id == doc_id)
        ).one()
        assert remaining_chunks == 0


def test_sqlite_store_rust_schema_alignment():
    """D6: Verify rust_core/src/sqlite_store.rs uses exact same column names as local_database.dart."""
    rust_store_path = Path("backend/rust_core/src/sqlite_store.rs")
    if not rust_store_path.exists():
        rust_store_path = Path("rust_core/src/sqlite_store.rs")
    assert rust_store_path.exists(), "Rust sqlite_store.rs must exist"
    content = rust_store_path.read_text(encoding="utf-8")

    # Column names that MUST exist in sqlite_store.rs INSERT statement
    required_cols = [
        "id",
        "document_id",
        "sequence",
        "raw_text",
        "start_offset",
        "end_offset",
        "page_start",
        "page_end",
        "section_title",
        "section_role",
        "source_pages_json",
        "checksum",
        "canonical_sha256",
        "boundary_method",
        "simhash",
    ]
    for col in required_cols:
        assert col in content, f"Column '{col}' must be present in sqlite_store.rs"

    # Forbid buggy old column names in INSERT
    assert "start_char_offset" not in content, "Buggy column start_char_offset must be removed"
    assert "end_char_offset" not in content, "Buggy column end_char_offset must be removed"


def test_fts5_triggers_installed():
    """P1-03 / P1-04: Verify FTS5 triggers are present in SQLite."""
    from sqlalchemy import text
    with engine.begin() as conn:
        triggers = conn.execute(text("SELECT name FROM sqlite_master WHERE type = 'trigger'")).fetchall()
        trigger_names = {t[0] for t in triggers}
        assert "reading_chunks_ai" in trigger_names
        assert "reading_chunks_ad" in trigger_names
        assert "reading_chunks_au" in trigger_names
