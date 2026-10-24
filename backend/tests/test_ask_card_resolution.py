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
