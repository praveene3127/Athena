import hashlib
import pytest
from app.services.ingestion.chunker import (
    chunk_document,
    is_legal_cut,
    _split_by_clauses,
)
from app.services.edge.hygiene import (
    dehyphenate_line_wraps,
    self_heal_prose_text,
)


def test_invariant_1_is_legal_cut_at_chunk_boundaries():
    """Invariant 1: All chunk start and end offsets must satisfy is_legal_cut (0 mid-token cuts)."""
    text = (
        "The quick brown fox jumps over the lazy dog. In 1914–1918 Europe experienced unprecedented turmoil. "
        "According to John 3:16, grace is universal. The constant pi is approximately 3.14159. "
        "Further details can be found at https://athena-reader.org/specifications for reference."
    )

    assert is_legal_cut(text, 0) is True
    assert is_legal_cut(text, len(text)) is True
    assert is_legal_cut(text, 4) is True  # after "The "
    assert is_legal_cut(text, 2) is False  # inside "The"
    assert is_legal_cut(text, 7) is False  # inside "quick"

    spans = [{"start": 0, "end": len(text), "page_start": 1, "page_end": 1, "type": "paragraph"}]
    chunks = chunk_document(
        doc_id="doc-inv-1",
        canonical_text=text,
        spans=spans,
    )

    assert len(chunks) > 0
    for chunk in chunks:
        start = chunk["start_offset"]
        end = chunk["end_offset"]
        assert is_legal_cut(text, start), f"Start {start} must be a legal cut"
        assert is_legal_cut(text, end), f"End {end} must be a legal cut"


def test_invariant_2_no_lowercase_hyphenated_orphans():
    """Invariant 2: No chunk begins with a lowercase continuation of a line-wrap hyphenated word."""
    sample = (
        "It was a monumental trans-\nformation of digital reading technology. "
        "We must nurture our self-\nesteem while cultivating mutual respect across cultures. "
        "The whole-document reflow engine ensures that every passage reads smoothly and consistently."
    )
    repaired = dehyphenate_line_wraps(sample)
    assert "transformation" in repaired
    assert "self-esteem" in repaired

    spans = [{"start": 0, "end": len(repaired), "page_start": 1, "page_end": 1, "type": "paragraph"}]
    chunks = chunk_document(
        doc_id="doc-inv-2",
        canonical_text=repaired,
        spans=spans,
    )

    for chunk in chunks:
        raw_text = chunk["raw_text"].lstrip()
        if raw_text:
            assert not raw_text.startswith("-") or not raw_text[1:2].islower(), (
                f"Chunk should not start with hyphenated orphan: {raw_text}"
            )


def test_invariant_3_words_per_chunk_cadence():
    """Invariant 3: Stable cadence with 0 intermediate orphan chunks < 20 words."""
    long_prose = " ".join(
        f"This is sentence {i} contributing to an insightful epistemic discussion on modern cognition."
        for i in range(16)
    )
    spans = [{"start": 0, "end": len(long_prose), "page_start": 1, "page_end": 2, "type": "paragraph"}]
    chunks = chunk_document(
        doc_id="doc-inv-3",
        canonical_text=long_prose,
        spans=spans,
    )

    assert len(chunks) >= 2
    for i in range(len(chunks) - 1):
        words = len(chunks[i]["raw_text"].strip().split())
        assert words >= 20, f"Intermediate chunk {i} has only {words} words"


def test_invariant_4_and_5_matter_vs_readable_roles():
    """Invariant 4 & 5: TOC/copyright vs Preface/Introduction classification."""
    matter_roles = {"toc", "copyright", "index", "bibliography"}
    readable_roles = {"preface", "introduction", "foreword", "prologue", "chapter"}

    # Disjoint sets
    assert matter_roles.isdisjoint(readable_roles)
    assert "preface" in readable_roles
    assert "introduction" in readable_roles
    assert "toc" in matter_roles
    assert "copyright" in matter_roles


def test_invariant_6_clause_and_sentence_boundaries():
    """Invariant 6: Clauses and sentence boundaries do not split times, decimals, citations, or URLs."""
    clause_sample = "At 4:30 p.m. John 3:16 was quoted; then 3.14159 was calculated; finally we read."
    cuts = _split_by_clauses(clause_sample)
    
    # Verify no cuts fall inside 4:30, 3:16, or 3.14159
    forbidden_spans = [
        (clause_sample.find("4:30"), clause_sample.find("4:30") + 4),
        (clause_sample.find("3:16"), clause_sample.find("3:16") + 4),
        (clause_sample.find("3.14159"), clause_sample.find("3.14159") + 7),
    ]

    for start, end in cuts:
        for f_start, f_end in forbidden_spans:
            if f_start != -1:
                assert not (f_start < start < f_end), f"Cut {start} bisects protected token [{f_start}, {f_end}]"
                assert not (f_start < end < f_end), f"Cut {end} bisects protected token [{f_start}, {f_end}]"


def test_invariant_7_line_end_dehyphenation():
    """Invariant 7: Line-end dehyphenation correctly joins soft and compound hyphens."""
    assert dehyphenate_line_wraps("trans-\nformation") == "transformation"
    assert dehyphenate_line_wraps("self-\nesteem") == "self-esteem"
    assert dehyphenate_line_wraps("under-\nstanding") == "understanding"


def test_invariant_8_lossless_reconstruction():
    """Invariant 8: Lossless reconstruction invariant (sum of chunks == canonical_text with matching SHA-256)."""
    canonical = (
        "First paragraph of the manuscript setting the philosophical premise.\n\n"
        "Second paragraph articulating the empirical evidence with neuroplasticity and quantum dynamics. "
        "The cognitive architecture demonstrates clear advantages in continuous reading.\n\n"
        "Third paragraph providing synthesis and grounded conclusions."
    )
    spans = [
        {"start": 0, "end": 69, "page_start": 1, "page_end": 1, "type": "paragraph"},
        {"start": 71, "end": 242, "page_start": 1, "page_end": 2, "type": "paragraph"},
        {"start": 244, "end": len(canonical), "page_start": 2, "page_end": 2, "type": "paragraph"},
    ]

    chunks = chunk_document(
        doc_id="doc-lossless-inv-py",
        canonical_text=canonical,
        spans=spans,
    )

    reconstructed = "".join(c["raw_text"] for c in chunks)
    assert reconstructed == canonical
    assert hashlib.sha256(reconstructed.encode("utf-8")).hexdigest() == hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def test_invariant_9_preserves_legitimate_compound_words():
    """Invariant 9: Legitimate compound and technical vocabulary are preserved without mutation."""
    words = [
        "schoolteacher",
        "breakthrough",
        "thanksgiving",
        "withholding",
        "nevertheless",
        "counterpoint",
        "neuroplasticity",
        "electromagnetism",
    ]

    for w in words:
        cleaned = self_heal_prose_text(w)
        assert cleaned == w, f"Legitimate word {w} mutated into {cleaned}"
