import re
from typing import Any, Dict, List, Tuple
from app.config import MARGIN_FRACTION

# Ligature lookup map
LIGATURE_MAP = {
    "\ufb01": "fi",
    "\ufb02": "fl",
    "\ufb00": "ff",
    "\ufb03": "ffi",
    "\ufb04": "ffl",
}

# Line break hyphenation regex: e.g. "com-\nputer" -> "computer"
RE_DEHYPHEN = re.compile(r"(?<=[A-Za-z])-\n(?=[a-z])")
RE_NEWLINES = re.compile(r"\r\n|\n|\r")
RE_SPACES = re.compile(r"[ \t]+")
RE_PAGE_NUM = re.compile(r"^(?:page\s+)?(?:\d+|[ivxlcdm]+)$", re.IGNORECASE)


from app.services.repairs import repair_text


def normalize_block_text(text: str, ledger: Any = None) -> str:
    """Applies Stage 2 character repair and steps 1-6 of normalize_v1."""
    if not text:
        return ""

    # Apply Stage 2 character repair (C1 control mapping, ligatures, invisibles)
    t, _ = repair_text(text, ledger=ledger)

    # De-hyphenate line breaks: e.g. "com-\nputer" -> "computer"
    t = RE_DEHYPHEN.sub("", t)

    # Remaining newlines to single space
    t = RE_NEWLINES.sub(" ", t)

    # Collapse runs of spaces/tabs to one space and strip
    t = RE_SPACES.sub(" ", t).strip()

    return t



def is_page_number_pattern(text: str) -> bool:
    """Checks if text consists only of digits, roman numerals, or 'Page N'."""
    return bool(RE_PAGE_NUM.match(text.strip()))


def normalize_document_blocks(
    page_blocks: List[List[Dict[str, Any]]],
    total_pages: int,
) -> Tuple[str, List[Dict[str, Any]]]:
    """
    Applies normalize_v1 across all document blocks (§6.3 in CLAUDE.md):
    - Normalizes each block text
    - Identifies and removes repeated header/footer and page-number margin blocks
    - Applies cross-page merges
    - Produces canonical_text and exact offset spans.
    """
    # 1. First pass: normalize text and track margin occurrences
    margin_text_page_counts: Dict[str, set] = {}

    for page_idx, blocks in enumerate(page_blocks):
        page_num = page_idx + 1
        for b in blocks:
            norm_text = normalize_block_text(b["text"])
            b["clean_text"] = norm_text
            b["page"] = page_num

            # Check if block is in margin zone
            h = b["page_height"]
            y0, y1 = b["bbox"][1], b["bbox"][3]
            in_margin = (y1 < MARGIN_FRACTION * h) or (y0 > (1.0 - MARGIN_FRACTION) * h)
            b["in_margin"] = in_margin

            if in_margin and norm_text:
                # Digit-stripped lowercase signature for repeated running headers/footers
                sig = re.sub(r"\d+", "", norm_text).lower().strip()
                if sig:
                    margin_text_page_counts.setdefault(sig, set()).add(page_num)

    # Threshold for recurring headers/footers across pages (>= 40% of pages)
    repeat_threshold = max(2, int(total_pages * 0.4))

    # 2. Filter blocks
    kept_blocks: List[Dict[str, Any]] = []

    for blocks in page_blocks:
        for b in blocks:
            text = b["clean_text"]
            if not text:
                continue  # Step 7: Drop empty blocks

            if b["in_margin"]:
                # Check condition 8: is page number pattern OR repeated across >= 40% of pages
                if is_page_number_pattern(text):
                    continue
                sig = re.sub(r"\d+", "", text).lower().strip()
                if sig and len(margin_text_page_counts.get(sig, set())) >= repeat_threshold:
                    continue

            kept_blocks.append(b)

    if not kept_blocks:
        return "", []

    # 3. Cross-page merge (Step 9)
    # If the last kept block of page N doesn't end with . ! ? : ” " and
    # the first block of page N+1 starts with a lowercase letter, join them with one space.
    sentence_end_chars = {".", "!", "?", ":", "”", '"'}
    merged_units: List[Dict[str, Any]] = []

    for block in kept_blocks:
        if merged_units:
            prev = merged_units[-1]
            prev_text = prev["clean_text"]
            curr_text = block["clean_text"]

            # Check if block is on next page and qualifies for merge
            if (
                block["page"] > prev["page_end"]
                and prev_text
                and prev_text[-1] not in sentence_end_chars
                and curr_text
                and curr_text[0].islower()
            ):
                # Join with one space and extend page span
                prev["clean_text"] = f"{prev_text} {curr_text}"
                prev["page_end"] = block["page"]
                continue

        merged_units.append({
            "clean_text": block["clean_text"],
            "page_start": block["page"],
            "page_end": block["page"],
            "heading": block.get("heading", False),
        })

    # 4. Construct canonical_text and spans
    # Canonical text = "\n\n".join(blocks)
    blocks_text = [u["clean_text"] for u in merged_units]
    canonical_text = "\n\n".join(blocks_text)

    spans: List[Dict[str, Any]] = []
    current_offset = 0

    for i, u in enumerate(merged_units):
        text_len = len(u["clean_text"])
        start = current_offset
        end = start + text_len
        spans.append({
            "start": start,
            "end": end,
            "page_start": u["page_start"],
            "page_end": u["page_end"],
        })
        # Advance offset past the block and the "\n\n" separator
        current_offset = end + 2

    return canonical_text, spans
