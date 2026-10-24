"""
Stage 1 (Structured Capture), Stage 3 (Reading Order), Stage 4 (Block Typing),
and Stage 5 (Paragraph Reconstruction).

Transforms raw PDF dict spans into typed, ordered, reconstructed document blocks
with full provenance and zero silent data loss.
"""

from collections import Counter
import re
from typing import Any, Callable, Dict, List, Optional, Set, Tuple
import pymupdf

from app.services.repairs import repair_text, RepairLedger
from app.services.edge_ai import (
    clean_block_hygiene,
    is_front_matter_or_noise_page,
    self_heal_prose_text,
    COMPOUND_PREFIXES,
)


class BlockType:
    HEADING = "heading"
    PARAGRAPH = "paragraph"
    LIST_ITEM = "list"
    QUOTE = "quote"
    RUNNING_HEADER = "running_header"
    RUNNING_FOOTER = "running_footer"
    CONTENTS_ENTRY = "contents_entry"
    TABLE = "table"
    CAPTION = "caption"
    FRONT_MATTER = "front_matter"
    NOISE = "noise"
    FOOTNOTE = "footnote"
    BACK_MATTER = "back_matter"


# Regexes for lists, numbers, and contents entries
RE_LIST_BULLET = re.compile(r"^([•*\-–—▪▫◦]|\d+[\.\)]|\([a-zA-Z0-9]+\))\s+")
RE_CONTENTS_LEADER = re.compile(r"(\.{3,}|_{3,}|\s{4,})\s*\d+$")
RE_DIGITS = re.compile(r"\d+")
RE_PUNCTUATION_END = re.compile(r"[.!?:\”\"']$")
RE_LINE_HYPHEN = re.compile(r"([A-Za-z]+)-\s*$")


def _looks_like_two_columns(blocks: List[Dict[str, Any]], page_width: float) -> bool:
    """Conservatively flags a page whose blocks suggest two text lanes."""
    left = 0
    right = 0
    for block in blocks:
        x0, _, x1, _ = block["bbox"]
        width = x1 - x0
        if width >= page_width * 0.68:
            continue
        if x1 <= page_width * 0.58:
            left += 1
        if x0 >= page_width * 0.42:
            right += 1
    return left >= 2 and right >= 2


def _find_column_gutter(
    blocks: List[Dict[str, Any]], page_width: float
) -> Optional[float]:
    """Finds a central whitespace gutter supported by multiple blocks per lane."""
    body_blocks = []
    edges = set()
    for block in blocks:
        x0, _, x1, _ = block["bbox"]
        if x1 - x0 >= page_width * 0.68:
            continue
        body_blocks.append(block)
        edges.add(x0)
        edges.add(x1)

    sorted_edges = sorted(x for x in edges if page_width * 0.24 <= x <= page_width * 0.76)
    min_gap = max(10.0, page_width * 0.018)
    candidates = []
    for left_edge, right_edge in zip(sorted_edges, sorted_edges[1:]):
        gap = right_edge - left_edge
        cut = (left_edge + right_edge) / 2
        if gap < min_gap or not page_width * 0.27 <= cut <= page_width * 0.73:
            continue

        left_count = sum(1 for b in body_blocks if b["bbox"][2] <= left_edge)
        right_count = sum(1 for b in body_blocks if b["bbox"][0] >= right_edge)
        if left_count < 2 or right_count < 2:
            continue

        left_blocks = [b for b in body_blocks if b["bbox"][2] <= left_edge]
        right_blocks = [b for b in body_blocks if b["bbox"][0] >= right_edge]
        vertically_supported_left = set()
        vertically_supported_right = set()
        for left_index, left_block in enumerate(left_blocks):
            for right_index, right_block in enumerate(right_blocks):
                overlap = min(left_block["bbox"][3], right_block["bbox"][3]) - max(
                    left_block["bbox"][1], right_block["bbox"][1]
                )
                if overlap > 0:
                    vertically_supported_left.add(left_index)
                    vertically_supported_right.add(right_index)
        if len(vertically_supported_left) < 2 or len(vertically_supported_right) < 2:
            continue

        center_penalty = abs(cut - page_width / 2) / page_width
        candidates.append((gap / page_width - center_penalty * 0.25, cut))

    return max(candidates, default=(0.0, None), key=lambda item: item[0])[1]


def _order_page_blocks(
    blocks: List[Dict[str, Any]], page_width: float, page_height: float
) -> Tuple[List[Dict[str, Any]], bool, bool]:
    """Orders one page; returns (blocks, is_two_column, uncertain_layout).

    A supported central gutter establishes columns. Full-width regions then split
    the page into vertical bands, so each band is read left column top-to-bottom,
    then right column top-to-bottom, with spanning regions in their visual place.
    If a page only looks columnar but has no defensible gutter, retain conservative
    top-to-bottom order and report uncertainty instead of silently guessing.
    """
    if not blocks:
        return [], False, False

    gutter = _find_column_gutter(blocks, page_width)
    if gutter is None:
        ordered = sorted(blocks, key=lambda b: (b["bbox"][1], b["bbox"][0]))
        return ordered, False, _looks_like_two_columns(blocks, page_width)

    spanning = [b for b in blocks if b["bbox"][0] < gutter < b["bbox"][2]]
    columns = [b for b in blocks if b not in spanning]

    def order_band(band: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        left = [b for b in band if b["bbox"][2] <= gutter]
        right = [b for b in band if b["bbox"][0] >= gutter]
        # Defensive fallback for malformed/overlapping geometry: place any block
        # by its center while retaining stable top-to-bottom order in each lane.
        ambiguous = [b for b in band if b not in left and b not in right]
        left.extend(b for b in ambiguous if (b["bbox"][0] + b["bbox"][2]) / 2 < gutter)
        right.extend(b for b in ambiguous if (b["bbox"][0] + b["bbox"][2]) / 2 >= gutter)
        key = lambda b: (b["bbox"][1], b["bbox"][0])
        return sorted(left, key=key) + sorted(right, key=key)

    # Merge vertically overlapping spanning blocks into a single visual band.
    spanning.sort(key=lambda b: (b["bbox"][1], b["bbox"][0]))
    groups: List[List[Dict[str, Any]]] = []
    group_bottom = -1.0
    join_gap = max(8.0, page_height * 0.012)
    for block in spanning:
        y0, y1 = block["bbox"][1], block["bbox"][3]
        if not groups or y0 > group_bottom + join_gap:
            groups.append([block])
            group_bottom = y1
        else:
            groups[-1].append(block)
            group_bottom = max(group_bottom, y1)

    ordered: List[Dict[str, Any]] = []
    remaining = list(columns)
    has_ambiguous_overlap = False
    for group in groups:
        group_top = min(b["bbox"][1] for b in group)
        group_bottom = max(b["bbox"][3] for b in group)
        before = [
            b for b in remaining
            if (b["bbox"][1] + b["bbox"][3]) / 2 < group_top
        ]
        ordered.extend(order_band(before))
        ordered.extend(sorted(group, key=lambda b: (b["bbox"][1], b["bbox"][0])))
        remaining = [b for b in remaining if b not in before]

        # Text geometrically overlapping a spanning region is ambiguous. Assign it
        # to the next band unless its center is clearly above the region.
        overlapped = [
            b for b in remaining
            if b["bbox"][1] < group_bottom
            and b["bbox"][3] > group_top
        ]
        if overlapped:
            has_ambiguous_overlap = True
            ordered.extend(order_band(overlapped))
            remaining = [b for b in remaining if b not in overlapped]

    ordered.extend(order_band(remaining))
    return ordered, True, has_ambiguous_overlap


RE_TOC_HEADER = re.compile(
    r"^\s*(?:table\s+of\s+)?(?:contents|brief\s+contents|table\s+des\s+mati[eè]res|inhaltsverzeichnis|outline)\b",
    re.IGNORECASE,
)
RE_LINE_END_PAGE_NUM = re.compile(
    r"(?:(?:\.|\s|_|-){2,}|\s{2,}|\t+)(\d+|[ivxlcdm]+)\s*$",
    re.IGNORECASE,
)
RE_TRAILING_NUMBER = re.compile(
    r"\b(\d+|[ivxlcdm]+)\s*$",
    re.IGNORECASE,
)
RE_DOT_LEADERS = re.compile(
    r"(?:\.{2,}|(?:\.\s+){2,}|\_{2,}|\-{3,}|\s{4,})\s*(?:\d+|[ivxlcdm]+)?\s*$",
    re.IGNORECASE,
)


def detect_printed_toc_page(
    blocks: List[Dict[str, Any]],
    page_width: float,
    page_height: float,
    page_num: int,
    total_pages: int,
) -> Tuple[bool, List[Dict[str, Any]]]:
    """
    ISP RAS Dedoc 4-Rule Geometric Heuristic for detecting printed Table of Contents pages:
    - Rule 1 (Header Trigger): Standalone heading matching Contents/Table of Contents/Outline
    - Rule 2 (Line-End Digit Ratio): >= 30% of lines end with an integer/Roman numeral near right margin
    - Rule 3 (Dot/Tab Leader Density): Repeating leader characters (... or ___ or long gaps)
    - Rule 4 (Monotonically Non-Decreasing Sequence): Trailing page numbers form a non-decreasing sequence (>= 3 numbers)

    A page is classified as TOC if it meets >= 2 of these rules (or Rule 1 with >= 2 page-numbered entries).
    Only applies to front matter (first 25% of the book, or first 30 pages).
    """
    if total_pages > 0 and page_num > max(30, int(total_pages * 0.25)):
        return False, []

    all_lines: List[Dict[str, Any]] = []
    for b in blocks:
        for l in b.get("lines", []):
            txt = l.get("text", "").strip()
            if txt:
                all_lines.append(l)

    if not all_lines:
        return False, []

    line_texts = [l["text"].strip() for l in all_lines]

    # Rule 1: Header trigger in the first 4 lines
    rule1_header = False
    for t in line_texts[:4]:
        if RE_TOC_HEADER.search(t):
            rule1_header = True
            break

    # Rule 2: Line-end digit ratio near right margin
    digit_lines_count = 0
    candidate_numbers: List[int] = []
    toc_entries: List[Dict[str, Any]] = []

    for l in all_lines:
        txt = l["text"].strip()
        x1 = l["bbox"][2] if "bbox" in l and len(l["bbox"]) >= 4 else page_width
        m_num = RE_TRAILING_NUMBER.search(txt)
        if m_num and (x1 >= page_width * 0.58 or len(all_lines) <= 15):
            digit_lines_count += 1
            num_str = m_num.group(1)
            if num_str.isdigit():
                candidate_numbers.append(int(num_str))

        # Extract potential TOC entry
        m_entry = RE_LINE_END_PAGE_NUM.search(txt)
        if m_entry:
            raw_title = txt[:m_entry.start(0)].strip()
            clean_title = re.sub(r"[\.\-_\s]+$", "", raw_title).strip()
            page_val = m_entry.group(1)
            if clean_title and len(clean_title) >= 2 and page_val.isdigit():
                toc_entries.append({
                    "level": 1,
                    "title": clean_title,
                    "page": int(page_val),
                })
        elif m_num and m_num.group(1).isdigit():
            raw_title = txt[:m_num.start(0)].strip()
            clean_title = re.sub(r"[\.\-_\s]+$", "", raw_title).strip()
            if clean_title and len(clean_title) >= 2:
                toc_entries.append({
                    "level": 1,
                    "title": clean_title,
                    "page": int(m_num.group(1)),
                })

    rule2_digit_ratio = (
        len(all_lines) >= 3 and (digit_lines_count / len(all_lines)) >= 0.30
    )

    # Rule 3: Dot/Tab leader density (>= 2 lines with dot leaders or long spacers)
    leader_count = sum(1 for t in line_texts if RE_DOT_LEADERS.search(t))
    rule3_leaders = leader_count >= 2

    # Rule 4: Monotonically non-decreasing page sequence
    rule4_increasing = False
    if len(candidate_numbers) >= 3:
        non_decreasing_steps = sum(
            1 for i in range(len(candidate_numbers) - 1)
            if candidate_numbers[i + 1] >= candidate_numbers[i]
        )
        if non_decreasing_steps >= max(2, int((len(candidate_numbers) - 1) * 0.75)):
            rule4_increasing = True

    chapter_matches = sum(1 for t in line_texts if re.match(r"^(?:chapter|section|part)\s+\d+", t, re.IGNORECASE))
    if chapter_matches >= 3:
        rule1_header = True

    matched_rules = sum([rule1_header, rule2_digit_ratio, rule3_leaders, rule4_increasing])
    is_toc = matched_rules >= 2 or (rule1_header and len(toc_entries) >= 2)

    return is_toc, toc_entries if is_toc else []


def extract_document_structure(
    doc: pymupdf.Document,
    ledger: Optional[RepairLedger] = None,
    progress_callback: Optional[Callable[[int, int], None]] = None,
    page_blocks_overrides: Optional[Dict[int, List[Dict[str, Any]]]] = None,
) -> Dict[str, Any]:
    """
    Executes Stages 1, 3, 4, and 5:
    - Extracts raw dict spans (Stage 1)
    - Determines modal body font size and builds vocabulary
    - Detects column gutters and reading order (Stage 3)
    - Types blocks with outline cross-checks and protected headings (Stage 4)
    - Reconstructs paragraphs across line and page breaks (Stage 5)
    """
    if ledger is None:
        ledger = RepairLedger()

    total_pages = doc.page_count
    raw_spans_record: List[Dict[str, Any]] = []

    # 1. Fetch document outline (TOC) for cross-checking headings
    outline_titles: Set[str] = set()
    try:
        raw_toc = doc.get_toc()
        for item in raw_toc:
            if len(item) >= 2 and item[1]:
                norm_title = re.sub(r"[^\w\s]", "", item[1]).lower().strip()
                if norm_title:
                    outline_titles.add(norm_title)
    except Exception:
        outline_titles = set()

    # 2. Collect all raw spans, font size statistics, and document vocabulary
    font_char_counts: Counter = Counter()
    document_words: Set[str] = set()
    page_raw_blocks: List[List[Dict[str, Any]]] = []

    for page_idx in range(total_pages):
        page = doc[page_idx]
        page_override = (page_blocks_overrides or {}).get(page_idx)
        page_dict = (
            {"blocks": page_override}
            if page_override is not None
            else page.get_text("dict")
        )
        p_blocks: List[Dict[str, Any]] = []

        for b in page_dict.get("blocks", []):
            if b.get("type") == 0:  # Text block
                lines_data: List[Dict[str, Any]] = []
                for l in b.get("lines", []):
                    spans_data: List[Dict[str, Any]] = []
                    for s in l.get("spans", []):
                        txt = s.get("text", "")
                        if txt:
                            # Apply Stage 2 character repair
                            repaired_txt, _ = repair_text(txt, page=page_idx + 1, ledger=ledger)
                            s_clean = dict(s)
                            s_clean["text"] = repaired_txt
                            s_clean["raw_text"] = txt
                            spans_data.append(s_clean)

                            # Statistics
                            sz = round(float(s.get("size", 10.0)), 1)
                            font_char_counts[sz] += len(repaired_txt.strip())

                            # Vocabulary
                            words = re.findall(r"\b[A-Za-z]+\b", repaired_txt.lower())
                            document_words.update(words)

                    if spans_data:
                        line_text = "".join(s["text"] for s in spans_data)
                        stripped_l = line_text.strip()
                        pw = page.rect.width
                        lx0, ly0, lx1, ly1 = l["bbox"]
                        # Gate H: Strip standalone margin line numbers in outer 12% margins (peer review / drafts)
                        if re.match(r"^\d{1,4}$", stripped_l) and (lx1 < 0.12 * pw or lx0 > 0.88 * pw):
                            continue

                        lines_data.append({
                            "bbox": l["bbox"],
                            "text": line_text,
                            "spans": spans_data,
                        })

                if lines_data:
                    p_blocks.append({
                        "bbox": b["bbox"],
                        "lines": lines_data,
                        "page": page_idx + 1,
                        "page_width": page.rect.width,
                        "page_height": page.rect.height,
                    })

        page_raw_blocks.append(p_blocks)
        if progress_callback:
            progress_callback(page_idx + 1, total_pages)

    # Calculate modal body font size
    body_size = 11.0
    if font_char_counts:
        body_size = font_char_counts.most_common(1)[0][0]

    # 3. Stage 3: Reading Order & Column Gutter Detection
    page_ordered_blocks: List[List[Dict[str, Any]]] = []
    is_multi_column_doc = False
    multi_col_page_count = 0
    uncertain_order_page_count = 0

    for page_idx, p_blocks in enumerate(page_raw_blocks):
        if not p_blocks:
            page_ordered_blocks.append([])
            continue

        pw = p_blocks[0]["page_width"]
        ph = p_blocks[0]["page_height"]
        ordered, is_two_column, uncertain_order = _order_page_blocks(p_blocks, pw, ph)
        if is_two_column:
            multi_col_page_count += 1
        if uncertain_order:
            uncertain_order_page_count += 1
        page_ordered_blocks.append(ordered)

    if total_pages > 0 and (multi_col_page_count / total_pages) >= 0.3:
        is_multi_column_doc = True

    # 4. Stage 4: Detect Running Headers / Footers and Printed TOC Pages
    # Look in top 12% and bottom 12% bands, separate odd vs even pages
    odd_margin_signatures: Dict[str, Set[int]] = {}
    even_margin_signatures: Dict[str, Set[int]] = {}
    all_printed_toc_entries: List[Dict[str, Any]] = []
    toc_pages_set: Set[int] = set()

    for page_idx, p_blocks in enumerate(page_ordered_blocks):
        page_num = page_idx + 1
        is_odd = (page_num % 2 == 1)
        target_dict = odd_margin_signatures if is_odd else even_margin_signatures

        pw = p_blocks[0]["page_width"] if p_blocks else 600.0
        ph = p_blocks[0]["page_height"] if p_blocks else 800.0
        is_toc, page_toc_entries = detect_printed_toc_page(p_blocks, pw, ph, page_num, total_pages)
        if is_toc:
            toc_pages_set.add(page_num)
            all_printed_toc_entries.extend(page_toc_entries)

        for b in p_blocks:
            ph = b["page_height"]
            y0, y1 = b["bbox"][1], b["bbox"][3]
            in_header_band = y1 < 0.12 * ph
            in_footer_band = y0 > 0.88 * ph

            if in_header_band or in_footer_band:
                full_text = " ".join(l["text"] for l in b["lines"]).strip()
                # Normalize digits to #
                sig = RE_DIGITS.sub("#", full_text).lower().strip()
                if sig:
                    target_dict.setdefault(sig, set()).add(page_num)

    # Threshold for recurring headers/footers: >= 25% of odd or even pages
    header_threshold_odd = max(2, int((total_pages / 2) * 0.25))
    header_threshold_even = max(2, int((total_pages / 2) * 0.25))

    # 5. Type Every Block & Filter Headers
    typed_blocks_by_page: List[List[Dict[str, Any]]] = []

    for page_idx, p_blocks in enumerate(page_ordered_blocks):
        page_num = page_idx + 1
        is_odd = (page_num % 2 == 1)
        active_signatures = odd_margin_signatures if is_odd else even_margin_signatures
        threshold = header_threshold_odd if is_odd else header_threshold_even

        # Check if page is a Table of Contents / Front Matter page
        is_toc_page = page_num in toc_pages_set
        page_all_texts = [" ".join(l["text"] for l in b["lines"]).strip() for b in p_blocks]
        if not is_toc_page:
            has_toc_header = any(re.search(r"^(?:table\s+of\s+)?contents\b", t, re.IGNORECASE) for t in page_all_texts[:3])
            chapter_matches_on_page = sum(1 for t in page_all_texts if re.match(r"^(?:chapter|section|part)\s+\d+", t, re.IGNORECASE))
            is_toc_page = has_toc_header or (chapter_matches_on_page >= 3)

        # Edge AI Front-Matter & Noise Page Detection (Gopher grammar density + FastEmbed ONNX)
        page_full_raw = "\n".join(page_all_texts)
        is_front_matter_page = is_front_matter_or_noise_page(page_idx, total_pages, page_full_raw)

        # Back-Matter Page Detection (last 20% of pages containing Index, Bibliography, etc.)
        is_back_matter_page = False
        if total_pages > 10 and page_idx >= int(total_pages * 0.80):
            has_back_matter_header = any(
                re.search(r"^(?:general\s+)?index\b|^(?:selected\s+)?bibliography\b|^works\s+cited\b|^(?:end)?notes\b", t, re.IGNORECASE)
                for t in page_all_texts[:3]
            )
            if has_back_matter_header:
                is_back_matter_page = True

        typed_page: List[Dict[str, Any]] = []

        for b in p_blocks:
            ph = b["page_height"]
            pw = b["page_width"]
            lines = b["lines"]
            block_text = " ".join(l["text"] for l in lines).strip()
            if not block_text:
                continue

            first_span = lines[0]["spans"][0] if lines and lines[0]["spans"] else None
            font_size = float(first_span.get("size", body_size)) if first_span else body_size
            font_flags = int(first_span.get("flags", 0)) if first_span else 0
            is_bold = bool(font_flags & 16) or ("bold" in str(first_span.get("font", "")).lower())

            # Outline matching check (Highest confidence heading check)
            norm_b_text = re.sub(r"[^\w\s]", "", block_text).lower().strip()
            matches_outline = norm_b_text in outline_titles

            # Check running header/footer
            y0, y1 = b["bbox"][1], b["bbox"][3]
            in_header_band = y1 < 0.12 * ph
            in_footer_band = y0 > 0.88 * ph

            is_running = False
            if (in_header_band or in_footer_band) and not matches_outline:
                # Page number alone check
                if re.match(r"^(?:page\s+)?(?:\d+|[ivxlcdm]+)$", block_text, re.IGNORECASE):
                    is_running = True
                else:
                    sig = RE_DIGITS.sub("#", block_text).lower().strip()
                    if sig and len(active_signatures.get(sig, set())) >= threshold:
                        is_running = True

            if is_running:
                # Mark as running header/footer and drop from body text
                continue

            # Classify Block Type
            words = block_text.split()
            word_count = len(words)

            if is_toc_page:
                b_type = BlockType.CONTENTS_ENTRY
            elif is_front_matter_page:
                b_type = BlockType.FRONT_MATTER
            elif is_back_matter_page:
                b_type = BlockType.BACK_MATTER
            elif matches_outline or (
                (font_size >= 1.15 * body_size or (is_bold and font_size >= body_size))
                and word_count <= 14
                and not block_text.endswith((".", ",", ";"))
            ) or (
                re.match(r"^(?:Chapter|Section|Part)\s+\d+", block_text, re.IGNORECASE)
                and word_count <= 10
            ):
                b_type = BlockType.HEADING
            elif (
                (y0 > 0.65 * ph and (font_size <= 0.88 * body_size or font_size < body_size - 0.75))
                or (y0 > 0.60 * ph and re.match(r"^(\d{1,2}\.|\(\d{1,2}\)|\[\d{1,2}\]|[*†‡§])\s+", block_text))
            ):
                b_type = BlockType.FOOTNOTE
            elif RE_CONTENTS_LEADER.search(block_text):
                b_type = BlockType.CONTENTS_ENTRY
            elif RE_LIST_BULLET.match(block_text):
                b_type = BlockType.LIST_ITEM
            else:
                b_type = BlockType.PARAGRAPH

            typed_page.append({
                "type": b_type,
                "bbox": b["bbox"],
                "lines": lines,
                "text": block_text,
                "font_size": font_size,
                "is_bold": is_bold,
                "page": page_num,
                "page_width": pw,
                "page_height": ph,
            })

        typed_blocks_by_page.append(typed_page)

    # 6. Stage 5: Rebuild Paragraphs (Line by Line and Block by Block)
    reconstructed_blocks: List[Dict[str, Any]] = []

    for page_blocks in typed_blocks_by_page:
        for b in page_blocks:
            b_type = b["type"]
            lines = b["lines"]

            # Rebuild lines inside the block
            reconstructed_lines: List[str] = []
            for li, l in enumerate(lines):
                line_str = l["text"].strip()
                if not line_str:
                    continue

                if reconstructed_lines:
                    prev_line = reconstructed_lines[-1]
                    # Check hyphenation at line end
                    hyphen_m = RE_LINE_HYPHEN.search(prev_line)
                    if hyphen_m and line_str and line_str[0].islower():
                        prefix = hyphen_m.group(1)
                        if prefix.lower() in COMPOUND_PREFIXES:
                            reconstructed_lines[-1] = prev_line[:hyphen_m.start()] + prefix + "-" + line_str
                            ledger.add(b["page"], 0, f"{prefix}-", f"{prefix}-", "compound_hyphen_preserved")
                        else:
                            reconstructed_lines[-1] = prev_line[:hyphen_m.start()] + prefix + line_str
                            ledger.add(b["page"], 0, f"{prefix}-", prefix, "hyphen_joined_universal")
                    else:
                        reconstructed_lines[-1] = prev_line + " " + line_str
                else:
                    reconstructed_lines.append(line_str)

            cleaned_block_text = " ".join(reconstructed_lines).strip()
            # Collapse multiple spaces
            cleaned_block_text = re.sub(r"[ \t]+", " ", cleaned_block_text)
            # Universal Self-Healing Prose Normalization (hygiene, dehyphenation, footnote callouts, fused kerning)
            cleaned_block_text = self_heal_prose_text(cleaned_block_text)

            # Drop or mark noise blocks with fewer than 3 words (unless valid heading)
            alpha_words = re.findall(r"\b[A-Za-z]{2,}\b", cleaned_block_text)
            if not cleaned_block_text or (b_type not in (BlockType.HEADING, BlockType.CONTENTS_ENTRY) and len(alpha_words) < 3):
                b_type = BlockType.NOISE

            if cleaned_block_text:
                reconstructed_blocks.append({
                    "type": b_type,
                    "text": cleaned_block_text,
                    "page_start": b["page"],
                    "page_end": b["page"],
                    "bbox": b["bbox"],
                    "font_size": b["font_size"],
                    "is_bold": b["is_bold"],
                })

    # 6b. Drop-cap Merger: single uppercase letter block fused with subsequent continuation text
    drop_cap_merged: List[Dict[str, Any]] = []
    d_idx = 0
    while d_idx < len(reconstructed_blocks):
        curr_b = reconstructed_blocks[d_idx]
        if (
            len(curr_b["text"]) == 1
            and curr_b["text"].isupper()
            and d_idx + 1 < len(reconstructed_blocks)
        ):
            next_b = reconstructed_blocks[d_idx + 1]
            if next_b["page_start"] == curr_b["page_end"]:
                if next_b["text"] and next_b["text"][0].islower():
                    next_b["text"] = curr_b["text"] + next_b["text"]
                    d_idx += 1
                    continue
                elif next_b["text"]:
                    next_b["text"] = curr_b["text"] + " " + next_b["text"].lstrip()
                    d_idx += 1
                    continue
        drop_cap_merged.append(curr_b)
        d_idx += 1

    # 7. Merge multi-line headings (e.g. "CHAPTER 1" followed immediately by "Don't Try")
    fused_blocks: List[Dict[str, Any]] = []
    f_idx = 0
    while f_idx < len(drop_cap_merged):
        curr_b = drop_cap_merged[f_idx]
        if curr_b["type"] == BlockType.HEADING and f_idx + 1 < len(drop_cap_merged):
            next_b = drop_cap_merged[f_idx + 1]
            if (
                next_b["page_start"] == curr_b["page_end"]
                and (
                    next_b["type"] == BlockType.HEADING
                    or (next_b["font_size"] >= curr_b["font_size"] * 0.85 and len(next_b["text"].split()) <= 12)
                )
                and not next_b["text"].endswith((".", ";"))
                and len(curr_b["text"].split()) <= 5
            ):
                curr_b["text"] = f"{curr_b['text']}: {next_b['text']}"
                f_idx += 2
                fused_blocks.append(curr_b)
                continue
        fused_blocks.append(curr_b)
        f_idx += 1

    # 8. Cross-page Paragraph Continuation
    # If the last block of page N does not end with terminal punctuation
    # and first block of page N+1 is a paragraph starting with lowercase (or ending with hyphen), merge them!
    merged_units: List[Dict[str, Any]] = []
    for b in fused_blocks:
        if merged_units:
            prev = merged_units[-1]
            if (
                prev["type"] == BlockType.PARAGRAPH
                and b["type"] == BlockType.PARAGRAPH
                and b["page_start"] > prev["page_end"]
                and prev["text"]
                and not RE_PUNCTUATION_END.search(prev["text"])
                and b["text"]
                and (b["text"][0].islower() or prev["text"].endswith("-"))
            ):
                if prev["text"].endswith("-"):
                    prefix = prev["text"].split()[-1].rstrip("-")
                    if prefix.lower() in COMPOUND_PREFIXES:
                        prev["text"] = prev["text"] + b["text"]
                    else:
                        prev["text"] = prev["text"][:-1] + b["text"]
                else:
                    prev["text"] = f"{prev['text']} {b['text']}"
                prev["page_end"] = b["page_end"]
                ledger.add(b["page_start"], 0, "", " ", "cross_page_paragraph_merge")
                continue

        merged_units.append(b)

    return {
        "body_size": body_size,
        "is_multi_column": is_multi_column_doc,
        "uncertain_reading_order": uncertain_order_page_count > 0,
        "units": merged_units,
        "document_words_count": len(document_words),
        "printed_toc": all_printed_toc_entries,
    }
