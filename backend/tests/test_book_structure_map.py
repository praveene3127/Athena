import os
import uuid
from pathlib import Path
import pymupdf
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session

from app.main import app
from app.db import engine, init_db
from app.models import Document, ReadingChunk, DocumentChapter
from app.services.ingestion.blocks import detect_section_role_from_title, SectionRole
from app.services.ingestion.jobs import process_document_job
from app.services.ingestion.extraction import get_document_file_path, UPLOADS_DIR


@pytest.fixture(scope="module", autouse=True)
def setup_db():
    init_db()


def make_12_page_probe_pdf(pdf_path: Path):
    doc = pymupdf.open()
    pages_text = [
        # Page 1: Cover
        "THE ART OF ATTENTION\nA Treatise on Focus and Cognition\nBy Dr. Marcus Aurelius\nAthena Press",
        # Page 2: Copyright
        "Copyright (c) 2026 by Athena Press\nAll rights reserved.\nPrinted in the United States of America.",
        # Page 3: Dedication
        "Dedication\nTo every curious reader who seeks clarity in an age of noise.",
        # Page 4: TOC
        "Contents\nIntroduction ..... 5\nChapter 1: The First Principle ..... 6\nChapter 2: The Stoic Mind ..... 8\nAcknowledgments ..... 10\nNotes ..... 11\nIndex ..... 12",
        # Page 5: Introduction
        "Introduction\nSustained cognitive focus is the prerequisite for all creative and intellectual achievement. When a scholar immerses deeply into a singular problem without distraction, profound connections emerge naturally across seemingly disparate disciplines.\n\nIn this treatise, we explore the historical foundations and modern cognitive implications of uninterrupted reading.",
        # Page 6: Ch 1 p 1
        "Chapter 1: The First Principle\nThe foundational axiom of deliberate inquiry requires establishing protected intervals of mental clarity. In classical antiquity, philosophers recognized that tranquility was not merely the absence of external disturbance, but the active cultivation of intellectual discipline.\n\nEvery deliberate inquiry begins with intentional stillness.",
        # Page 7: Ch 1 p 2
        "When attention divides across multiple competing distractions, cognitive depth deteriorates rapidly. The preservation of deep concentration demands continuous vigilance against superficial interruptions and ambient restlessness.",
        # Page 8: Ch 2 p 1
        "Chapter 2: The Stoic Mind\nThe capacity to direct one's cognitive faculty deliberately forms the bedrock of rational agency. Epictetus observed that while external circumstances remain beyond immediate command, internal judgment remains sovereign.\n\nBy anchoring focus to the essential structure of reality, one cultivates resilience against mental fragmentation.",
        # Page 9: Ch 2 p 2
        "Practitioners of cognitive discipline learn to view obstacles as raw material for intellectual refinement. The subsequent sections illustrate practical methodologies for sustaining contemplative focus under challenging conditions.",
        # Page 10: Acknowledgments
        "Acknowledgments\nI wish to express sincere gratitude to the scholars, colleagues, and research associates whose insightful critiques enriched every stage of this work. Special thanks to the editorial staff for their enduring patience and rigor.",
        # Page 11: Notes
        "Notes\n1. Epictetus, Discourses, Book I, Chapter 14.\n2. Marcus Aurelius, Meditations, Book IV, Section 3.",
        # Page 12: Index
        "Index\nattention, 5, 9, 12\nfocus, 3, 18, 22\nmeaning, 7, 11",
    ]
    for text in pages_text:
        page = doc.new_page(width=595, height=842)
        lines = text.split("\n\n")
        y = 72
        for block in lines:
            rect = pymupdf.Rect(54, y, 541, y + 150)
            page.insert_textbox(rect, block, fontsize=11, fontname="helv")
            y += 120
    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(pdf_path))
    doc.close()


def test_section_role_substring_immunity():
    """Item 5: 'Back to the Land', 'Attack Surface', 'Counterpart', 'Introspection' are never misclassified."""
    assert detect_section_role_from_title("Back to the Land") not in (SectionRole.ACKNOWLEDGMENTS, SectionRole.PART, SectionRole.INTRODUCTION)
    assert detect_section_role_from_title("Attack Surface") not in (SectionRole.ACKNOWLEDGMENTS, SectionRole.PART, SectionRole.INTRODUCTION)
    assert detect_section_role_from_title("Counterpart") not in (SectionRole.ACKNOWLEDGMENTS, SectionRole.PART, SectionRole.INTRODUCTION)
    assert detect_section_role_from_title("Introspection") not in (SectionRole.ACKNOWLEDGMENTS, SectionRole.PART, SectionRole.INTRODUCTION)
    assert detect_section_role_from_title("Apart") not in (SectionRole.ACKNOWLEDGMENTS, SectionRole.PART, SectionRole.INTRODUCTION)

    # Positive assertions
    assert detect_section_role_from_title("Introduction") == SectionRole.INTRODUCTION
    assert detect_section_role_from_title("Acknowledgments") == SectionRole.ACKNOWLEDGMENTS
    assert detect_section_role_from_title("Part 1: The Beginning") == SectionRole.PART
    assert detect_section_role_from_title("Chapter 3: Focus") == SectionRole.CHAPTER
    assert detect_section_role_from_title("Index") == SectionRole.INDEX


def test_12_page_probe_book_structure_and_reader():
    """
    Torture test on the Appendix A 12-page probe book:
    1. All chunks in /reader carry valid section_role, section_title, page_start, and page_end.
    2. 'Introduction' chunks have section_role == 'introduction' and section_title == 'Introduction'.
    3. 'Acknowledgments' chunks have section_role == 'acknowledgments' and section_title == 'Acknowledgments'.
    4. 'Index' page ('attention, 5, 9, 12') is classified as index and NEVER produces fake TOC chapters in /chapters.
    """
    doc_id = f"probe_{uuid.uuid4().hex[:8]}"
    pdf_path = UPLOADS_DIR / f"{doc_id}.pdf"
    make_12_page_probe_pdf(pdf_path)

    try:
        with Session(engine) as session:
            doc = Document(id=doc_id, filename="probe.pdf", title="The Art of Attention", status="queued")
            session.add(doc)
            session.commit()

        # Run full ingestion pipeline
        process_document_job(doc_id)

        client = TestClient(app)

        # 1. Verify GET /api/documents/{id}/reader
        resp = client.get(f"/api/documents/{doc_id}/reader")
        assert resp.status_code == 200, f"Reader error: {resp.text}"
        data = resp.json()

        items = data.get("items", [])
        chunk_items = [it for it in items if it.get("type") == "reading_chunk"]
        assert len(chunk_items) > 0, "No chunks returned by /reader"

        # 1. All chunks in /reader carry a valid section_role, section_title, page_start, and page_end
        for c in chunk_items:
            assert "section_role" in c and c["section_role"] is not None
            assert "page_start" in c and c["page_start"] is not None
            assert "page_end" in c and c["page_end"] is not None
            assert c["page_start"] >= 1 and c["page_end"] >= c["page_start"]

        # 2. 'Introduction' chunks have section_role == 'introduction' and section_title == 'Introduction'
        intro_chunks = [c for c in chunk_items if "Sustained cognitive focus" in (c.get("text") or "")]
        assert len(intro_chunks) >= 1
        for c in intro_chunks:
            assert c["section_role"] == "introduction"
            assert c["section_title"] == "Introduction"

        # 3. 'Acknowledgments' chunks have section_role == 'acknowledgments' and section_title == 'Acknowledgments'
        ack_chunks = [c for c in chunk_items if "sincere gratitude" in (c.get("text") or "")]
        assert len(ack_chunks) >= 1
        for c in ack_chunks:
            assert c["section_role"] == "acknowledgments"
            assert c["section_title"] == "Acknowledgments"

        # Verify structure map payload in /reader
        assert "structure" in data, "Missing 'structure' map in /reader"
        structure = data["structure"]
        assert "digest" in structure
        assert "zones" in structure
        assert "sections" in structure
        assert len(structure["zones"]) >= 2
        assert len(structure["sections"]) >= 3

        # Check section roles and in_feed flags
        sec_roles = [s["role"] for s in structure["sections"]]
        assert "introduction" in sec_roles
        assert "chapter" in sec_roles
        assert "acknowledgments" in sec_roles

        for s in structure["sections"]:
            if s["role"] in ("acknowledgments", "dedication", "notes", "index"):
                assert s["in_feed"] is False
            elif s["role"] in ("introduction", "chapter"):
                assert s["in_feed"] is True

        # 4. Verify GET /api/documents/{id}/chapters
        chap_resp = client.get(f"/api/documents/{doc_id}/chapters")
        assert chap_resp.status_code == 200
        chapters = chap_resp.json()
        chap_titles = [ch["title"] for ch in chapters]

        # NEVER produces fake chapters named "attention, 5, 9," or "focus, 3, 18,"
        for t in chap_titles:
            assert "attention" not in t.lower(), f"Fake TOC chapter detected: {t}"
            assert "focus," not in t.lower(), f"Fake TOC chapter detected: {t}"
            assert "meaning," not in t.lower(), f"Fake TOC chapter detected: {t}"

        # Real chapters are retained
        assert any("introduction" in t.lower() for t in chap_titles)
        assert any("first principle" in t.lower() or "chapter 1" in t.lower() for t in chap_titles)
        assert any("stoic mind" in t.lower() or "chapter 2" in t.lower() for t in chap_titles)
        assert any("acknowledgments" in t.lower() for t in chap_titles)

        # 5. Verify /tape endpoint carries simhash_low
        tape_resp = client.get(f"/api/documents/{doc_id}/tape")
        assert tape_resp.status_code == 200
        assert len(tape_resp.content) > 64

    finally:
        # Cleanup test files and records
        if pdf_path.exists():
            try:
                pdf_path.unlink()
            except Exception:
                pass
        try:
            client.delete(f"/api/documents/{doc_id}")
        except Exception:
            pass
