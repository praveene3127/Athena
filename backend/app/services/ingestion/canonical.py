"""
Stage 6: Canonical Text Assembly, Offset Spans, and Provenance Index.

Produces the immutable canonical text string from structured units,
builds the character offset index for original-page navigation and context cards,
and provides guarded sentence boundary splitting.
"""

import re
from typing import Any, Dict, List, Set, Tuple

from app.services.edge_ai import self_heal_prose_text, COMPOUND_PREFIXES

# Known abbreviations that must NEVER trigger sentence cuts
ABBREVIATIONS: Set[str] = {
    "et al.", "fig.", "figs.", "e.g.", "i.e.", "dr.", "mr.", "mrs.", "ms.",
    "prof.", "vol.", "no.", "pp.", "vs.", "ca.", "cf.", "al.", "inc.", "ltd.",
    "jr.", "sr.", "approx.", "dept.", "est.", "min.", "sec.", "univ.", "ed.",
    "eds.", "ref.", "refs.", "eq.", "eqs.", "p.", "ch.", "sec."
}

# Regex to detect sentence ending punctuation followed by whitespace and uppercase/digit/quote
RE_SENTENCE_CANDIDATE = re.compile(r"([.!?])(\s+)(?=[A-Z0-9\"'\(])")


def find_safe_sentence_boundaries(text: str) -> List[int]:
    """
    Finds cut offsets in text after sentence terminal punctuation,
    guarding strictly against abbreviations, decimals (3.14), initials (J. K.),
    and lowercase continuations.
    
    Returns offsets at the end of whitespace so trailing whitespace stays with previous sentence.
    """
    boundaries: List[int] = []

    for m in RE_SENTENCE_CANDIDATE.finditer(text):
        punct_idx = m.start(1)
        ws_end = m.end(2)

        # Guard 1: Decimal numbers like 3.14 or 0.5
        if punct_idx > 0 and punct_idx + 1 < len(text):
            if text[punct_idx - 1].isdigit() and text[punct_idx + 1].isdigit():
                continue

        # Guard 2: Preceding token is an abbreviation
        preceding = text[:punct_idx + 1].split()
        if preceding:
            last_word = preceding[-1].lower()
            if last_word in ABBREVIATIONS:
                continue
            # Single capital letter with period (initials like 'E. Coli' or 'J. Doe')
            if len(last_word) == 2 and last_word[0].isalpha() and last_word[1] == ".":
                continue

        boundaries.append(ws_end)

    return boundaries


def assemble_canonical_text(
    units: List[Dict[str, Any]],
    separator: str = "\n\n",
) -> Tuple[str, List[Dict[str, Any]]]:
    """
    Assembles canonical text by joining clean units with a fixed separator.
    Computes exact, contiguous character offset spans for each unit.
    """
    if not units:
        return "", []

    # Semantic Zone Partitioning: Exclude printed TOC entries, front matter, noise, footnotes, and back matter from reading prose
    body_units = [u for u in units if u.get("type") not in ("contents_entry", "front_matter", "noise", "footnote", "back_matter")]
    target_units = body_units if body_units else units

    # 1. Dehyphenate and stitch cross-unit splits (e.g. page-break hyphens like 'responsi-' and 'bility')
    merged_units: List[Dict[str, Any]] = []
    for u in target_units:
        if merged_units:
            prev_u = merged_units[-1]
            prev_text = prev_u["text"].rstrip()
            curr_text = u.get("text", "").lstrip()
            hyphen_match = re.search(r"([A-Za-z]+)-\s*$", prev_text)
            if hyphen_match and curr_text and (curr_text[0].islower() or curr_text[0] in "('\""):
                prefix = hyphen_match.group(1)
                if prefix.lower() in COMPOUND_PREFIXES:
                    prev_u["text"] = prev_text[:hyphen_match.start()] + prefix + "-" + curr_text
                else:
                    prev_u["text"] = prev_text[:hyphen_match.start()] + prefix + curr_text
                prev_u["page_end"] = u.get("page_end", prev_u.get("page_end", 1))
                continue
        u_copy = dict(u)
        merged_units.append(u_copy)

    # 2. Universal Self-Healing Prose Normalization per merged unit to guarantee 100% clean canonical text
    cleaned_units: List[Dict[str, Any]] = []
    for u in merged_units:
        healed = self_heal_prose_text(u.get("text", ""))
        if healed:
            u["text"] = healed
            cleaned_units.append(u)

    target_processed = cleaned_units if cleaned_units else merged_units
    blocks_text = [u["text"] for u in target_processed]
    canonical_text = separator.join(blocks_text)

    spans: List[Dict[str, Any]] = []
    current_offset = 0
    sep_len = len(separator)

    for i, u in enumerate(target_processed):
        text_len = len(u["text"])
        start = current_offset
        end = start + text_len

        spans.append({
            "start": start,
            "end": end,
            "page_start": u.get("page_start", 1),
            "page_end": u.get("page_end", 1),
            "type": u.get("type", "paragraph"),
            "heading": u.get("type") == "heading",
            "bbox": u.get("bbox"),
            "font_size": u.get("font_size"),
            "is_bold": u.get("is_bold", False),
        })

        current_offset = end + sep_len

    return canonical_text, spans
