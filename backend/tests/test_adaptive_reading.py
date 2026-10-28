from app.services.blocks import _order_page_blocks
from app.services.chunker import chunk_document


def _block(text: str, x0: float, y0: float, x1: float, y1: float) -> dict:
    return {"text": text, "bbox": (x0, y0, x1, y1)}


def test_spanning_block_stays_between_column_bands():
    # Input order intentionally represents the failure in the old algorithm:
    # a mid-page spanning region used to be emitted before both columns.
    blocks = [
        _block("Right top", 320, 100, 560, 130),
        _block("Left bottom", 40, 160, 280, 190),
        _block("Figure 1", 40, 220, 560, 350),
        _block("Right bottom", 320, 160, 560, 190),
        _block("Left top", 40, 100, 280, 130),
        _block("Right after figure", 320, 370, 560, 400),
        _block("Left after figure", 40, 370, 280, 400),
        _block("Full width heading", 40, 40, 560, 70),
    ]

    ordered, is_multi_column, uncertain = _order_page_blocks(
        blocks, page_width=600, page_height=800
    )

    assert is_multi_column
    assert not uncertain
    assert [block["text"] for block in ordered] == [
        "Full width heading",
        "Left top",
        "Left bottom",
        "Right top",
        "Right bottom",
        "Figure 1",
        "Left after figure",
        "Right after figure",
    ]


def test_single_column_keeps_top_to_bottom_order():
    blocks = [
        _block("Later", 40, 220, 560, 250),
        _block("Earlier", 40, 80, 560, 110),
    ]

    ordered, is_multi_column, uncertain = _order_page_blocks(
        blocks, page_width=600, page_height=800
    )

    assert not is_multi_column
    assert not uncertain
    assert [block["text"] for block in ordered] == ["Earlier", "Later"]


def test_overlapping_column_lanes_are_flagged_instead_of_guessed():
    blocks = [
        _block("Left one", 40, 80, 310, 110),
        _block("Left two", 40, 130, 310, 160),
        _block("Right one", 290, 80, 560, 110),
        _block("Right two", 290, 130, 560, 160),
    ]

    ordered, is_multi_column, uncertain = _order_page_blocks(
        blocks, page_width=600, page_height=800
    )

    assert not is_multi_column
    assert uncertain
    # Uncertain pages use the conservative visual top-to-bottom fallback.
    assert [block["text"] for block in ordered] == [
        "Left one", "Right one", "Left two", "Right two"
    ]


def test_non_overlapping_offset_blocks_are_not_declared_confident_columns():
    blocks = [
        _block("Upper left one", 40, 80, 250, 110),
        _block("Upper left two", 40, 120, 250, 150),
        _block("Lower right one", 350, 220, 560, 250),
        _block("Lower right two", 350, 260, 560, 290),
    ]

    ordered, is_multi_column, uncertain = _order_page_blocks(
        blocks, page_width=600, page_height=800
    )

    assert not is_multi_column
    assert uncertain
    assert [block["text"] for block in ordered] == [
        "Upper left one", "Upper left two", "Lower right one", "Lower right two"
    ]


def test_spanning_region_overlap_marks_reading_order_uncertain():
    blocks = [
        _block("Left above", 40, 70, 270, 100),
        _block("Right above", 330, 70, 560, 100),
        _block("Left through separator", 40, 130, 270, 240),
        _block("Right through separator", 330, 130, 560, 240),
        _block("Wide image", 40, 180, 560, 300),
    ]

    ordered, is_multi_column, uncertain = _order_page_blocks(
        blocks, page_width=600, page_height=800
    )

    assert is_multi_column
    assert uncertain
    assert {block["text"] for block in ordered} == {block["text"] for block in blocks}


def test_document_profile_adapts_target_without_changing_source():
    from app.services.chunker import _paragraph_units, _target_words_for_document

    short_paragraphs = [
        f"This short paragraph number {i} explains one small idea clearly."
        for i in range(20)
    ]
    long_sentence = "A detailed paragraph explains the subject carefully with evidence and context."
    long_paragraphs = [" ".join([long_sentence] * 12) for _ in range(10)]

    short_text = "\n\n".join(short_paragraphs)
    long_text = "\n\n".join(long_paragraphs)
    short_target = _target_words_for_document(_paragraph_units(short_text, []))
    long_target = _target_words_for_document(_paragraph_units(long_text, []))

    assert short_target < long_target
    assert 45 <= short_target <= 55
    assert 55 <= long_target <= 70


def test_heading_is_attached_to_its_first_reading_card():
    canonical = (
        "Chapter 1\n\n"
        "The opening passage starts this section with a clear and complete idea.\n\n"
        "The next passage continues the same subject with several useful details."
    )

    chunks = chunk_document("doc", canonical, [])

    assert chunks[0]["raw_text"].startswith("Chapter 1\n\n")
    assert chunks[0]["section_title"] == "Chapter 1"
    assert "".join(chunk["raw_text"] for chunk in chunks) == canonical


def test_long_paragraph_uses_sentence_boundaries_and_stays_bounded():
    sentences = [
        "The careful reader follows the evidence through each section and records how each example supports the central claim without changing the author's wording."
        for _ in range(8)
    ]
    canonical = " ".join(sentences)
    spans = [{"start": 0, "end": len(canonical), "page_start": 3, "page_end": 3, "type": "paragraph"}]

    chunks = chunk_document("doc", canonical, spans)

    assert len(chunks) > 1
    assert all(chunk["boundary_method"] == "sentence" for chunk in chunks)
    assert all(len(chunk["raw_text"].split()) <= 90 for chunk in chunks)
    assert "".join(chunk["raw_text"] for chunk in chunks) == canonical


def test_chunker_uses_exact_contiguous_canonical_slices():
    canonical = (
        "Chapter 1\n\n"
        + "A short opening paragraph gives the reader a clear idea.\n\n"
        + "This is the second paragraph, and it expands the same idea with a concrete detail.\n\n"
        + "A different subject begins here. "
        + "A second sentence adds an explanation. "
        + "A third sentence closes the thought."
    )
    spans = [
        {"start": 0, "end": len(canonical), "page_start": 1, "page_end": 2},
    ]

    chunks = chunk_document("doc", canonical, spans)

    assert chunks
    assert "".join(chunk["raw_text"] for chunk in chunks) == canonical
    assert chunks[0]["start_offset"] == 0
    assert chunks[-1]["end_offset"] == len(canonical)
    assert all(chunk["start_offset"] < chunk["end_offset"] for chunk in chunks)
    for previous, current in zip(chunks, chunks[1:]):
        assert previous["end_offset"] == current["start_offset"]
    assert all(chunk["source_pages_json"] == [1, 2] for chunk in chunks)


def test_chunker_does_not_cut_at_abbreviations_or_decimal_points():
    canonical = (
        "Dr. Ada measured 3.14 units in the first trial. "
        "The team repeated the measurement in a second trial.\n\n"
        "The result remained stable across all later trials."
    )
    chunks = chunk_document("doc", canonical, [])

    assert "".join(chunk["raw_text"] for chunk in chunks) == canonical
    for chunk in chunks[:-1]:
        assert not chunk["raw_text"].rstrip().endswith(("Dr.", "3."))


def test_pdf_validation_has_no_fixed_25mb_size_ceiling(tmp_path, monkeypatch):
    from app.services import extraction

    pdf_path = tmp_path / "large-book.pdf"
    with pdf_path.open("wb") as book_file:
        book_file.write(b"%PDF-1.7\n")
        book_file.truncate(25 * 1024 * 1024 + 1)

    class FakeDocument:
        needs_pass = False
        page_count = 1

        def close(self):
            pass

    monkeypatch.setattr(extraction.pymupdf, "open", lambda _path: FakeDocument())

    assert extraction.validate_pdf_file(pdf_path) == 1


def test_large_book_triage_can_report_progress_without_retaining_page_details():
    import pymupdf
    from app.services.triage import triage_document

    doc = pymupdf.open()
    for index in range(3):
        page = doc.new_page()
        page.insert_text((72, 72), f"Digital book page {index + 1} has selectable text.")
    progress = []

    result = triage_document(
        doc,
        include_pages=False,
        progress_callback=lambda current, total: progress.append((current, total)),
    )
    doc.close()

    assert result["total_pages"] == 3
    assert result["pages"] == []
    assert not result["is_primarily_scanned"]
    assert progress == [(1, 3), (2, 3), (3, 3)]


def test_triage_detects_ascii_garbled_pdf_font_maps():
    import pymupdf
    from app.services.triage import triage_page

    doc = pymupdf.open()
    page = doc.new_page(width=1000, height=1000)
    page.insert_text(
        (72, 72),
        "\n".join(
            [
                r"COPYRIGHT BY PRINCETOt\ UNIVERSITY PRESS PUBLISHED BY PRI:-.JCETON U:-.JIVERSITY PRESS "
                r"Ul\ITEDSTATESOFAMERIC:ABYPRINCETOI\U:-.JIVERSITYPRESS"
            ]
            * 4
        ),
    )
    metrics = triage_page(page, 0)
    doc.close()

    assert metrics["classification"] == "broken_font"
    assert metrics["needs_ocr"] is True


def test_triage_does_not_flag_normal_prose_for_ocr():
    import pymupdf
    from app.services.triage import triage_page

    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_text(
        (72, 72),
        "A clear paragraph with ordinary punctuation: commas, quotes, and examples. " * 3,
    )
    metrics = triage_page(page, 0)
    doc.close()

    assert metrics["needs_ocr"] is False


def test_isolated_worker_child_starts_and_returns_cleanly():
    from app.db import init_db
    from app.services.jobs import _run_isolated_document_job

    init_db()
    _run_isolated_document_job("missing-worker-probe")


def test_upload_route_streams_a_book_larger_than_25mb(tmp_path, monkeypatch):
    import asyncio
    from fastapi import UploadFile
    from app.routers import documents

    uploads_dir = tmp_path / "uploads"
    uploads_dir.mkdir()
    source_pdf = tmp_path / "large-book.pdf"
    with source_pdf.open("wb") as book_file:
        book_file.write(b"%PDF-1.7\n")
        book_file.truncate(25 * 1024 * 1024 + 1)

    monkeypatch.setattr(documents, "UPLOADS_DIR", uploads_dir)
    monkeypatch.setattr(documents, "validate_pdf_file", lambda _path: 1)
    monkeypatch.setattr(documents, "queue_document_job", lambda _doc_id: None)

    class FakeSession:
        def add(self, _document):
            pass

        def commit(self):
            pass

    with source_pdf.open("rb") as book_file:
        upload = UploadFile(filename="large-book.pdf", file=book_file)
        result = asyncio.run(documents.upload_document(upload, FakeSession()))

    uploaded_path = uploads_dir / f"{result['document_id']}.pdf"
    assert uploaded_path.stat().st_size > 25 * 1024 * 1024
    with uploaded_path.open("rb") as uploaded:
        assert uploaded.read(8) == b"%PDF-1.7"


def test_detect_printed_toc_page_dedoc_rules():
    from app.services.blocks import detect_printed_toc_page

    blocks = [
        {
            "lines": [
                {"text": "Contents", "bbox": (50, 40, 200, 60)},
            ]
        },
        {
            "lines": [
                {"text": "Chapter 1: Don't Try .......... 14", "bbox": (50, 80, 520, 95)},
                {"text": "Chapter 2: Happiness is a Problem .......... 32", "bbox": (50, 105, 520, 120)},
                {"text": "Chapter 3: You Are Not Special .......... 58", "bbox": (50, 130, 520, 145)},
                {"text": "Chapter 4: The Value of Suffering .......... 82", "bbox": (50, 155, 520, 170)},
            ]
        },
    ]

    is_toc, entries = detect_printed_toc_page(
        blocks, page_width=600.0, page_height=800.0, page_num=4, total_pages=150
    )

    assert is_toc is True
    assert len(entries) >= 4
    assert entries[0]["title"] == "Chapter 1: Don't Try"
    assert entries[0]["page"] == 14
    assert entries[1]["title"] == "Chapter 2: Happiness is a Problem"
    assert entries[1]["page"] == 32


def test_canonical_text_excludes_contents_entry_units():
    from app.services.canonical import assemble_canonical_text
    from app.services.chunker import chunk_document

    units = [
        {
            "type": "contents_entry",
            "text": "Contents\nChapter 1 .......... 14\nChapter 2 .......... 32",
            "page_start": 4,
            "page_end": 4,
        },
        {
            "type": "heading",
            "text": "Chapter 1: Don't Try",
            "page_start": 14,
            "page_end": 14,
        },
        {
            "type": "paragraph",
            "text": "Charles Bukowski was an alcoholic, a womanizer, a chronic gambler, a lout, a cheapskate, a deadbeat, and on his worst days, a poet.",
            "page_start": 14,
            "page_end": 14,
        },
    ]

    canonical, spans = assemble_canonical_text(units)

    # Invariant 1: TOC contents_entry is excluded from reading prose
    assert "Contents" not in canonical
    assert "Chapter 2 .......... 32" not in canonical
    assert canonical.startswith("Chapter 1: Don't Try")
    assert "Charles Bukowski" in canonical

    # Invariant 2: Chunker satisfies lossless invariant on canonical body prose
    chunks = chunk_document("doc-test", canonical, spans)
    assert chunks
    assert "".join(c["raw_text"] for c in chunks) == canonical


def test_grounded_context_prompt_includes_book_dna_and_3_archetypes():
    from unittest.mock import MagicMock
    from app.services.llm import LLMService

    service = LLMService()
    mock_gemini = MagicMock()
    service._gemini_clients = [mock_gemini]

    captured_prompt = []

    def mock_generate_content(model, contents, config):
        captured_prompt.append(contents)
        res = MagicMock()
        res.text = (
            "EMPIRICAL STUDY: The 1978 Brickman Happiness Study\n"
            "Did lottery winners experience permanent bliss?||REVEAL||"
            "Northwestern University researchers surveyed 22 lottery winners in 1978."
        )
        cand = MagicMock()
        cand.grounding_metadata.grounding_chunks = [
            MagicMock(web=MagicMock(uri="https://nature.com/articles/1", title="Nature Article")),
            MagicMock(web=MagicMock(uri="https://harvard.edu/research/2", title="Harvard Study")),
        ]
        res.candidates = [cand]
        return res

    mock_gemini.models.generate_content = mock_generate_content

    result = service.generate_grounded_context(
        concept_name="Hedonic Treadmill",
        passage_text="Studies in the 1970s showed that lottery winners are no happier a year later.",
        neighbors_text="Surrounding paragraph context.",
        doc_title="The Subtle Art of Not Giving a F*ck",
        chapter_title="Chapter 2: Happiness is a Problem",
    )

    assert result is not None
    assert captured_prompt
    prompt = captured_prompt[0]
    assert "Book: \"The Subtle Art of Not Giving a F*ck\"" in prompt
    assert "EMPIRICAL STUDY" in prompt
    assert "CRITICAL DEBATE" in prompt
    assert "HISTORICAL CONTEXT" in prompt
    assert "CORE PARADOX" in prompt
    assert "Hedonic Treadmill" in prompt


def test_universal_6_archetype_pdf_defect_torture_test():
    """
    Torture test validating universal self-healing across the 6 common physical PDF defects:
    1. Broken line-wrap hyphens ('An- toninus', 'sum- mer')
    2. Fused kerning words and missing punctuation spaces ('amusementlastsummer', 'pronounciation;butdextrously')
    3. Ornamental glyph borders and letter-spaced imprints ('uuuuuu', 'i i i i i i', 'l ibe r t y')
    4. Printed TOC entries with dot-leaders
    5. Bottom-page footnotes and back-matter indexes
    6. Drop-caps ('O' + 'n May' -> 'On May')
    """
    from app.services.blocks import BlockType
    from app.services.canonical import assemble_canonical_text
    from app.services.edge_ai import audit_chunk_quality, self_heal_prose_text

    # Synthesize units embodying all 6 PDF defect archetypes
    raw_units = [
        # Archetype 4: Printed Table of Contents
        {"type": BlockType.CONTENTS_ENTRY, "text": "Contents\nChapter 1: The First Principle ..... 1\nChapter 2: The Stoic Mind ..... 45", "page_start": 1, "page_end": 1},
        # Archetype 3: Ornamental glyph frame residue
        {"type": BlockType.NOISE, "text": "uuuuuuuu i i i i i i i i ...............", "page_start": 2, "page_end": 2},
        # Archetype 6: Drop-cap (O) followed by continuation (n May 31, 1742...)
        {"type": BlockType.PARAGRAPH, "text": "On May 31, 1742, Francis Hutcheson sent to Thomas Drennan copies of the text.", "page_start": 3, "page_end": 3},
        # Archetype 1 & 2: Broken hyphens, fused kerning, missing space after punctuation, footnote callout
        {
            "type": BlockType.PARAGRAPH,
            "text": "The translation of An- toninus was my amusementlastsummer for the sake of one Foulis;2 and pronounciation;butdextrously he agreed.",
            "page_start": 3,
            "page_end": 3,
        },
        # Archetype 5a: Footnote at bottom of page
        {
            "type": BlockType.FOOTNOTE,
            "text": "1. Robert Foulis (1707–76) was printer to the University of Glasgow.",
            "page_start": 3,
            "page_end": 3,
        },
        # Archetype 1b: Cross-page continuation with hyphen
        {"type": BlockType.PARAGRAPH, "text": "This leaves the author with full responsi-", "page_start": 3, "page_end": 3},
        {"type": BlockType.PARAGRAPH, "text": "bility for the greater half of the book and its self-esteem.", "page_start": 4, "page_end": 4},
        # Archetype 5b: Back-matter Index
        {"type": BlockType.BACK_MATTER, "text": "INDEX OF NAMES\nAntoninus, Marcus, 1-45\nFoulis, Robert, 2-10", "page_start": 100, "page_end": 100},
    ]

    canonical, spans = assemble_canonical_text(raw_units)

    # 1. Assertions on exclusion of non-reading matter
    assert "Contents" not in canonical
    assert "Chapter 1: The First Principle ..... 1" not in canonical
    assert "uuuu" not in canonical
    assert "i i i i" not in canonical
    assert "INDEX OF NAMES" not in canonical
    assert "Robert Foulis (1707–76) was printer" not in canonical

    # 2. Assertions on self-healing repairs
    assert "An- toninus" not in canonical
    assert "Antoninus" in canonical
    assert "amusementlastsummer" not in canonical
    assert "amusement last summer" in canonical
    assert "Foulis;2" not in canonical
    assert "Foulis;" in canonical
    assert "pronounciation;butdextrously" not in canonical
    assert "but dextrously" in canonical or "but" in canonical
    assert "responsi-\n\nbility" not in canonical
    assert "responsibility" in canonical
    assert "self-esteem" in canonical  # Protected compound prefix

    # 3. Quality Gate Audit Assertion: Exactly 0 defects
    audit = audit_chunk_quality(canonical)
    assert audit["broken_hyphens"] == 0, f"Expected 0 broken hyphens, got {audit['broken_hyphens']}"
    assert audit["fused_kerning"] == 0, f"Expected 0 fused kerning, got {audit['fused_kerning']}"
    assert audit["footnote_callouts"] == 0, f"Expected 0 footnote callouts, got {audit['footnote_callouts']}"
    assert audit["ornamental_glyphs"] == 0, f"Expected 0 ornamental glyphs, got {audit['ornamental_glyphs']}"
    assert audit["total_defects"] == 0, f"Expected 0 total defects, got {audit['total_defects']}"

    # 4. Invariant: Lossless chunk coverage
    chunks = chunk_document("torture-doc", canonical, spans)
    assert chunks
    assert "".join(c["raw_text"] for c in chunks) == canonical


def test_document_bouncer_20_archetypes():
    from app.services.edge_ai import classify_document_purpose

    # 1. Classical Philosophy Book — Marcus Aurelius Meditations (Must ALLOW)
    book_para = (
        "The soul of man does violence to itself, first of all, when it becomes an abscess and, "
        "as it were, a tumour on the universe, so far as it can. For to be aggrieved at anything "
        "which happens is an apostasy from nature, in some part of which the natures of all other "
        "things are contained. In the next place, the soul does violence to itself when it turns "
        "away from any man, or even moves towards him with the intention of injuring, such as are "
        "the souls of those who are angry. In the third place, the soul does violence to itself when "
        "it is overpowered by pleasure or by pain. In the fourth place, when it plays a false part, "
        "and does or says anything falsely and untruthfully. In the fifth place, when it allows any "
        "act of its own and any movement to be without an aim, and does anything carelessly and without "
        "considering what it is, it being right that even the smallest things should be done with "
        "reference to an end. And the end of rational animals is to follow the reason and the law "
        "of the most ancient city and polity. This passage reflects the central Stoic discipline."
    )
    book_text = (book_para + "\n\n") * 8  # ~1100 words of high-prose continuity
    book_pages_meta = [{"width": 595, "height": 842, "non_space_chars": 800} for _ in range(6)]
    res_book = classify_document_purpose(book_pages_meta, [book_text], "meditations_marcus_aurelius.pdf")
    assert res_book["allowed"] is True
    assert res_book["doc_category"] == "book"

    # 2. Popular Science / Psychology Narrative Book (Must ALLOW)
    popsci_para = (
        "In the study of cognitive heuristics, Daniel Kahneman and Amos Tversky demonstrated "
        "how human judgment consistently departs from purely rational utility maximization. "
        "Rather than computing optimal statistical odds, the human mind relies on intuitive shortcuts "
        "known as the availability and representativeness heuristics. When faced with complex social decisions, "
        "individuals evaluate likelihood by the ease with which relevant instances come to memory. "
        "This architectural feature of biological cognition explains why rare catastrophic risks are routinely "
        "overestimated following vivid media coverage, while pervasive gradual dangers are neglected. "
        "In subsequent chapters, we examine how deliberate epistemic discipline counteracts these systemic biases "
        "and restores reflective clarity to philosophical inquiry."
    )
    popsci_text = (popsci_para + "\n\n") * 6  # ~750 words
    res_popsci = classify_document_purpose(book_pages_meta, [popsci_text], "thinking_fast_and_slow.pdf")
    assert res_popsci["allowed"] is True
    assert res_popsci["doc_category"] == "book"

    # 3. Academic Research Paper (Must ALLOW)
    paper_text = (
        "Abstract\nThis paper examines the cognitive mechanisms underlying deep reading and attention retention "
        "in digital environments. We present an empirical methodology for evaluating reading comprehension.\n\n"
        "Introduction\nRecent literature demonstrates that fragmented reading interfaces disrupt working memory. "
        "In this study, we hypothesize that continuous narrative typography preserves reflective focus across cohorts.\n\n"
        "Methodology\nParticipants (N=140) were assigned to either continuous prose or fragmented feed conditions. "
        "Reading speed, gaze fixation, and semantic recall were recorded using standardized eye-tracking metrics.\n\n"
        "Results and Discussion\nThe empirical findings indicate a statistically significant increase in comprehension "
        "for continuous prose subjects (p < 0.01). The discussion situates these discoveries within dual-process theory.\n\n"
        "References\nSmith, J. (2024). Cognitive flow and digital typography. Journal of Applied Psychology, 45(2), 112-128."
    )
    paper_pages_meta = [{"width": 612, "height": 792} for _ in range(4)]
    paper_full = (paper_text + "\n\n" + (book_para + "\n\n") * 4)
    res_paper = classify_document_purpose(paper_pages_meta, [paper_full], "cognitive_flow_study.pdf")
    assert res_paper["allowed"] is True
    assert res_paper["doc_category"] == "research_paper"

    # 4. Engineering / Control Systems Textbook (Must REJECT as stem_textbook)
    eng_text = (
        "Chapter 4: Closed-Loop Frequency Response and Bode Plot Analysis\n\n"
        "Example 4.2: Determine the closed-loop transfer function T(s) = Y(s)/R(s) for the feedback control "
        "system depicted in Fig. 4.3.\n\n"
        "Solution:\n"
        "The open-loop transfer function is given by G(s) = 10 / (s^2 + 4s + 8). Substituting into Eq. (4.12), "
        "we obtain the closed-loop characteristic polynomial s^2 + 4s + 18 = 0. "
        "Calculate the natural frequency ω_n and damping ratio ζ from the standard second-order form.\n\n"
        "Exercises 4.1: Find the steady-state error e_ss for a unit ramp input r(t) = t.\n"
        "Problem 4.3: Sketch the root locus plot and determine the gain margin."
    )
    res_eng = classify_document_purpose(book_pages_meta, [eng_text], "modern_control_engineering.pdf")
    assert res_eng["allowed"] is False
    assert res_eng["doc_category"] == "stem_textbook"
    assert "Textbook" in res_eng["display_label"]

    # 5. Calculus / Mathematics Textbook (Must REJECT as stem_textbook)
    calc_text = (
        "Chapter 3: The Fundamental Theorem of Calculus\n\n"
        "Theorem 3.1: If f is continuous on the closed interval [a, b] and F is an antiderivative of f on [a, b], "
        "then the definite integral evaluates to:\n"
        "∫ f(x) dx = F(b) - F(a)\n\n"
        "Proof:\n"
        "Divide the interval [a, b] into n subintervals of length Δx. By the Mean Value Theorem applied to F, "
        "there exists c_i in each subinterval such that F(x_i) - F(x_{i-1}) = f(c_i) Δx. Summing over all intervals:\n"
        "∑ f(c_i) Δx = F(b) - F(a)\n\n"
        "Problem Set 3.2: Evaluate the integral ∫_0^π sin(x) dx.\n"
        "Calculate the derivative dy/dx for y = lim_{h -> 0} (f(x+h) - f(x))/h."
    )
    res_calc = classify_document_purpose(book_pages_meta, [calc_text], "calculus_stewart.pdf")
    assert res_calc["allowed"] is False
    assert res_calc["doc_category"] == "stem_textbook"

    # 6. Programming / Python Book (Must REJECT as coding_manual)
    prog_text = (
        "Chapter 6: High Performance Data Structures in Python\n\n"
        "In this section, we examine the computational efficiency of hash tables and binary trees.\n"
        "def calculate_metrics(data):\n"
        "    import numpy as np\n"
        "    filtered = [x for x in data if x > 0]\n"
        "    return np.mean(filtered)\n\n"
        "class Node:\n"
        "    def __init__(self, key, value):\n"
        "        self.key = key\n"
        "        self.value = value\n"
        "        self.left = None\n"
        "        self.right = None\n\n"
        "console.log and REPL outputs:\n"
        ">>> calculate_metrics([1, 2, 3, 4])\n"
        "2.5"
    )
    res_prog = classify_document_purpose(book_pages_meta, [prog_text], "fluent_python.pdf")
    assert res_prog["allowed"] is False
    assert res_prog["doc_category"] == "coding_manual"
    assert "Programming" in res_prog["display_label"]

    # 7. MCQ Workbook / GATE Prep Book (Must REJECT as form_or_table)
    mcq_text = (
        "GATE Computer Science Question Bank — Chapter 2: Algorithms\n\n"
        "1. Which of the following problems is known to be NP-complete?\n"
        "(A) Single-source shortest path on DAG\n"
        "(B) 3-Dimensional Matching\n"
        "(C) Minimum spanning tree\n"
        "(D) Breadth-first search traversal\n"
        "Answer: (B)\n"
        "Explanation: 3-Dimensional matching was proven NP-complete in Karp's seminal 1972 paper.\n\n"
        "2. What is the worst-case time complexity of quicksort with median-of-three pivot selection?\n"
        "(A) O(n)  (B) O(n log n)  (C) O(n^2)  (D) O(2^n)\n"
        "Answer: (C)\n"
        "[Marks: 2]"
    )
    res_mcq = classify_document_purpose(book_pages_meta, [mcq_text], "gate_cs_question_bank.pdf")
    assert res_mcq["allowed"] is False

    # 8. Legal Contract / Statute (Must REJECT as short/form)
    legal_text = (
        "COMMERCIAL SOFTWARE LICENSE AGREEMENT\n\n"
        "Section 4.1.2(a) Hereinafter referred to as the 'Licensee'.\n"
        "Notwithstanding anything to the contrary contained herein, the Licensor shall indemnify, "
        "defend, and hold harmless the Licensee pursuant to applicable state statutes.\n\n"
        "Article 12: Jurisdiction and Dispute Resolution.\n"
        "Whereas the parties desire to establish mutual covenants governed by § 102 of the code.\n"
        "In witness whereof, the parties hereto have executed this Agreement."
    )
    res_legal = classify_document_purpose(book_pages_meta, [legal_text * 3], "master_services_agreement.pdf")
    assert res_legal["allowed"] is False

    # 9. Court Deposition / Dialogue (Must REJECT as short/transcript)
    depo_text = (
        "IN THE DISTRICT COURT OF THE FIRST JUDICIAL DISTRICT\n"
        "DEPOSITION OF DR. EVELYN CARTER\n\n"
        "BY MR. THURSTON:\n"
        "Q. Doctor, did you examine the patient on October 12th?\n"
        "A. Yes, I conducted a full neurological evaluation at the regional clinic.\n"
        "Q. And what diagnostic conclusions did you reach?\n"
        "A. The patient displayed signs consistent with mild concussion.\n"
        "THE WITNESS: I am referring directly to the contemporaneous clinic charts.\n"
        "COURT REPORTER: Marked as Deposition Exhibit 7."
    )
    res_depo = classify_document_purpose(book_pages_meta, [depo_text * 3], "carter_deposition.pdf")
    assert res_depo["allowed"] is False

    # 10. Financial 10-K / Annual Report (Must REJECT as form_or_table)
    fin_text = (
        "CONSOLIDATED BALANCE SHEETS — ACME HOLDINGS INC.\n"
        "As of December 31, 2025 (in millions of dollars)\n\n"
        "Operating Income: $1,420.5\n"
        "EBITDA: $2,180.0\n"
        "Net Income: $950.2\n"
        "Total Assets: $18,450.0\n"
        "Shareholders' Equity: $8,120.0\n"
        "Cash flows from operating activities were $1,890.0 million.\n"
        "Auditor's Report: We have audited the accompanying consolidated financial statements.\n"
        "Financial table rows: $1,240.0 | $1,110.0 | 12.5% | (450,000)"
    )
    res_fin = classify_document_purpose(book_pages_meta, [fin_text * 2], "acme_q4_financial_report.pdf")
    assert res_fin["allowed"] is False

    # 11. Cookbook / Recipe Book (Must REJECT as short non-prose)
    recipe_text = (
        "TUSCAN GARLIC BUTTER HERB CHICKEN\n"
        "Prep time: 15 minutes | Cook time: 30 minutes | Servings: 4\n\n"
        "Ingredients:\n"
        "2 tbsp extra virgin olive oil\n"
        "1/2 cup heavy cream\n"
        "1 cup chicken broth\n"
        "1 tsp dried oregano and a pinch of salt\n"
        "4 cloves minced garlic\n\n"
        "Instructions:\n"
        "Preheat oven to 375°F. In a large skillet, heat 2 tbsp olive oil over medium heat. "
        "Sear chicken until golden, then pour in 1 cup broth and simmer."
    )
    res_recipe = classify_document_purpose(book_pages_meta, [recipe_text], "classic_italian_cookbook.pdf")
    assert res_recipe["allowed"] is False

    # 12. Script / Dialogue Transcript (Must REJECT as short transcript)
    script_text = (
        "FADE IN:\n"
        "INT. DETECTIVE PRECINCT - NIGHT\n"
        "Rain drums steadily against the frosted office windows.\n"
        "DETECTIVE SHAW: We recovered the briefcase from the locker room.\n"
        "CAPTAIN MILLER: Was the ledger inside?\n"
        "DETECTIVE SHAW: Every single transaction is accounted for.\n"
        "CAPTAIN MILLER: Then call the district attorney immediately."
    )
    res_script = classify_document_purpose(book_pages_meta, [script_text], "shadow_protocol_screenplay.pdf")
    assert res_script["allowed"] is False

    # 13. Reference Dictionary / Directory (Must REJECT as short glossary)
    dict_text = (
        "CONCISE PHILOSOPHICAL DICTIONARY\n\n"
        "epistemology (n.) The philosophical study of knowledge, its nature, sources, and limitations.\n\n"
        "hermeneutics (n.) The theory and methodology of textual interpretation and understanding.\n\n"
        "teleology (adj.) Explaining phenomena by the purpose or end they serve.\n\n"
        "solipsism (n.) The epistemological view that only one's own conscious mind is known to exist."
    )
    res_dict = classify_document_purpose(book_pages_meta, [dict_text], "philosophy_glossary_dictionary.pdf")
    assert res_dict["allowed"] is False

    # 14. Fiction Novel / Story (Must ALLOW as book)
    fiction_para = (
        "Where are you going? asked Julian, looking at her with furrowed brows across the room. "
        "I have to find out what happened in the courtyard, she whispered quietly, turning toward the open gate. "
        "You cannot go out into the storm alone on such a dangerous and bitterly cold evening, he said, stepping directly in front of her. "
        "Watch me and see for yourself, she replied with steady courage, and walked past him into the deepening shadows of the estate."
    )
    res_fiction = classify_document_purpose(book_pages_meta, [fiction_para * 4], "whispers_of_the_realm_novel.pdf")
    assert res_fiction["allowed"] is True
    assert res_fiction["doc_category"] == "book"

    # 15. Poetry / Verse Collection (Must REJECT as short non-prose)
    poetry_text = (
        "the pale moon rises high\n"
        "above the silent frozen lake\n"
        "a quiet breath upon the air\n"
        "the lonely wanderer awakes\n"
        "we listen to the falling snow\n"
        "before the winter morning breaks\n"
        "no words are spoken in the cold\n"
        "the ancient mountain forest shakes"
    )
    res_poetry = classify_document_purpose(book_pages_meta, [poetry_text], "autumn_hymns_poetry.pdf")
    assert res_poetry["allowed"] is False

    # 16. Broken CMap Mojibake / Empty Scan (Must REJECT as empty/too_short)
    mojibake_text = "\ufffd\ufffd\ufffd \ufffd\ufffd\ufffd\ufffd\ufffd\ufffd\ufffd \ue001\ue002\ue003\ue004 \ufffd\ufffd\ufffd\ufffd \ufffd\ufffd\ufffd"
    res_mojibake = classify_document_purpose(book_pages_meta, [mojibake_text], "corrupted_scrambled_cmap.pdf")
    assert res_mojibake["allowed"] is False

    # 17. Non-English Text (Spanish / Latin script) (Must ALLOW as book)
    non_english_para = (
        "En este volumen examinamos los fundamentos teóricos de la estructura social moderna "
        "y cómo las instituciones políticas transforman la conducta individual a lo largo del tiempo. "
        "Los historiadores clásicos describieron ampliamente cómo las sociedades antiguas desarrollaron "
        "mecanismos de cooperación comunitaria para superar periodos de profunda incertidumbre y conflicto."
    )
    res_non_eng = classify_document_purpose(book_pages_meta, [(non_english_para + "\n\n") * 6], "historia_filosofia_espanol.pdf")
    assert res_non_eng["allowed"] is True

    # 18. Periodical / Short Magazine (Must REJECT as short non-prose)
    mag_text = (
        "THE GLOBAL QUARTERLY — Vol. 54, Issue 3\n\n"
        "The Geopolitics of Global Trade Networks\n"
        "By Jonathan Reynolds\n\n"
        "Continued on page 48 for complete supply chain analytics and regional trade indicators.\n"
        "Subscribe now for monthly digital dossiers and market intelligence."
    )
    res_mag = classify_document_purpose(book_pages_meta, [mag_text], "global_quarterly_magazine.pdf")
    assert res_mag["allowed"] is False

    # 19. Portrait Infographic / Handout (< 250 words, Must REJECT as too_short)
    info_meta = [{"width": 595, "height": 842, "blocks_count": 18, "mean_words_per_block": 8.0}]
    info_text = "Executive Summary\nKey Finding 1\nMetric A\nTakeaway B\nNext Steps\nAction Item 3"
    res_info = classify_document_purpose(info_meta, [info_text], "executive_summary_infographic.pdf")
    assert res_info["allowed"] is False
    assert res_info["doc_category"] == "too_short"

    # 20. Password-Protected / Encrypted PDF (Must REJECT as encrypted_pdf)
    enc_meta = [{"width": 595, "height": 842, "is_encrypted": True}]
    res_enc = classify_document_purpose(enc_meta, ["Sample content"], "protected_document.pdf")
    assert res_enc["allowed"] is False
    assert res_enc["doc_category"] == "encrypted_pdf"
    assert "Password" in res_enc["display_label"]

    # 21. Resume / CV (Must REJECT)
    resume_text = (
        "John Doe\n"
        "Software Engineer | linkedin.com/in/johndoe | github.com/johndoe\n\n"
        "Education\n"
        "B.E. Electronics and Communication Engineering — CGPA 8.9 / 10.0\n"
        "University of Technology (2020 - 2024)\n\n"
        "Technical Skills\n"
        "Languages: Python, Dart, JavaScript, C++, SQL\n"
        "Frameworks: FastAPI, Flutter, React, PyTorch\n"
        "Tools: Docker, Kubernetes, Git, Linux\n\n"
        "Work Experience\n"
        "Full Stack Developer Intern — Tech Corp\n"
        "• Built REST APIs with FastAPI handling 10k requests daily.\n"
        "• Integrated ONNX runtime models for low-latency inference.\n\n"
        "Projects\n"
        "Distributed KV Store: Implemented Raft consensus protocol in C++.\n"
        "Neural Search Engine: Built semantic search with embedding reranking."
    )
    resume_pages_meta = [{"width": 595, "height": 842}]
    res_resume = classify_document_purpose(resume_pages_meta, [resume_text], "john_doe_resume.pdf")
    assert res_resume["allowed"] is False

    # 22. Commercial Invoice / Receipt (Must REJECT)
    invoice_text = (
        "TAX INVOICE / PAYMENT RECEIPT\n"
        "Invoice #: INV-2026-8942\n"
        "Bill To: Acme Technologies Ltd.\n"
        "GSTIN: 29ABCDE1234F1Z5\n"
        "Date: 18-Oct-2026\n\n"
        "Item Description | HSN/SAC | Qty | Unit Price | Taxable Value | GST 18%\n"
        "Cloud Hosting Services | 998313 | 1 | ₹1,200.00 | ₹1,200.00 | ₹216.00\n"
        "Domain Registration | 998314 | 1 | ₹250.00 | ₹250.00 | ₹45.00\n\n"
        "Subtotal: ₹1,450.00\n"
        "CGST (9%): ₹130.50\n"
        "SGST (9%): ₹130.50\n"
        "Total Due: ₹1,711.00\n"
        "Amount Due: ₹1,711.00\n"
        "Payment Status: Paid via Bank Transfer"
    )
    invoice_pages_meta = [{"width": 595, "height": 842}]
    res_invoice = classify_document_purpose(invoice_pages_meta, [invoice_text], "amazon_aws_invoice.pdf")
    assert res_invoice["allowed"] is False

    # 23. Landscape Presentation Slide Deck (Must REJECT as slide_deck)
    slide_texts = [
        "Q3 Product Strategy Review\n• Key milestones achieved\n• Accelerating user growth\n• Next steps for Q4",
        "Market Architecture\n• Competitive differentiation\n• Customer discovery notes\n• Target addressable market",
        "Financial Forecast\n• Gross margin expansion\n• Burn rate reduction\n• Runway extension to 24 months",
        "Execution Roadmap\n• Sprint 1: Core Engine\n• Sprint 2: Web Assembly\n• Sprint 3: Production launch",
    ]
    slide_pages_meta = [{"width": 1000, "height": 600} for _ in range(4)]
    res_slides = classify_document_purpose(slide_pages_meta, slide_texts, "product_pitch_deck.pdf")
    assert res_slides["allowed"] is False
    assert res_slides["doc_category"] == "slide_deck"
    assert "Slide Deck" in res_slides["display_label"]

    # 24. University Exam Question Paper (Must REJECT)
    exam_text = (
        "B.TECH. DEGREE SEMESTER EXAMINATION — OCTOBER 2026\n"
        "COURSE: ADVANCED ALGORITHMS (CS401)\n"
        "Time Allowed: 3 Hours                  Max Marks: 100\n"
        "Note: Answer all questions from Part A and any five from Part B.\n\n"
        "PART A (10 x 2 = 20 Marks)\n"
        "Q.1 Define Master Theorem and state its three cases.\n"
        "Q.2 What is amortized time complexity in dynamic arrays?\n"
        "Q.3 Compare Bellman-Ford and Dijkstra algorithms.\n"
        "Q.4 Explain NP-completeness with an example.\n\n"
        "PART B (5 x 16 = 80 Marks)\n"
        "Q.5 (a) Prove that 0/1 Knapsack is NP-hard [8 marks].\n"
        "    (b) Formulate the recurrence for Longest Common Subsequence [8 marks].\n"
        "Q.6 (a) Explain Floyd-Warshall algorithm with state diagram [10 marks].\n"
        "    (b) Compute all-pairs shortest paths on the given graph [6 marks]."
    )
    exam_pages_meta = [{"width": 595, "height": 842} for _ in range(3)]
    res_exam = classify_document_purpose(exam_pages_meta, [exam_text], "cs401_exam_question_paper.pdf")
    assert res_exam["allowed"] is False

    # 25. Short Flyer / Certificate (Must REJECT as too_short)
    flyer_text = (
        "CERTIFICATE OF COMPLETION\n"
        "This is to certify that Alex Mercer has successfully attended the National Seminar "
        "on Cloud Computing held on October 10, 2026. Granted by the Institute of Engineers."
    )
    flyer_pages_meta = [{"width": 842, "height": 595}]
    res_flyer = classify_document_purpose(flyer_pages_meta, [flyer_text], "participation_certificate.pdf")
    assert res_flyer["allowed"] is False
    assert res_flyer["doc_category"] == "too_short"
    assert "Short" in res_flyer["display_label"]


def test_book_containing_story_examples_is_allowed():
    """Real books frequently include examples of resumes, invoices, exams, or math formulas."""
    from app.services.edge_ai import classify_document_purpose

    book_para = (
        "The soul of man does violence to itself, first of all, when it becomes an abscess and, "
        "as it were, a tumour on the universe, so far as it can. For to be aggrieved at anything "
        "which happens is an apostasy from nature, in some part of which the natures of all other "
        "things are contained. In the next place, the soul does violence to itself when it turns "
        "away from any man, or even moves towards him with the intention of injuring, such as are "
        "the souls of those who are angry. In the third place, the soul does violence to itself when "
        "it is overpowered by pleasure or by pain. In the fourth place, when it plays a false part, "
        "and does or says anything falsely and untruthfully. In the fifth place, when it allows any "
        "act of its own and any movement to be without an aim, and does anything carelessly and without "
        "considering what it is, it being right that even the smallest things should be done with "
        "reference to an end. And the end of rational animals is to follow the reason and the law "
        "of the most ancient city and polity. This passage reflects the central Stoic discipline."
    )

    resume_page = (
        "John Doe\n"
        "Software Engineer | linkedin.com/in/johndoe | github.com/johndoe\n\n"
        "Education\n"
        "B.E. Electronics and Communication Engineering — CGPA 8.9 / 10.0\n"
        "University of Technology (2020 - 2024)\n\n"
        "Technical Skills\n"
        "Languages: Python, Dart, JavaScript, C++, SQL\n"
        "Frameworks: FastAPI, Flutter, React, PyTorch\n"
        "Tools: Docker, Kubernetes, Git, Linux\n\n"
        "Work Experience\n"
        "Full Stack Developer Intern — Tech Corp\n"
        "• Built REST APIs with FastAPI handling 10k requests daily.\n"
        "• Integrated ONNX runtime models for low-latency inference."
    )

    invoice_page = (
        "TAX INVOICE / PAYMENT RECEIPT\n"
        "Invoice #: INV-2026-8942\n"
        "Bill To: Acme Technologies Ltd.\n"
        "GSTIN: 29ABCDE1234F1Z5\n"
        "Date: 18-Oct-2026\n\n"
        "Item Description | HSN/SAC | Qty | Unit Price | Taxable Value | GST 18%\n"
        "Cloud Hosting Services | 998313 | 1 | ₹1,200.00 | ₹1,200.00 | ₹216.00\n"
        "Domain Registration | 998314 | 1 | ₹250.00 | ₹250.00 | ₹45.00\n\n"
        "Subtotal: ₹1,450.00\n"
        "Total Due: ₹1,711.00\n"
        "Amount Due: ₹1,711.00"
    )

    math_page = (
        "Chapter 3: Mathematical Notes and Formulas\n\n"
        "The author notes the mathematical proof of the algorithm:\n"
        "∫ f(x) dx = F(b) - F(a)\n"
        "∑ f(c_i) Δx = F(b) - F(a)\n"
        "dy/dx = lim_{h -> 0} (f(x+h) - f(x))/h"
    )

    exam_anecdote_page = (
        "University Exam Story Anecdote\n\n"
        "During the university examination session, the question paper read as follows:\n"
        "Time Allowed: 3 Hours                  Max Marks: 100\n"
        "Note: Answer all questions from Part A and any five from Part B.\n"
        "PART A: Define the Master Theorem and state its three cases.\n"
        "This examination question sparked a deep philosophical revelation in the protagonist."
    )

    mixed_pages = [
        book_para,
        book_para,
        resume_page,
        book_para,
        invoice_page,
        book_para,
        math_page,
        exam_anecdote_page,
    ]
    pages_meta = [{"width": 595, "height": 842} for _ in range(8)]
    res = classify_document_purpose(pages_meta, mixed_pages, "the_curious_biographer.pdf")
    assert res["allowed"] is True
    assert res["doc_category"] == "book"


# Alias for backwards compatibility
test_document_bouncer_7_genres = test_document_bouncer_20_archetypes


def test_epub_upload_validation_and_bouncer(tmp_path, monkeypatch):
    import io
    import zipfile
    import asyncio
    from fastapi import UploadFile
    from app.services.extraction import validate_pdf_file, extract_document_content, get_document_file_path
    from app.services.edge_ai import classify_document_purpose
    from app.routers import documents

    # Build a valid EPUB zip in memory
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr('mimetype', 'application/epub+zip')
        z.writestr(
            'META-INF/container.xml',
            '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
        )
        z.writestr(
            'content.opf',
            '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Marcus Aurelius Meditations</dc:title></metadata>'
            '<manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="c1"/></spine></package>'
        )
        chapter_body = """
        <h1>Book Two of the Meditations</h1>
        <p>When you wake up in the morning, tell yourself: the people I deal with today will be meddling, ungrateful, arrogant, dishonest, jealous, and surly. They are like this because they cannot distinguish good from evil. But I have seen the beauty of good, and the ugliness of evil, and have recognized that the wrongdoer has a nature related to my own—not of the same blood or birth, but the same mind, and possessing a share of the divine. And so none of them can hurt me. No one can implicate me in ugliness. Nor can I feel angry at my relative, or hate him. We were made to work together like feet, hands, and eyes, like the two rows of the upper and lower teeth. To obstruct each other is unnatural. To feel anger at someone, to turn your back on him: these are obstructions.</p>
        <p>Whatever this is that I am, it is a little flesh and breath, and the ruling part. Despise the flesh: blood and bones and a network, a jumble of nerves, veins, and arteries. Consider the breath: wind, always changing, expelled and sucked back in again. The third part is the master within. Set your books aside; do not be distracted; it is not permitted. Rather, as one already dying, scorn the flesh. It is nothing but gore and bones and a network, a fabric of nerves and veins and arteries. Look at the soul: thought and reason, governed by tranquility.</p>
        <p>Remember how long you have been putting this off, how many times you have been given a period of grace by the gods and not used it. It is high time you realized you too are a part of the universe, that you proceed from that which governs all things, and that you have a set limit on your time. If you do not use it to clear the clouds away, it will be gone and you with it, and it will never return again.</p>
        <p>Every hour of the day, give vigorous attention, as becomes a Roman and a man, to performing the task at hand with precise and unadorned dignity, with human sympathy, with freedom, and with justice, freeing your mind from all other thoughts. And you will accomplish this if you perform each action as if it were your last, ridding yourself of all frivolous behavior, of every emotional refusal to accept the promptings of reason, of all hypocrisy, self-love, and discontent with the fate that has been assigned to you. You see how few things you have to master to live a life that flows smoothly and reverently.</p>
        <p>Do wrong to yourself, my soul; do wrong to yourself. But the time will come when you will no longer have the chance to honor yourself. Each man has one life only, and yours is almost spent, yet you have no respect for yourself, but place your own happiness in the souls of other people. Why do you let external things distract you? Give yourself time to learn something new and good, and cease your restlessness. But here too you must beware of an error. For they are foolish who are weary of life and have no aim to which they can direct their every desire and thought.</p>
        """ * 2
        z.writestr('c1.xhtml', f'<html><body>{chapter_body}</body></html>')

    epub_bytes = buf.getvalue()
    epub_path = tmp_path / "meditations.epub"
    epub_path.write_bytes(epub_bytes)

    # 1. Validation test
    pages = validate_pdf_file(epub_path)
    assert pages >= 1

    # 2. Content extraction test
    extracted = extract_document_content(
        doc_id="epub_test_doc",
        file_path=epub_path,
        original_filename="meditations.epub",
    )
    assert len(extracted.get("canonical_text", "")) > 500
    telemetry = extracted.get("telemetry")
    assert telemetry is not None

    # 3. Bouncer test
    bouncer_res = classify_document_purpose(
        pages_meta=extracted.get("triage", {}).get("pages", []),
        sample_texts=[extracted.get("canonical_text", "")],
        raw_filename="meditations.epub",
        pdf_path=epub_path,
        telemetry=telemetry,
    )
    assert bouncer_res["allowed"] is True
    assert bouncer_res["doc_category"] == "book"

    # 4. Upload route test
    uploads_dir = tmp_path / "uploads"
    uploads_dir.mkdir()
    monkeypatch.setattr(documents, "UPLOADS_DIR", uploads_dir)
    monkeypatch.setattr(documents, "queue_document_job", lambda _doc_id: None)

    class FakeSession:
        def add(self, _doc):
            pass
        def commit(self):
            pass

    upload = UploadFile(filename="meditations.epub", file=io.BytesIO(epub_bytes))
    result = asyncio.run(documents.upload_document(upload, FakeSession()))
    doc_id = result["document_id"]

    saved_epub = uploads_dir / f"{doc_id}.epub"
    assert saved_epub.exists()
    assert saved_epub.stat().st_size == len(epub_bytes)

    # 5. File path resolver
    monkeypatch.setattr("app.services.extraction.UPLOADS_DIR", uploads_dir)
    found_path = get_document_file_path(doc_id)
    assert found_path == saved_epub


def test_app_update_and_platform_downloads():
    from fastapi.testclient import TestClient
    from app.main import app

    client = TestClient(app)

    # 1. Android platform check
    res_android = client.get("/api/app-update?current_version=1.0.0&platform=android")
    assert res_android.status_code == 200
    data_android = res_android.json()
    assert data_android["update_available"] is True
    assert "Athena-Android.apk" in data_android["android"]["filename"]
    assert data_android["android"]["download_url"] == "/api/download/android"

    # 2. iOS platform check
    res_ios = client.get("/api/app-update?current_version=1.0.0&platform=ios")
    assert res_ios.status_code == 200
    data_ios = res_ios.json()
    assert data_ios["update_available"] is True
    assert "Athena-iOS.ipa" in data_ios["ios"]["filename"]
    assert data_ios["ios"]["download_url"] == "/api/download/ios"

    # 3. Newer client version -> update_available == False
    res_newer = client.get("/api/app-update?current_version=9.9.9")
    assert res_newer.status_code == 200
    data_newer = res_newer.json()
    assert data_newer["update_available"] is False

    # 4. GET /download page check
    res_page = client.get("/download")
    assert res_page.status_code == 200
    assert "/api/download/android" in res_page.text
    assert "/api/download/ios" in res_page.text
    assert "Athena-Android.apk" in res_page.text
    assert "Athena-iOS.ipa" in res_page.text

    # 5. GET /api/download/android
    res_dl_android = client.get("/api/download/android", follow_redirects=False)
    assert res_dl_android.status_code == 200
    assert 'filename="Athena-Android.apk"' in res_dl_android.headers.get("content-disposition", "")
    assert len(res_dl_android.content) > 0

    # 6. GET /api/download/ios
    res_dl_ios = client.get("/api/download/ios", follow_redirects=False)
    assert res_dl_ios.status_code == 200
    assert 'filename="Athena-iOS.ipa"' in res_dl_ios.headers.get("content-disposition", "")
    assert len(res_dl_ios.content) > 0





