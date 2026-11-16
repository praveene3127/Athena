import os
import json
import uuid
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.main import app
from app.db import engine, init_db
from app.models import Document, ReadingChunk, ContextCard, AISettings
from app.config import is_llm_configured


init_db()
client = TestClient(app)


def test_b01_force_ingest_ready_document_rejected():
    """B01: force-ingest on ready/processing book returns 409 and never wipes chunks."""
    doc_id = f"test-doc-ready-b01-{uuid.uuid4().hex[:8]}"
    with Session(engine) as session:
        # Create ready document with chunks
        doc = Document(
            id=doc_id,
            filename="book.pdf",
            title="Ready Test Book",
            status="ready",
            stage="done",
            percent=100,
            page_count=5,
            processed_page=5,
        )
        session.add(doc)
        chunk = ReadingChunk(
            id=f"{doc_id}-chunk-1",
            document_id=doc_id,
            sequence=1,
            section_title="Chapter 1",
            raw_text="This is precious chunk text that must not be wiped.",
            start_offset=0,
            end_offset=50,
            checksum="abc123",
        )
        session.add(chunk)
        session.commit()

    try:
        # Calling force-ingest on a ready doc must return 409 Conflict
        resp = client.post(f"/api/documents/{doc_id}/force-ingest")
        assert resp.status_code == 409
        assert "cannot be force-ingested" in resp.json()["error"]["message"]

        # Verify chunks were NOT wiped
        with Session(engine) as session:
            chunks = session.exec(select(ReadingChunk).where(ReadingChunk.document_id == doc_id)).all()
            assert len(chunks) == 1
            assert chunks[0].raw_text == "This is precious chunk text that must not be wiped."
            refreshed_doc = session.get(Document, doc_id)
            assert refreshed_doc.status == "ready"
    finally:
        client.delete(f"/api/documents/{doc_id}")


def test_b02_saved_and_dismissed_mutual_exclusivity():
    """B02: saved and dismissed are mutually exclusive on ContextCard."""
    doc_id = f"test-doc-b02-{uuid.uuid4().hex[:8]}"
    card_id = f"test-card-b02-{uuid.uuid4().hex[:8]}"
    with Session(engine) as session:
        doc = Document(id=doc_id, filename="book.pdf", title="Card Test Book", status="ready")
        session.add(doc)
        chunk = ReadingChunk(
            id=f"{doc_id}-c1",
            document_id=doc_id,
            sequence=1,
            raw_text="Some text",
            start_offset=0,
            end_offset=9,
            checksum="chk1",
        )
        session.add(chunk)
        card = ContextCard(
            id=card_id,
            document_id=doc_id,
            source_chunk_id=chunk.id,
            concept_name="Test Concept",
            title="Test Insight",
            body="Insight body text.",
            why_here="Grounded context from primary sources.",
            exact_quote="Some text",
            saved=False,
            dismissed=False,
        )
        session.add(card)
        session.commit()

    try:
        # 1. Save card
        resp_save = client.post(f"/api/cards/{card_id}/save")
        assert resp_save.status_code == 200
        with Session(engine) as session:
            c = session.get(ContextCard, card_id)
            assert c.saved is True
            assert c.dismissed is False

        # Card should appear in /api/saved
        saved_resp = client.get("/api/saved")
        assert saved_resp.status_code == 200
        saved_items = saved_resp.json()
        saved_ids = [item["id"] for item in (saved_items if isinstance(saved_items, list) else saved_items.get("cards", []))]
        assert card_id in saved_ids

        # 2. Dismiss card: must set saved = False, dismissed = True
        resp_dismiss = client.post(f"/api/cards/{card_id}/dismiss")
        assert resp_dismiss.status_code == 200
        with Session(engine) as session:
            c = session.get(ContextCard, card_id)
            assert c.dismissed is True
            assert c.saved is False

        # Card must NOT appear in /api/saved anymore
        saved_resp2 = client.get("/api/saved")
        saved_items2 = saved_resp2.json()
        saved_ids2 = [item["id"] for item in (saved_items2 if isinstance(saved_items2, list) else saved_items2.get("cards", []))]
        assert card_id not in saved_ids2

        # 3. Save again: must clear dismissed
        client.post(f"/api/cards/{card_id}/save")
        with Session(engine) as session:
            c = session.get(ContextCard, card_id)
            assert c.saved is True
            assert c.dismissed is False

        # 4. Clear all saved cards
        clear_resp = client.post("/api/saved/clear")
        assert clear_resp.status_code == 200
        with Session(engine) as session:
            c = session.get(ContextCard, card_id)
            assert c.saved is False
    finally:
        client.delete(f"/api/documents/{doc_id}")


def test_a4_status_and_lifecycle_contract():
    """A4 & A13: GET /api/documents/{id}/status returns checkpoints and lifecycle fields."""
    doc_id = f"test-doc-status-a4-{uuid.uuid4().hex[:8]}"
    with Session(engine) as session:
        doc = Document(
            id=doc_id,
            filename="book.pdf",
            title="Status Check Book",
            status="partially_readable",
            stage="chunking",
            percent=60,
            page_count=20,
            processed_page=16,
            last_checkpoint_page=16,
        )
        session.add(doc)
        session.commit()

    try:
        resp = client.get(f"/api/documents/{doc_id}/status")
        assert resp.status_code == 200
        data = resp.json()
        assert data["document_id"] == doc_id
        assert data["status"] == "partially_readable"
        assert data["page_count"] == 20
        assert data["processed_page"] == 16
        assert data["last_checkpoint_page"] == 16
        assert data["stage_label"] == "Creating reading chunks"
    finally:
        client.delete(f"/api/documents/{doc_id}")


def test_b12_is_llm_configured_handles_ciphertext_and_decryption():
    """B12: is_llm_configured validates decrypability of stored keys."""
    # With no keys configured in env or SQLite
    orig_p = os.environ.get("GEMINI_API_KEY_PRIMARY")
    orig_s = os.environ.get("GEMINI_API_KEY_SECONDARY")
    orig_l = os.environ.get("LLM_API_KEY")

    try:
        os.environ.pop("GEMINI_API_KEY_PRIMARY", None)
        os.environ.pop("GEMINI_API_KEY_SECONDARY", None)
        os.environ.pop("LLM_API_KEY", None)

        with Session(engine) as session:
            # Undecryptable / empty key
            settings = session.get(AISettings, "global")
            if not settings:
                settings = AISettings(id="global", primary_provider="gemini", primary_api_key="enc:v2:corrupted:data")
                session.add(settings)
            else:
                settings.primary_provider = "gemini"
                settings.primary_api_key = "enc:v2:corrupted:data"
                session.add(settings)
            session.commit()

            # Corrupted key must fail closed and return False
            assert is_llm_configured(session) is False

            # Valid plaintext key
            settings.primary_api_key = "AIzaSyTestKey123"
            session.add(settings)
            session.commit()
            assert is_llm_configured(session) is True
    finally:
        if orig_p:
            os.environ["GEMINI_API_KEY_PRIMARY"] = orig_p
        if orig_s:
            os.environ["GEMINI_API_KEY_SECONDARY"] = orig_s
        if orig_l:
            os.environ["LLM_API_KEY"] = orig_l


def test_cancel_and_delete_in_flight_document():
    """B20: Cancel and delete work on queued/processing documents without 409."""
    doc_id = f"test-doc-cancel-b20-{uuid.uuid4().hex[:8]}"
    with Session(engine) as session:
        doc = Document(id=doc_id, filename="book.pdf", title="In Flight Book", status="processing", stage="chunking")
        session.add(doc)
        session.commit()

    try:
        # Cancel endpoint
        resp_cancel = client.post(f"/api/documents/{doc_id}/cancel")
        assert resp_cancel.status_code == 200
        assert resp_cancel.json()["status"] == "failed"
        assert resp_cancel.json()["stage"] == "cancelled"

        # Delete endpoint must succeed without 409
        resp_del = client.delete(f"/api/documents/{doc_id}")
        assert resp_del.status_code == 200
        with Session(engine) as session:
            assert session.get(Document, doc_id) is None
    finally:
        # Ensure cleanup if failed
        with Session(engine) as session:
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
                session.commit()


def test_health_reports_rust_core_and_llm():
    """A14: /api/health returns rust_core availability and llm_configured."""
    resp = client.get("/api/health")
    assert resp.status_code == 200
    data = resp.json()
    assert "status" in data
    assert "database" in data
    assert "llm_configured" in data
    assert "rust_core" in data
    assert "available" in data["rust_core"]
    assert isinstance(data["rust_core"]["available"], bool)


def test_fts5_hybrid_search():
    """A8/A9: Search endpoint uses FTS5 retrieval over document chunks."""
    doc_id = f"test-doc-search-{uuid.uuid4().hex[:8]}"
    with Session(engine) as session:
        doc = Document(id=doc_id, filename="book.pdf", title="Search Test Book", status="ready")
        session.add(doc)
        chunk = ReadingChunk(
            id=f"{doc_id}-c1",
            document_id=doc_id,
            sequence=1,
            section_title="Quantum Section",
            raw_text="The quantum harmonic oscillator exhibits zero-point energy at ground state.",
            start_offset=0,
            end_offset=74,
            checksum="chk-search",
        )
        session.add(chunk)
        session.commit()

    try:
        resp = client.get(f"/api/documents/{doc_id}/search?q=quantum+oscillator")
        assert resp.status_code == 200
        data = resp.json()
        assert data["document_id"] == doc_id
        assert len(data["results"]) >= 1
        assert "quantum harmonic oscillator" in data["results"][0]["raw_text"]
    finally:
        client.delete(f"/api/documents/{doc_id}")


def test_sse_lan_pairing_token_query_param():
    """A5: require_lan_pairing_token supports ?token= query parameter for EventSource."""
    orig_token = os.environ.get("ATHENA_PAIRING_TOKEN")
    try:
        os.environ["ATHENA_PAIRING_TOKEN"] = "secret-pairing-123"
        # Simulate non-loopback with forwarded header
        headers = {"X-Forwarded-For": "192.168.1.100"}

        # Request without token should fail with 401
        resp_unauth = client.get("/api/documents", headers=headers)
        assert resp_unauth.status_code == 401

        # Request with ?token= in query string should succeed
        resp_auth = client.get("/api/documents?token=secret-pairing-123", headers=headers)
        assert resp_auth.status_code == 200
    finally:
        if orig_token:
            os.environ["ATHENA_PAIRING_TOKEN"] = orig_token
        else:
            os.environ.pop("ATHENA_PAIRING_TOKEN", None)

