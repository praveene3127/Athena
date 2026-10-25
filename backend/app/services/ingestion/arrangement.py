"""
Intelligent Reading Arrangement Layer (Asian + Global Research Invariant).

Operates between block extraction and final lossless chunk creation:
1. Classifies blocks: heading, paragraph, quote, list, table, caption, formula, footnote
2. Detects reading direction and script constraints (Japanese/Chinese vertical vs horizontal)
3. Analyzes syntactic and semantic relationships: continues, introduces, explains, gives_example, starts_new_section
4. Builds reading-order graph with confidence and explicit rationale
5. Selects safe thought boundaries without arbitrary word-count fragmentation
6. Emits exact [start_offset, end_offset] slices into canonical_text (zero generated tokens)
"""

import re
from typing import Any, Dict, List, Optional, Tuple


# Classification Taxonomy
class UnitType:
    HEADING = "heading"
    PARAGRAPH = "paragraph"
    QUOTE = "quote"
    LIST_ITEM = "list"
    TABLE = "table"
    CAPTION = "caption"
    FORMULA = "formula"
    FOOTNOTE = "footnote"
    CONTENTS_ENTRY = "contents_entry"


# Relationship Taxonomy
class RelationType:
    CONTINUES = "continues"
    INTRODUCES = "introduces"
    EXPLAINS = "explains"
    GIVES_EXAMPLE = "gives_example"
    STARTS_NEW_SECTION = "starts_new_section"
    CAPTION_OF = "caption_of"
    ITEM_OF = "item_of"
    INDEPENDENT = "independent"


# Discourse & continuity markers
RE_EXAMPLE_START = re.compile(
    r"^(for example|for instance|specifically|namely|to illustrate|such as|in particular|consider, for example)\b",
    re.IGNORECASE,
)
RE_EXPLANATION_MARKERS = re.compile(
    r"\b(is defined as|refers to|that is to say|in other words|means that|corresponds to)\b",
    re.IGNORECASE,
)
RE_ELABORATION_START = re.compile(
    r"^(furthermore|moreover|in addition|additionally|what is more|similarly)\b",
    re.IGNORECASE,
)
RE_CONTRAST_START = re.compile(
    r"^(however|nevertheless|nonetheless|on the other hand|conversely|in contrast)\b",
    re.IGNORECASE,
)
RE_LIST_START = re.compile(
    r"^([•*\-–—▪▫◦]|\d+[\.\)]|\([a-zA-Z0-9]+\))\s+"
)
RE_QUOTE_START = re.compile(r"^[\"“'「『]")
RE_FORMULA_CANDIDATE = re.compile(r"[=≠≈≤≥∑∫√α-ωΑ-Ω]{2,}|\\\[.*?\\\]")
RE_FOOTNOTE_START = re.compile(r"^(\[\d+\]|\d+[\.\)])\s*")


def detect_script_and_direction(text: str, bbox: Optional[Tuple[float, float, float, float]] = None) -> Dict[str, Any]:
    """
    Detects script characteristics and layout direction (§1.2 in Asian Research Plan):
    - Japanese (Kanji, Hiragana, Katakana)
    - Chinese (Hanzi)
    - Korean (Hangul)
    - Latin/Western
    - Vertical vs Horizontal aspect ratio cues (height > 2 * width indicates vertical column)
    """
    kanji_count = len(re.findall(r"[\u4e00-\u9fff]", text))
    hiragana_count = len(re.findall(r"[\u3040-\u309f]", text))
    katakana_count = len(re.findall(r"[\u30a0-\u30ff]", text))
    hangul_count = len(re.findall(r"[\uac00-\ud7af]", text))
    latin_count = len(re.findall(r"[A-Za-z]", text))

    is_japanese = (hiragana_count + katakana_count > 0)
    is_korean = (hangul_count > 0)
    is_chinese = (kanji_count > 0 and not is_japanese)

    is_vertical = False
    if bbox:
        x0, y0, x1, y1 = bbox
        width = x1 - x0
        height = y1 - y0
        if height > 2.2 * width and (is_japanese or is_chinese):
            is_vertical = True

    return {
        "is_japanese": is_japanese,
        "is_chinese": is_chinese,
        "is_korean": is_korean,
        "is_cjk": is_japanese or is_chinese or is_korean,
        "is_vertical": is_vertical,
        "direction": "rtl_v" if is_vertical else "ltr_h",
    }


def classify_block(
    text: str,
    font_size: Optional[float] = None,
    modal_body_size: Optional[float] = None,
    is_bold: bool = False,
    bbox: Optional[Tuple[float, float, float, float]] = None,
) -> str:
    """
    Classifies an extracted unit into the fine-grained reading taxonomy (§1.1, §3.2).
    """
    stripped = text.strip()
    if not stripped:
        return UnitType.PARAGRAPH

    words = stripped.split()
    word_count = len(words)

    # 1. Footnote check
    if RE_FOOTNOTE_START.match(stripped) and word_count < 40 and font_size and modal_body_size:
        if font_size < 0.85 * modal_body_size:
            return UnitType.FOOTNOTE

    # 2. Formula check
    if RE_FORMULA_CANDIDATE.search(stripped) and word_count < 25:
        return UnitType.FORMULA

    # 3. Caption check (starts with Figure, Table, Fig., etc.)
    if re.match(r"^(figure|fig\.|table|chart|diagram|photo|plate)\s+\d+[:.]?", stripped, re.IGNORECASE):
        return UnitType.CAPTION

    # 4. Heading check
    is_heading_typography = False
    if modal_body_size and font_size:
        if font_size >= 1.18 * modal_body_size or (is_bold and font_size >= 1.05 * modal_body_size):
            is_heading_typography = True

    if (
        (is_heading_typography or word_count <= 12)
        and not stripped.endswith((".", ",", ";"))
        and (stripped[0].isupper() or stripped[0].isdigit() or not stripped[0].isalnum())
        and word_count <= 15
    ):
        return UnitType.HEADING

    # 5. List item check
    if RE_LIST_START.match(stripped):
        return UnitType.LIST_ITEM

    # 6. Quote check
    if RE_QUOTE_START.match(stripped) and (stripped.endswith(("\"", "”", "'", "」", "』")) or word_count < 60):
        return UnitType.QUOTE

    # Default to standard body paragraph
    return UnitType.PARAGRAPH


def analyze_block_relation(
    prev_block: Dict[str, Any],
    curr_block: Dict[str, Any],
) -> Dict[str, Any]:
    """
    Understands semantic and structural relationships between two neighboring blocks:
    Returns {
        "relation": str,
        "decision": "keep_together" | "allow_split",
        "confidence": float,
        "reason": str
    }
    """
    prev_text = prev_block.get("text", "").strip()
    curr_text = curr_block.get("text", "").strip()
    prev_type = prev_block.get("type", UnitType.PARAGRAPH)
    curr_type = curr_block.get("type", UnitType.PARAGRAPH)

    # 0. Table of Contents grouping
    if prev_type == UnitType.CONTENTS_ENTRY and curr_type == UnitType.CONTENTS_ENTRY:
        return {
            "relation": RelationType.ITEM_OF,
            "decision": "keep_together",
            "confidence": 0.99,
            "reason": "Consecutive Table of Contents lines belong together in the TOC card.",
        }

    if prev_type == UnitType.CONTENTS_ENTRY and curr_type != UnitType.CONTENTS_ENTRY:
        return {
            "relation": RelationType.STARTS_NEW_SECTION,
            "decision": "allow_split",
            "confidence": 0.99,
            "reason": "Transition from Table of Contents to book body content.",
        }

    # 1. Heading introduces following content
    if prev_type == UnitType.HEADING:
        return {
            "relation": RelationType.INTRODUCES,
            "decision": "keep_together",
            "confidence": 0.95,
            "reason": "Section heading directly introduces following body paragraph.",
        }

    # 2. Next block starts a new section
    if curr_type == UnitType.HEADING:
        return {
            "relation": RelationType.STARTS_NEW_SECTION,
            "decision": "allow_split",
            "confidence": 0.99,
            "reason": "Incoming block is a new heading; establishes section boundary.",
        }

    # 3. Caption belongs with preceding table or figure
    if curr_type == UnitType.CAPTION:
        return {
            "relation": RelationType.CAPTION_OF,
            "decision": "keep_together",
            "confidence": 0.92,
            "reason": "Caption belongs with preceding visual or tabular unit.",
        }

    # 4. Syntactic continuation (prev does not end with terminal punctuation or ends with colon/comma)
    if prev_text and not prev_text.endswith((".", "!", "?", "。", "！", "？")):
        if prev_text.endswith((":", "：")):
            return {
                "relation": RelationType.INTRODUCES,
                "decision": "keep_together",
                "confidence": 0.94,
                "reason": "Preceding block ends with a colon introducing the next statement.",
            }
        if prev_text.endswith((",", ";", "—", "-")):
            return {
                "relation": RelationType.CONTINUES,
                "decision": "keep_together",
                "confidence": 0.96,
                "reason": "Preceding block ends with a continuation punctuation mark.",
            }
        if curr_text and (curr_text[0].islower() or curr_text.startswith(("and ", "or ", "but "))):
            return {
                "relation": RelationType.CONTINUES,
                "decision": "keep_together",
                "confidence": 0.98,
                "reason": "Grammatical lowercase continuation across block boundary.",
            }

    # 5. Discourse: Gives example
    if RE_EXAMPLE_START.search(curr_text):
        prev_words = len(prev_text.split())
        curr_words = len(curr_text.split())
        if prev_words + curr_words <= 180:
            return {
                "relation": RelationType.GIVES_EXAMPLE,
                "decision": "keep_together",
                "confidence": 0.91,
                "reason": "Paragraph provides a direct example for the concept introduced immediately above.",
            }

    # 6. Discourse: Definition and immediate explanation
    if RE_EXPLANATION_MARKERS.search(prev_text) or RE_EXPLANATION_MARKERS.search(curr_text):
        prev_words = len(prev_text.split())
        curr_words = len(curr_text.split())
        if prev_words + curr_words <= 170:
            return {
                "relation": RelationType.EXPLAINS,
                "decision": "keep_together",
                "confidence": 0.88,
                "reason": "Definition and explanatory text belong together as an atomic conceptual beat.",
            }

    # 7. Consecutive List items
    if prev_type == UnitType.LIST_ITEM and curr_type == UnitType.LIST_ITEM:
        prev_words = len(prev_text.split())
        curr_words = len(curr_text.split())
        if prev_words + curr_words <= 150:
            return {
                "relation": RelationType.ITEM_OF,
                "decision": "keep_together",
                "confidence": 0.89,
                "reason": "Consecutive list items form a cohesive list block.",
            }

    # Default: Independent full thought
    return {
        "relation": RelationType.INDEPENDENT,
        "decision": "allow_split",
        "confidence": 0.80,
        "reason": "Self-contained semantic thought; safe boundary for card transition.",
    }


def build_reading_order_graph(
    blocks: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """
    Constructs a directed reading-order graph with typed edges, confidence scores,
    and thought-boundary recommendations.
    """
    nodes = []
    edges = []

    for i, b in enumerate(blocks):
        b_id = f"blk_{i:04d}"
        nodes.append({
            "id": b_id,
            "index": i,
            "type": b.get("type", UnitType.PARAGRAPH),
            "text": b.get("text", ""),
            "start": b.get("start", 0),
            "end": b.get("end", 0),
            "page_start": b.get("page_start", 1),
            "page_end": b.get("page_end", 1),
            "word_count": len(b.get("text", "").split()),
        })

    for i in range(len(nodes) - 1):
        prev_node = nodes[i]
        curr_node = nodes[i + 1]
        rel_info = analyze_block_relation(prev_node, curr_node)
        edges.append({
            "from_id": prev_node["id"],
            "to_id": curr_node["id"],
            "relation": rel_info["relation"],
            "decision": rel_info["decision"],
            "confidence": rel_info["confidence"],
            "reason": rel_info["reason"],
        })

    return {
        "nodes": nodes,
        "edges": edges,
    }


def plan_reading_card_boundaries(
    graph: Dict[str, Any],
    max_comfortable_words: int = 180,
    min_standalone_words: int = 25,
) -> List[Dict[str, Any]]:
    """
    Selects final card boundaries from the reading-order graph.
    - Honors 'keep_together' edges to keep concepts, definitions, and examples intact.
    - Honors 'starts_new_section' and 'allow_split' at natural thought boundaries.
    - Merges tiny fragments (< 15 words) into adjacent cards so 1-word cards are never emitted.
    - Groups Table of Contents into a single cohesive overview card.
    - Returns list of groups with exact canonical character ranges: [{'start': int, 'end': int, ...}]
    """
    nodes = graph["nodes"]
    edges = graph["edges"]
    if not nodes:
        return []

    # Map edges by from_id
    edge_map = {e["from_id"]: e for e in edges}

    arranged_cards: List[Dict[str, Any]] = []
    current_nodes: List[Dict[str, Any]] = []
    current_words = 0
    current_section_title: Optional[str] = None

    def flush_card():
        nonlocal current_nodes, current_words, current_section_title
        if not current_nodes:
            return

        first_node = current_nodes[0]
        last_node = current_nodes[-1]

        # Guard: Never emit a tiny fragment (< 15 words) as an isolated card
        if current_words < 15 and arranged_cards:
            prev_card = arranged_cards[-1]
            prev_card["end"] = last_node["end"]
            prev_card["node_count"] += len(current_nodes)
            prev_card["word_count"] += current_words
            current_nodes = []
            current_words = 0
            return

        # Determine section title (if leading node was heading or inherited)
        section = current_section_title
        if first_node["type"] == UnitType.HEADING and not section:
            section = first_node["text"].strip()
        elif first_node["type"] == UnitType.CONTENTS_ENTRY:
            section = "Table of Contents"

        arranged_cards.append({
            "start": first_node["start"],
            "end": last_node["end"],
            "node_count": len(current_nodes),
            "primary_type": first_node["type"] if len(current_nodes) == 1 else "compound",
            "section_title": section,
            "word_count": current_words,
            "reason": "Complete semantic thought unit assembled from arrangement graph",
        })

        current_nodes = []
        current_words = 0

    for i, node in enumerate(nodes):
        node_words = node["word_count"]
        node_type = node["type"]

        if node_type == UnitType.HEADING:
            current_section_title = node["text"].strip()
        elif node_type == UnitType.CONTENTS_ENTRY:
            if not current_section_title or current_section_title != "Table of Contents":
                if current_nodes:
                    flush_card()
                current_section_title = "Table of Contents"

        # Check relation from previous node
        if current_nodes:
            prev_node = current_nodes[-1]
            edge = edge_map.get(prev_node["id"])
            decision = edge["decision"] if edge else "allow_split"
            total_projected_words = current_words + node_words

            # 1. Hard transition from TOC to Body content
            if prev_node["type"] == UnitType.CONTENTS_ENTRY and node_type != UnitType.CONTENTS_ENTRY:
                flush_card()
                current_section_title = node["text"].strip() if node_type == UnitType.HEADING else None
                current_nodes.append(node)
                current_words += node_words
                continue

            # 2. Hard boundary trigger: incoming block is a new heading section
            if node_type == UnitType.HEADING:
                if current_words >= 15:
                    flush_card()
                current_section_title = node["text"].strip()
                current_nodes.append(node)
                current_words += node_words
                continue

            # 3. Edge allows split AND accumulated enough words
            if decision == "allow_split":
                if current_words >= min_standalone_words or total_projected_words > max_comfortable_words:
                    flush_card()
                    current_nodes.append(node)
                    current_words += node_words
                    continue

            # 4. Edge is keep_together, but length is excessively long (> 220 words)
            if decision == "keep_together" and total_projected_words > 220:
                flush_card()
                current_nodes.append(node)
                current_words += node_words
                continue

        current_nodes.append(node)
        current_words += node_words

    flush_card()
    return arranged_cards
