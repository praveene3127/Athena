from fastapi.testclient import TestClient
from sqlmodel import Session, select
import uuid

from app.main import app
from app.db import engine
from app.models import (
    Concept,
    ConceptCache,
    ContextCard,
    Document,
    DocumentChapter,
    ReadingChunk,
    ReadingState,
)
from app.services.pipeline import ReadAheadPipeline


def _clean_doc(doc_id: str):
    with Session(engine) as session:
        for chunk in session.exec(select(ReadingChunk).where(ReadingChunk.document_id == doc_id)).all():
            session.delete(chunk)
        for chapter in session.exec(select(DocumentChapter).where(DocumentChapter.doc_id == doc_id)).all():
            session.delete(chapter)
        for card in session.exec(select(ContextCard).where(ContextCard.document_id == doc_id)).all():
            session.delete(card)
        for concept in session.exec(select(Concept).where(Concept.document_id == doc_id)).all():
            session.delete(concept)
        state = session.get(ReadingState, doc_id)
        if state:
            session.delete(state)
        doc = session.get(Document, doc_id)
        if doc:
            session.delete(doc)
        session.commit()


def test_score_chunk_density():
    filler = "Hello there. Yes. No. What do you think? I think so too."
    assert ReadAheadPipeline.score_chunk_density(filler) == 0.1

    dense = (
        "In 1945, John von Neumann published the First Draft of a Report on the EDVAC, "
        "describing a stored-program architecture that revolutionized computation across 85% "
        "of modern microprocessors developed by Intel and IBM throughout the subsequent decades. "
        "This structural design unified memory and processor pipelines into an integrated processing unit, "
        "permanently transforming computer engineering standards worldwide."
    )
    score = ReadAheadPipeline.score_chunk_density(dense)
    assert score > 0.3


def test_score_epistemic_curiosity_triggers():
    # 1. Study trigger
    study_chunk = (
        "In 1978, psychologists discovered that lottery winners were not significantly happier "
        "than control group participants in a famous study published by Northwestern University researchers. "
        "The experiments show that hedonic adaptation rapidly returns baseline emotional states to equilibrium, "
        "demonstrating that subjective well-being is relatively stable regardless of fortune."
    )
    study_score = ReadAheadPipeline.score_epistemic_curiosity(study_chunk)
    assert study_score > 0.4

    # 2. Philosophy trigger
    philosophy_chunk = (
        "Suffering is not a bug in human nature; meaning requires an existential confrontation with adversity. "
        "As Stoic philosophers like Epictetus and Seneca argued, our freedom is not determined by external circumstance, "
        "but by our moral relationship to truth and virtue amidst an illusion of control."
    )
    philosophy_score = ReadAheadPipeline.score_epistemic_curiosity(philosophy_chunk)
    assert philosophy_score > 0.35

    # 3. Dialectic trigger
    dialectic_chunk = (
        "Contrary to popular belief, everything you know about personal motivation is fundamentally flawed. "
        "The problem with positive thinking is that in reality, suppressing negative emotions exacerbates psychological distress, "
        "creating a common misconception that happiness is achieved by eliminating pain. Decades of clinical observations "
        "confirm that experiential avoidance paradoxically amplifies suffering across diverse patient populations."
    )
    dialectic_score = ReadAheadPipeline.score_epistemic_curiosity(dialectic_chunk)
    assert dialectic_score > 0.35

    # 4. Rabbit hole trigger
    rabbit_hole_chunk = (
        "In ancient Greece, evolutionary survival pressured early hominids to prioritize tribal cohesion. "
        "As Charles Darwin noted regarding natural selection, behavioral traits favoring reciprocal altruism "
        "outperformed isolated individualism across successive generations of anthropological development. "
        "This captivating backstory illustrates how cognitive adaptations shaped modern civil discourse."
    )
    rabbit_hole_score = ReadAheadPipeline.score_epistemic_curiosity(rabbit_hole_chunk)
    assert rabbit_hole_score > 0.35


def test_progress_sync_and_reading_state():
    client = TestClient(app)
    doc_id = f"test_sync_{uuid.uuid4().hex[:8]}"
    try:
        with Session(engine) as session:
            doc = Document(id=doc_id, filename="test.pdf", title="Test Doc", status="ready")
            session.add(doc)
            session.commit()

        resp = client.post(f"/api/documents/{doc_id}/progress", json={"chunk_index": 12, "reading_mode": "flow"})
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"
        assert resp.json()["prefetched_from"] == 12

        with Session(engine) as session:
            state = session.get(ReadingState, doc_id)
            assert state is not None
            assert state.current_chunk_index == 12
            assert state.reading_mode == "flow"
    finally:
        _clean_doc(doc_id)


def test_document_chapters_endpoint():
    client = TestClient(app)
    doc_id = f"test_chap_{uuid.uuid4().hex[:8]}"
    try:
        with Session(engine) as session:
            doc = Document(id=doc_id, filename="chapters.pdf", title="Chapter Book", status="ready")
            session.add(doc)
            ch1 = DocumentChapter(doc_id=doc_id, level=1, title="Introduction", start_page=0, start_chunk_index=1)
            ch2 = DocumentChapter(doc_id=doc_id, level=1, title="Core Architecture", start_page=12, start_chunk_index=15)
            session.add(ch1)
            session.add(ch2)
            session.commit()

        resp = client.get(f"/api/documents/{doc_id}/chapters")
        assert resp.status_code == 200
        chapters = resp.json()
        assert len(chapters) == 2
        assert chapters[0]["title"] == "Introduction"
        assert chapters[0]["start_chunk_index"] == 1
        assert chapters[1]["title"] == "Core Architecture"
        assert chapters[1]["start_chunk_index"] == 15
    finally:
        _clean_doc(doc_id)


def test_concept_cache_deduplication():
    slug = f"cognitive_dissonance_{uuid.uuid4().hex[:8]}"
    try:
        with Session(engine) as session:
            session.add(
                ConceptCache(
                    concept_slug=slug,
                    title="Cognitive Dissonance",
                    body="A mental discomfort from holding conflicting beliefs.",
                    citations_json='[{"title": "APA Dictionary", "publisher": "apa.org", "url": "https://dictionary.apa.org"}]',
                    source_model="gemini_search",
                )
            )
            session.commit()

            cached = session.get(ConceptCache, slug)
            assert cached is not None
            assert cached.title == "Cognitive Dissonance"
            assert "apa.org" in cached.citations_json
    finally:
        with Session(engine) as session:
            cached = session.get(ConceptCache, slug)
            if cached:
                session.delete(cached)
                session.commit()


def test_export_markdown_endpoint():
    client = TestClient(app)
    doc_id = f"test_exp_{uuid.uuid4().hex[:8]}"
    try:
        with Session(engine) as session:
            doc = Document(id=doc_id, filename="export.pdf", title="Exportable Book", status="ready")
            session.add(doc)
            chunk = ReadingChunk(
                id=f"{doc_id}-c0001",
                document_id=doc_id,
                sequence=1,
                raw_text="The concept of feedback loops determines systemic equilibrium.",
                source_pages_json="[1]",
                start_offset=0,
                end_offset=64,
                checksum="abc",
            )
            session.add(chunk)
            card = ContextCard(
                document_id=doc_id,
                source_chunk_id=chunk.id,
                concept_name="feedback loops",
                title="Context: feedback loops",
                body="Feedback loops are processes where outputs loop back as inputs.",
                why_here="Important principle.",
                exact_quote="The concept of feedback loops determines systemic equilibrium.",
                citations_json='[{"title": "MIT Systems", "publisher": "mit.edu", "url": "https://mit.edu/systems"}]',
                dismissed=False,
            )
            session.add(card)
            session.commit()

        resp = client.get(f"/api/documents/{doc_id}/export-markdown")
        assert resp.status_code == 200
        assert "text/markdown" in resp.headers["content-type"]
        text = resp.text
        assert "# Exportable Book" in text
        assert "feedback loops" in text
        assert "mit.edu" in text
    finally:
        _clean_doc(doc_id)


def test_shadow_quote_matching():
    from app.services.cards import verify_and_anchor_quote, find_exact_quote

    # Passage with pristine curly quotes and em-dash
    passage = "In cognitive psychology, the “mind—body dualism” explains how consciousness operates."

    # Model produces straight quotes and spaces around hyphens
    candidate = 'the "mind - body dualism" explains'
    anchored = verify_and_anchor_quote(passage, candidate)
    assert anchored is not None
    # Ada Lovelace invariant: must be a verbatim substring of passage
    assert anchored in passage
    assert "“mind—body dualism”" in anchored

    # Test find_exact_quote with term containing punctuation
    found = find_exact_quote(passage, "mind-body dualism")
    assert found is not None
    assert found in passage


def test_viewport_epoch_advancement():
    import asyncio
    pipeline = ReadAheadPipeline()
    doc_id = "test_epoch_doc"
    pipeline.chunk_densities[doc_id] = {i: 0.5 for i in range(1, 100)}

    # Initial scroll to chunk 5
    asyncio.run(pipeline.update_viewport(doc_id, 5))
    assert pipeline.viewport_epochs.get(doc_id, 1) == 1

    # Small scroll to chunk 8 (delta 3 <= 16) -> epoch stays 1
    asyncio.run(pipeline.update_viewport(doc_id, 8))
    assert pipeline.viewport_epochs.get(doc_id, 1) == 1

    # Large chapter jump from chunk 8 to chunk 60 (delta 52 > 16) -> epoch increments to 2!
    asyncio.run(pipeline.update_viewport(doc_id, 60))
    assert pipeline.viewport_epochs.get(doc_id) == 2


def test_same_book_concept_suppression():
    pipeline = ReadAheadPipeline()
    unique_id = uuid.uuid4().hex[:8]
    doc_id = f"test_suppress_{unique_id}"
    term = f"thermodynamics_{unique_id}"

    try:
        with Session(engine) as session:
            doc = Document(id=doc_id, filename="book.pdf", title="Suppression Book", status="ready")
            session.add(doc)
            chunk1 = ReadingChunk(
                id=f"{doc_id}-c0001",
                document_id=doc_id,
                sequence=1,
                raw_text=f"The concept of {term} describes irreversible thermodynamic decay.",
                source_pages_json="[1]",
                start_offset=0,
                end_offset=64,
                checksum="chk1",
            )
            chunk5 = ReadingChunk(
                id=f"{doc_id}-c0005",
                document_id=doc_id,
                sequence=5,
                raw_text=f"Later in life, {term} also manifests in software architecture deterioration.",
                source_pages_json="[5]",
                start_offset=65,
                end_offset=140,
                checksum="chk5",
            )
            session.add(chunk1)
            session.add(chunk5)

            # Seed candidate concepts for both chunks
            con1 = Concept(
                id=f"{doc_id}-con1",
                document_id=doc_id,
                chunk_id=chunk1.id,
                name=term,
                importance=0.95,
            )
            con5 = Concept(
                id=f"{doc_id}-con5",
                document_id=doc_id,
                chunk_id=chunk5.id,
                name=term,
                importance=0.95,
            )
            session.add(con1)
            session.add(con5)

            # Cache entry for term
            session.add(
                ConceptCache(
                    concept_slug=term,
                    title=term.capitalize(),
                    body="Thermodynamics is a branch of physics that deals with heat and work.",
                    citations_json='[{"title": "Britannica", "publisher": "britannica.com", "url": "https://britannica.com"}]',
                    source_model="wikipedia",
                )
            )
            session.commit()

        # First card generation on chunk 1 -> generates card
        card1 = pipeline.generate_or_reuse_card(doc_id, 1)
        assert card1 is not None
        assert term in pipeline.doc_grounded_concepts[doc_id]

        # Second card generation on chunk 5 with same concept -> suppressed!
        card5 = pipeline.generate_or_reuse_card(doc_id, 5)
        # Since term is already in pipeline.doc_grounded_concepts[doc_id], it was suppressed!
        assert card5 is None
    finally:
        _clean_doc(doc_id)
        with Session(engine) as session:
            cached = session.get(ConceptCache, term)
            if cached:
                session.delete(cached)
                session.commit()


def test_vibe_check_endpoint_and_fallback():
    from fastapi.testclient import TestClient
    from app.main import app

    client = TestClient(app)
    unique_id = uuid.uuid4().hex[:8]
    doc_id = f"test_vibe_{unique_id}"

    try:
        with Session(engine) as session:
            doc = Document(id=doc_id, filename="dense_book.pdf", title="The Density of Reason", status="ready")
            session.add(doc)
            chunk = ReadingChunk(
                id=f"{doc_id}-c0003",
                document_id=doc_id,
                sequence=3,
                raw_text="Because the epistemological framework demands rigorous empirical falsification, theories must undergo systemic stress tests.",
                source_pages_json="[1]",
                start_offset=0,
                end_offset=128,
                checksum="chk3",
                canonical_sha256="fake_sha",
            )
            session.add(chunk)
            session.commit()

        response = client.post(f"/api/documents/{doc_id}/vibe-check", json={"chunk_index": 3})
        assert response.status_code == 200
        data = response.json()
        assert data["chunk_index"] == 3
        assert "plain_take" in data
        assert data.get("fallback") is True or data["analogy"] is not None
        if data.get("fallback"):
            assert data["analogy"] is None
    finally:
        _clean_doc(doc_id)



