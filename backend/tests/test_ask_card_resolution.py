from sqlmodel import Session, select
from app.db import engine
from app.models import Document, ReadingChunk, ContextCard, AISettings, utc_now
from app.config import is_llm_configured
from app.routers.ask import AskRequest


def test_is_llm_configured_recognizes_ai_settings():
    with Session(engine) as session:
        saved = session.exec(select(AISettings).where(AISettings.id == "global")).first()
        if not saved:
            saved = AISettings(id="global", primary_provider="gemini", primary_api_key="AIzaSyTestKey12345")
            session.add(saved)
            session.commit()
        else:
            saved.primary_api_key = "AIzaSyTestKey12345"
            session.add(saved)
            session.commit()

    assert is_llm_configured() is True


def test_ask_request_allows_rich_queries():
    req = AskRequest(
        document_id="doc_123",
        chunk_id="chunk_123",
        question="Explain the intellectual context behind this card: " + "a" * 400,
    )
    assert len(req.question) > 300
    assert req.chunk_id == "chunk_123"


def test_ask_locates_chunk_from_context_card_id():
    with Session(engine) as session:
        # Create dummy doc, chunk and card
        doc = Document(
            id="doc_test_ask_card",
            filename="test.pdf",
            title="Test Book",
            status="ready",
            stage="done",
            stage_label="Ready to read",
            page_count=1,
            processed_page=1,
            file_path="test.pdf",
            canonical_text="This is a test paragraph for asking questions.",
            created_at=utc_now(),
            updated_at=utc_now(),
        )
        session.add(doc)
        chunk = ReadingChunk(
            id="chunk_test_ask_1",
            document_id="doc_test_ask_card",
            sequence=1,
            raw_text="This is a test paragraph for asking questions.",
            source_pages_json="[1]",
            start_offset=0,
            end_offset=46,
            checksum="abc",
            boundary_method="paragraph",
            canonical_sha256="sha",
        )
        session.add(chunk)
        card = ContextCard(
            id="card_test_ask_card_1",
            document_id="doc_test_ask_card",
            source_chunk_id="chunk_test_ask_1",
            concept_name="test_concept",
            card_type="context",
            title="Test Concept",
            body="Test Concept Body",
            why_here="Why here",
            citations_json="[]",
            canonical_sha256="sha",
            created_at=utc_now(),
        )
        session.add(card)
        session.commit()

        # Simulate Ask resolution logic
        card_id = "card_test_ask_card_1"
        resolved_chunk = session.get(ReadingChunk, card_id)
        if not resolved_chunk:
            c = session.get(ContextCard, card_id)
            if c:
                resolved_chunk = session.get(ReadingChunk, c.source_chunk_id)

        assert resolved_chunk is not None
        assert resolved_chunk.id == "chunk_test_ask_1"
        assert resolved_chunk.document_id == "doc_test_ask_card"

        # Clean up
        session.delete(card)
        session.delete(chunk)
        session.delete(doc)
        session.commit()


def test_create_and_fetch_saved_user_quote():
    from fastapi.testclient import TestClient
    from app.main import app

    client = TestClient(app)
    doc_id = "doc_quote_test_1"
    note_id = "user_quote_test_999"

    with Session(engine) as session:
        doc = Document(
            id=doc_id,
            filename="quote_doc.pdf",
            title="Marcus Aurelius Meditations",
            status="ready",
            stage="done",
            page_count=1,
            file_path="quote_doc.pdf",
            created_at=utc_now(),
            updated_at=utc_now(),
        )
        chunk = ReadingChunk(
            id=f"{doc_id}-c0001",
            document_id=doc_id,
            sequence=1,
            raw_text="Waste no more time arguing about what a good man should be. Be one.",
            source_pages_json="[1]",
            start_offset=0,
            end_offset=67,
            checksum="chk_quote",
            canonical_sha256="sha_quote",
        )
        session.add(doc)
        session.add(chunk)
        session.commit()

    try:
        # 1. Post user quote to /api/cards/quote
        payload = {
            "id": note_id,
            "document_id": doc_id,
            "source_chunk_id": f"{doc_id}-c0001",
            "title": "Saved Passage · Page 1",
            "body": "Waste no more time arguing about what a good man should be. Be one.",
            "exact_quote": "Waste no more time arguing about what a good man should be. Be one.",
        }
        res = client.post("/api/cards/quote", json=payload)
        assert res.status_code == 200
        assert res.json() == {"id": note_id, "saved": True}

        # 2. Verify quote appears in /api/saved
        saved_res = client.get("/api/saved")
        assert saved_res.status_code == 200
        saved_items = saved_res.json()
        matching = [item for item in saved_items if item["id"] == note_id]
        assert len(matching) == 1
        quote_card = matching[0]
        assert quote_card["card_type"] == "user_highlight"
        assert quote_card["document_title"] == "Marcus Aurelius Meditations"
        assert "Waste no more time" in quote_card["body"]
        assert quote_card["saved"] is True

        # 3. Unsave card
        unsave_res = client.delete(f"/api/cards/{note_id}/save")
        assert unsave_res.status_code == 200
        assert unsave_res.json()["saved"] is False

    finally:
        with Session(engine) as session:
            c = session.get(ContextCard, note_id)
            if c:
                session.delete(c)
            chk = session.get(ReadingChunk, f"{doc_id}-c0001")
            if chk:
                session.delete(chk)
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
            session.commit()

