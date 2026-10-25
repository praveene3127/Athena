"""
Lossless offset-based chunker with Intelligent Reading Arrangement Layer.

Chunks are strictly contiguous slices of the canonical text (canonical_text[start:end]).
Never split() and re-join. Separators (\\n\\n) stay attached to preceding chunks.
Boundary selection is driven by the Intelligent Reading Arrangement graph
(prioritizing complete thoughts, concept continuity, and section boundaries).
"""

import hashlib
import re
from typing import Any, Dict, List, Tuple

from app.services.canonical import find_safe_sentence_boundaries
from app.services.arrangement import classify_block, UnitType


_FEED_MIN_WORDS = 25
_FEED_MAX_WORDS = 90
_CONTINUATION_START = re.compile(
    r"^(however|therefore|thus|moreover|furthermore|for example|for instance|"
    r"as a result|in contrast|because|but|and|so|this|these|they|it)\b",
    re.IGNORECASE,
)
_TOKEN = re.compile(r"[A-Za-z]{4,}")
_COHESION_STOPWORDS = {
    "about", "after", "also", "among", "because", "been", "before", "being",
    "between", "could", "does", "each", "from", "have", "into", "just", "more",
    "most", "over", "same", "some", "such", "than", "that", "their", "them",
    "then", "there", "these", "they", "this", "those", "through", "under", "very",
    "were", "what", "when", "where", "which", "while", "with", "would",
}


def _word_count(text: str) -> int:
    """Counts words in text (splitting on whitespace)."""
    return len(text.split())


def _sha256(text: str) -> str:
    """Returns hex SHA-256 digest of text encoded as UTF-8."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _find_pages_for_span(
    start: int, end: int, spans: List[Dict[str, Any]]
) -> List[int]:
    """
    Finds all pages that overlap with the given character range [start, end)
    using the block spans from normalization.
    """
    pages: set = set()
    for span in spans:
        if span.get("end", 0) > start and span.get("start", 0) < end:
            p_start = span.get("page_start", 1)
            p_end = span.get("page_end", p_start)
            for p in range(p_start, p_end + 1):
                pages.add(p)
    return sorted(pages) if pages else [1]


def _split_oversized_unit(text: str, max_words: int) -> List[Tuple[int, int]]:
    """
    Splits an oversized text unit at guarded sentence boundaries into offset ranges.
    Returns a list of (start, end) tuples relative to the text.
    All characters are accounted for — zero gaps.
    """
    boundaries = find_safe_sentence_boundaries(text)

    if not boundaries:
        if _word_count(text) > 200:
            return _hard_split_offsets(text, max_words)
        return [(0, len(text))]

    pieces: List[Tuple[int, int]] = []
    prev_offset = 0
    for b in boundaries:
        pieces.append((prev_offset, b))
        prev_offset = b
    if prev_offset < len(text):
        pieces.append((prev_offset, len(text)))

    packed: List[Tuple[int, int]] = []
    current_start = 0
    current_end = 0

    for (p_start, p_end) in pieces:
        piece_text = text[p_start:p_end]
        piece_words = _word_count(piece_text)

        if piece_words > 200:
            if current_end > current_start:
                packed.append((current_start, current_end))
            sub_splits = _hard_split_offsets(piece_text, max_words)
            for (ss, se) in sub_splits:
                packed.append((p_start + ss, p_start + se))
            current_start = p_end
            current_end = p_end
            continue

        current_text = text[current_start:p_end]
        current_words = _word_count(current_text)

        if current_words <= max_words:
            current_end = p_end
        else:
            if current_end > current_start:
                packed.append((current_start, current_end))
            current_start = p_start
            current_end = p_end

    if current_end > current_start:
        packed.append((current_start, current_end))

    return packed if packed else [(0, len(text))]


def _hard_split_offsets(text: str, max_words: int) -> List[Tuple[int, int]]:
    """
    Hard-splits text at whitespace boundaries into pieces <= max_words.
    Preserves all characters.
    """
    word_starts: List[int] = []
    in_word = False
    for i, ch in enumerate(text):
        if ch.isspace():
            in_word = False
        else:
            if not in_word:
                word_starts.append(i)
                in_word = True

    if not word_starts:
        return [(0, len(text))]

    splits: List[Tuple[int, int]] = []
    chunk_start = 0
    word_count = 0

    for i, ws in enumerate(word_starts):
        word_count += 1
        if word_count >= max_words and i + 1 < len(word_starts):
            chunk_end = word_starts[i + 1]
            splits.append((chunk_start, chunk_end))
            chunk_start = chunk_end
            word_count = 0

    if chunk_start < len(text):
        splits.append((chunk_start, len(text)))

    return splits


def _paragraph_units(
    canonical_text: str, spans: List[Dict[str, Any]]
) -> List[Dict[str, Any]]:
    """Split only at the canonical paragraph delimiter, keeping exact offsets."""
    units: List[Dict[str, Any]] = []
    ordered_spans = sorted(spans, key=lambda span: span.get("start", 0))
    span_index = 0
    start = 0
    while start < len(canonical_text):
        delimiter = canonical_text.find("\n\n", start)
        content_end = len(canonical_text) if delimiter < 0 else delimiter
        end = len(canonical_text) if delimiter < 0 else delimiter + 2
        text = canonical_text[start:content_end]

        while span_index < len(ordered_spans) and ordered_spans[span_index].get("end", 0) <= start:
            span_index += 1
        matched_span = None
        if span_index < len(ordered_spans):
            candidate = ordered_spans[span_index]
            if candidate.get("start", 0) < content_end:
                matched_span = candidate
        unit_type = matched_span.get("type") if matched_span else None
        if not unit_type:
            unit_type = classify_block(text)

        units.append(
            {
                "start": start,
                "content_end": content_end,
                "end": end,
                "text": text,
                "type": unit_type,
                "page_start": matched_span.get("page_start", 1) if matched_span else 1,
                "page_end": matched_span.get("page_end", 1) if matched_span else 1,
            }
        )
        start = end

    return units


def _target_words_for_document(units: List[Dict[str, Any]]) -> int:
    """Estimate a steady feed-card size from this book's paragraph profile."""
    body_lengths = [
        _word_count(unit["text"])
        for unit in units
        if unit["type"] != UnitType.HEADING and _word_count(unit["text"]) > 0
    ]
    if not body_lengths:
        return 56

    body_lengths.sort()
    median = body_lengths[len(body_lengths) // 2]
    short_ratio = sum(length <= 30 for length in body_lengths) / len(body_lengths)
    long_ratio = sum(length >= 90 for length in body_lengths) / len(body_lengths)

    # These are document-shape profiles, not genre claims. A book with many short
    # paragraphs gets a slightly smaller target; long-block books get more room.
    if median <= 30 and short_ratio >= 0.55:
        return 48
    if median >= 70 or long_ratio >= 0.35:
        return 64
    return 56


def _make_reading_atoms(
    canonical_text: str,
    units: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """Create safe paragraph/sentence units; headings stay with their opening text."""
    atoms: List[Dict[str, Any]] = []
    index = 0
    while index < len(units):
        unit = units[index]

        # Keep consecutive headings and the first following paragraph together.
        if unit["type"] == UnitType.HEADING:
            heading_start = unit["start"]
            heading_end = unit["end"]
            section_title = unit["text"].strip()
            index += 1
            while index < len(units) and units[index]["type"] == UnitType.HEADING:
                heading_end = units[index]["end"]
                section_title = f"{section_title}: {units[index]['text'].strip()}"
                index += 1

            if index < len(units):
                body = units[index]
                body_text = body["text"]
                if body["type"] == UnitType.CONTENTS_ENTRY:
                    index += 1
                    atoms.append(
                        {
                            "start": heading_start,
                            "end": body["end"],
                            "word_count": _word_count(canonical_text[heading_start:body["end"]]),
                            "paragraph_id": index - 1,
                            "boundary_after": "paragraph",
                            "starts_section": True,
                            "section_title": section_title,
                        }
                    )
                    continue

                body_word_count = _word_count(body_text)
                if body_word_count > _FEED_MAX_WORDS:
                    relative_slices = _split_oversized_unit(
                        body_text, max_words=_FEED_MAX_WORDS
                    )
                else:
                    relative_slices = [(0, len(body_text))]

                for part_index, (rel_start, rel_end) in enumerate(relative_slices):
                    part_start = heading_start if part_index == 0 else body["start"] + rel_start
                    part_end = body["end"] if part_index == len(relative_slices) - 1 else body["start"] + rel_end
                    atoms.append(
                        {
                            "start": part_start,
                            "end": part_end,
                            "word_count": _word_count(canonical_text[part_start:part_end]),
                            "paragraph_id": index,
                            "boundary_after": "sentence" if len(relative_slices) > 1 else "paragraph",
                            "starts_section": part_index == 0,
                            "section_title": section_title if part_index == 0 else None,
                        }
                    )
                index += 1
                continue

            # A trailing heading has no body to attach to; retain it verbatim.
            atoms.append(
                {
                    "start": heading_start,
                    "end": heading_end,
                    "word_count": _word_count(canonical_text[heading_start:heading_end]),
                    "paragraph_id": index - 1,
                    "boundary_after": "paragraph",
                    "starts_section": True,
                    "section_title": section_title,
                }
            )
            continue

        paragraph_text = unit["text"]
        word_count = _word_count(paragraph_text)
        if word_count > _FEED_MAX_WORDS:
            relative_slices = _split_oversized_unit(
                paragraph_text, max_words=_FEED_MAX_WORDS
            )
        else:
            relative_slices = [(0, len(paragraph_text))]

        for part_index, (rel_start, rel_end) in enumerate(relative_slices):
            part_start = unit["start"] + rel_start
            part_end = unit["end"] if part_index == len(relative_slices) - 1 else unit["start"] + rel_end
            atoms.append(
                {
                    "start": part_start,
                    "end": part_end,
                    "word_count": _word_count(canonical_text[part_start:part_end]),
                    "paragraph_id": index,
                    "boundary_after": "sentence" if len(relative_slices) > 1 else "paragraph",
                    "starts_section": False,
                    "section_title": None,
                }
            )
        index += 1

    return atoms


def _boundary_penalty(left_text: str, right_text: str, same_paragraph: bool) -> float:
    """A local, deterministic cohesion signal used only to rank safe boundaries."""
    if not right_text.strip():
        return 0.0
    penalty = 0.12 if same_paragraph else 0.0
    if _CONTINUATION_START.match(right_text.lstrip()):
        penalty += 0.42

    left_terms = {
        token.lower()
        for token in _TOKEN.findall(left_text[-600:])
        if token.lower() not in _COHESION_STOPWORDS
    }
    right_terms = {
        token.lower()
        for token in _TOKEN.findall(right_text[:600])
        if token.lower() not in _COHESION_STOPWORDS
    }
    if left_terms and right_terms:
        overlap = len(left_terms & right_terms) / min(len(left_terms), len(right_terms))
        penalty += min(0.3, overlap * 0.3)
    return penalty


def _plan_feed_chunks(
    canonical_text: str, atoms: List[Dict[str, Any]], target_words: int
) -> List[Tuple[int, int]]:
    """Choose contiguous atom ranges with a bounded, low-variance reading cadence."""
    if not atoms:
        return []

    min_words = max(_FEED_MIN_WORDS, int(target_words * 0.55))
    costs = [float("inf")] * (len(atoms) + 1)
    next_index = [len(atoms)] * len(atoms)
    costs[-1] = 0.0

    for start in range(len(atoms) - 1, -1, -1):
        words = 0
        for end in range(start, len(atoms)):
            if end > start and atoms[end]["starts_section"]:
                break
            words += atoms[end]["word_count"]
            if words > _FEED_MAX_WORDS and end > start:
                break

            deviation = (words - target_words) / target_words
            chunk_cost = deviation * deviation
            if words < min_words and end + 1 < len(atoms):
                shortfall = (min_words - words) / min_words
                chunk_cost += 2.0 * shortfall * shortfall
            if words > _FEED_MAX_WORDS:
                overflow = (words - _FEED_MAX_WORDS) / _FEED_MAX_WORDS
                chunk_cost += 8.0 * overflow * overflow

            if end + 1 < len(atoms):
                left = canonical_text[atoms[end]["start"]:atoms[end]["end"]]
                right = canonical_text[atoms[end + 1]["start"]:atoms[end + 1]["end"]]
                chunk_cost += _boundary_penalty(
                    left,
                    right,
                    atoms[end]["paragraph_id"] == atoms[end + 1]["paragraph_id"],
                )
                if atoms[end]["boundary_after"] == "sentence":
                    chunk_cost += 0.08

            total_cost = chunk_cost + costs[end + 1]
            if total_cost < costs[start]:
                costs[start] = total_cost
                next_index[start] = end + 1

            # A single oversized indivisible sentence/paragraph is retained whole.
            if words > _FEED_MAX_WORDS:
                break

    ranges: List[Tuple[int, int]] = []
    start = 0
    while start < len(atoms):
        end = next_index[start]
        if end <= start:
            raise ValueError(f"No valid feed boundary after atom {start}")
        ranges.append((start, end))
        start = end
    return ranges


def chunk_document(
    doc_id: str,
    canonical_text: str,
    spans: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """
    Produces short feed cards using paragraph structure, a per-document size
    profile, and local cohesion cues. Boundaries always remain canonical offsets.
    """
    if not canonical_text:
        return []

    units = _paragraph_units(canonical_text, spans)
    target_words = _target_words_for_document(units)
    atoms = _make_reading_atoms(canonical_text, units)
    ranges = _plan_feed_chunks(canonical_text, atoms, target_words)

    # Validate the plan before materializing records; never silently repair gaps.
    expected_start = 0
    for atom_start, atom_end in ranges:
        if atom_start < 0 or atom_end <= atom_start or atom_end > len(atoms):
            raise ValueError("Adaptive chunker produced an invalid atom range")
        first = atoms[atom_start]
        last = atoms[atom_end - 1]
        if first["start"] != expected_start or last["end"] <= first["start"]:
            raise ValueError("Adaptive chunker produced non-contiguous source offsets")
        expected_start = last["end"]
    if expected_start != len(canonical_text):
        raise ValueError("Adaptive chunker did not cover the full canonical text")

    canonical_hash = _sha256(canonical_text)
    result: List[Dict[str, Any]] = []
    previous_end = 0
    for seq_idx, (atom_start, atom_end) in enumerate(ranges):
        seq = seq_idx + 1
        chunk_id = f"{doc_id}-c{seq:04d}"
        first_atom = atoms[atom_start]
        last_atom = atoms[atom_end - 1]
        c_start = first_atom["start"]
        c_end = last_atom["end"]
        if c_start != previous_end:
            raise ValueError("Adaptive chunker produced a gap or overlap")
        raw_text = canonical_text[c_start:c_end]
        pages = _find_pages_for_span(c_start, c_end, spans)
        section_title = next(
            (atoms[i]["section_title"] for i in range(atom_start, atom_end) if atoms[i].get("section_title")),
            None,
        )

        result.append({
            "id": chunk_id,
            "document_id": doc_id,
            "sequence": seq,
            "section_title": section_title,
            "raw_text": raw_text,
            "source_pages_json": pages,
            "start_offset": c_start,
            "end_offset": c_end,
            "checksum": _sha256(raw_text),
            "boundary_method": last_atom["boundary_after"],
            "canonical_sha256": canonical_hash,
        })
        previous_end = c_end

    if previous_end != len(canonical_text):
        raise ValueError("Adaptive chunker output did not cover the source text")
    return result
