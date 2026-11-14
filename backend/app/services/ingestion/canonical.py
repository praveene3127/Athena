"""
Stage 6: Canonical Text Assembly, Offset Spans, and Provenance Index.

Produces the immutable canonical text string from structured units,
builds the character offset index for original-page navigation and context cards,
and provides guarded sentence boundary splitting.
"""

import re
from typing import Any, Dict, List, Set, Tuple

from app.services.edge.hygiene import self_heal_prose_text, COMPOUND_PREFIXES

# Known abbreviations that must NEVER trigger sentence cuts (Golden Rule, FP-2)
ABBREVIATIONS: Set[str] = {
    "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "inc.", "ltd.", "co.",
    "vs.", "etc.", "e.g.", "i.e.", "cf.", "al.", "vol.", "no.", "ed.",
    "eds.", "pp.", "p.", "rev.", "gen.", "sen.", "rep.", "gov.", "pres.",
    "sec.", "dept.", "univ.", "assn.", "corp.", "jan.", "feb.", "mar.",
    "apr.", "jun.", "jul.", "aug.", "sep.", "sept.", "oct.", "nov.", "dec.",
    "ca.", "jr.", "sr.", "fig.", "figs.", "ch.", "ref.", "refs.", "eq.", "eqs.",
    "et al.", "approx.", "est.", "min."
}

# Regex matching the Golden Rule sentence boundary detector with multilingual support (FP-2, LNG-03):
# Supports Latin (.!?…), CJK (。\uff01\uff1f), Indic (।॥), Arabic (؟)
RE_SENTENCE_CANDIDATE = re.compile(
    r"([.!?…\u3002\uff01\uff1f\u0964\u0965\u061f]+|\.\s?\.\s?\.)([”\"’\'\)\]»]*)([\s\u3000]*)(?=[“\"‘\'\(\[«¿¡]*([\w]|[\u0900-\u097F\u0B80-\u0BFF\u0600-\u06FF\u0590-\u05FF\u3040-\u9FFF\uAC00-\uD7AF]|$))",
    re.UNICODE
)


def find_safe_sentence_boundaries(text: str) -> List[int]:
    """
    Finds cut offsets in text after sentence terminal punctuation (Golden Rule, FP-2),
    guarding strictly against abbreviations, decimals (3.14), initials (J. K.),
    and times/versions across Latin and non-Latin scripts.
    
    Returns offsets at the end of whitespace so trailing whitespace stays with previous sentence.
    """
    boundaries: List[int] = []

    for m in RE_SENTENCE_CANDIDATE.finditer(text):
        punct_text = m.group(1)
        punct_idx = m.start(1)
        punct_end = punct_idx + len(punct_text)
        ws_end = m.end(3)

        # Guard 1: Decimal numbers like 3.14 or 2.0
        if punct_end > 0 and punct_end < len(text):
            if text[punct_end - 1].isdigit() and text[punct_end].isdigit():
                continue

        # Guard 2: Preceding token is an abbreviation or initial
        preceding = text[:punct_idx].split()
        if preceding:
            last_word = preceding[-1].lower()
            if last_word in ABBREVIATIONS or f"{last_word}." in ABBREVIATIONS:
                continue
            # Single capital letter with period (initials like 'E.' or 'J.')
            if len(last_word) == 1 and last_word.isalpha():
                continue
            if len(last_word) == 2 and last_word[0].isalpha() and last_word[1] == ".":
                continue

        # For ASCII/Latin punct, require whitespace before the next word
        is_multilingual_term = any(ch in "\u3002\uff01\uff1f\u0964\u0965\u061f" for ch in punct_text)
        if not m.group(3) and not is_multilingual_term and ws_end < len(text):
            continue

        if ws_end > 0:
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

    # Semantic Zone Partitioning: Exclude printed TOC entries, noise, and footnotes while preserving substantive preface/foreword prose (RC-04)
    def _is_droppable_unit(u: Dict[str, Any]) -> bool:
        u_type = u.get("type")
        if u_type in ("contents_entry", "noise", "footnote"):
            return True
        if u_type in ("front_matter", "back_matter"):
            text_low = u.get("text", "").lower()
            if any(term in text_low for term in ("preface", "foreword", "prologue", "introduction")):
                if len(text_low.split()) >= 40:
                    return False
            return True
        return False

    body_units = [u for u in units if not _is_droppable_unit(u)]
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
