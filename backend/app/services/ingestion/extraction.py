import json
import logging
from pathlib import Path
import re
from typing import Any, Callable, Dict, List, Optional
import pymupdf

from app.config import RAW_DIR, UPLOADS_DIR
from app.errors import AppException
from app.services.normalize import normalize_document_blocks
from app.services.repairs import RepairLedger
from app.services.triage import triage_document
from app.services.blocks import extract_document_structure
from app.services.canonical import assemble_canonical_text
from app.services.edge_ai import extract_clean_book_title, extract_document_telemetry

MAGIC_PDF_HEADER = b"%PDF-"
MAGIC_ZIP_HEADER = b"PK\x03\x04"
logger = logging.getLogger(__name__)
_rapid_ocr_engine = None


def get_document_file_path(doc_id: str) -> Path:
    """Finds the stored document file (.pdf or .epub) on disk for a given document ID."""
    for ext in (".pdf", ".epub"):
        p = UPLOADS_DIR / f"{doc_id}{ext}"
        if p.exists():
            return p
    return UPLOADS_DIR / f"{doc_id}.pdf"



def _ocr_blocks_for_page(page: pymupdf.Page, engine: Any) -> List[Dict[str, Any]]:
    """Run bundled OCR and convert detected lines to the extractor's block format."""
    import numpy as np

    rect = page.rect
    dpi = 180
    estimated_pixels = (rect.width * dpi / 72) * (rect.height * dpi / 72)
    if estimated_pixels > 6_000_000:
        dpi = max(72, int(dpi * (6_000_000 / estimated_pixels) ** 0.5))

    pixmap = page.get_pixmap(dpi=dpi, alpha=False)
    image = np.frombuffer(pixmap.samples, dtype=np.uint8).reshape(
        pixmap.height, pixmap.width, pixmap.n
    )
    result = engine(image)
    if result is None or not result.txts:
        return []

    scale_x = rect.width / pixmap.width
    scale_y = rect.height / pixmap.height
    lines = []
    for quad, text, score in zip(result.boxes, result.txts, result.scores):
        text = text.strip()
        if not text:
            continue
        x0 = min(float(point[0]) for point in quad) * scale_x
        y0 = min(float(point[1]) for point in quad) * scale_y
        x1 = max(float(point[0]) for point in quad) * scale_x
        y1 = max(float(point[1]) for point in quad) * scale_y
        lines.append({
            "bbox": (x0, y0, x1, y1),
            "text": text,
            "confidence": float(score),
        })

    lines.sort(key=lambda line: ((line["bbox"][1] + line["bbox"][3]) / 2, line["bbox"][0]))
    groups: List[List[Dict[str, Any]]] = []
    for line in lines:
        if groups:
            previous = groups[-1][-1]
            px0, py0, px1, py1 = previous["bbox"]
            x0, y0, x1, y1 = line["bbox"]
            previous_height = max(1.0, py1 - py0)
            same_column = abs(x0 - px0) <= rect.width * 0.08
            close_lines = y0 - py1 <= previous_height * 1.2
            is_new_list_item = bool(re.match(r"^(?:[•*\-–—]|\d+[.)])\s+", line["text"]))
            if same_column and close_lines and not is_new_list_item:
                groups[-1].append(line)
                continue
        groups.append([line])

    blocks = []
    for group in groups:
        x0 = min(line["bbox"][0] for line in group)
        y0 = min(line["bbox"][1] for line in group)
        x1 = max(line["bbox"][2] for line in group)
        y1 = max(line["bbox"][3] for line in group)
        block_lines = []
        for line in group:
            bx0, by0, bx1, by1 = line["bbox"]
            block_lines.append({
                "bbox": line["bbox"],
                "text": line["text"],
                "spans": [{
                    "text": line["text"],
                    "size": max(6.0, by1 - by0),
                    "flags": 0,
                    "font": "RapidOCR",
                    "confidence": line["confidence"],
                }],
            })
        blocks.append({
            "type": 0,
            "bbox": (x0, y0, x1, y1),
            "lines": block_lines,
        })
    return blocks


def _ocr_suspect_pages(
    doc: pymupdf.Document,
    page_metrics: List[Dict[str, Any]],
    progress_callback: Optional[Callable[[str, int, int], None]],
) -> Dict[int, List[Dict[str, Any]]]:
    """OCR only corrupted-font pages using model files bundled with RapidOCR."""
    global _rapid_ocr_engine
    suspect_pages = [metric["page_number"] - 1 for metric in page_metrics if metric.get("needs_ocr")]
    if not suspect_pages:
        return {}

    try:
        if _rapid_ocr_engine is None:
            from rapidocr import RapidOCR

            _rapid_ocr_engine = RapidOCR()
    except Exception:
        logger.exception("Bundled RapidOCR could not be initialized; retaining extracted PDF text")
        return {}

    ocr_blocks: Dict[int, List[Dict[str, Any]]] = {}
    for index, page_idx in enumerate(suspect_pages, start=1):
        try:
            blocks = _ocr_blocks_for_page(doc[page_idx], _rapid_ocr_engine)
            recognized = " ".join(
                span["text"]
                for block in blocks
                for line in block["lines"]
                for span in line["spans"]
            )
            if len(recognized.strip()) >= 20:
                ocr_blocks[page_idx] = blocks
            else:
                logger.warning("OCR returned too little text for PDF page %d; retaining extracted text", page_idx + 1)
        except Exception:
            logger.exception("OCR failed for PDF page %d; retaining extracted text", page_idx + 1)
        if progress_callback:
            progress_callback("ocr", index, len(suspect_pages))
    return ocr_blocks


def sanitize_filename(filename: str) -> str:
    """Sanitizes filename for display ([^\\w.\\- ] -> _, max 120 chars)."""
    clean = re.sub(r"[^\w.\- ]", "_", filename)
    return clean[:120]


def validate_pdf_file(file_path: Path) -> int:
    """
    Validates uploaded PDF or EPUB file:
    1. First bytes are %PDF- (for PDF) or PK\x03\x04 (for EPUB zip container).
    2. Open with PyMuPDF (readable and not encrypted).
    Returns total page count.
    """
    is_epub = file_path.suffix.lower() == ".epub"
    with open(file_path, "rb") as f:
        header = f.read(1024)
        if is_epub or header.startswith(MAGIC_ZIP_HEADER):
            if not header.startswith(MAGIC_ZIP_HEADER):
                raise AppException("UNSUPPORTED_FILE")
        elif not header.startswith(MAGIC_PDF_HEADER):
            raise AppException("UNSUPPORTED_FILE")

    # Open with PyMuPDF
    try:
        doc = pymupdf.open(file_path)
    except Exception:
        raise AppException("PDF_UNREADABLE")

    try:
        if doc.needs_pass or getattr(doc, "is_encrypted", False):
            raise AppException("PDF_ENCRYPTED")

        page_count = doc.page_count
        return page_count
    finally:
        doc.close()


validate_document_file = validate_pdf_file



def extract_document_content(
    doc_id: str,
    file_path: Path,
    original_filename: str,
    progress_callback: Optional[Callable[[str, int, int], None]] = None,
) -> Dict[str, Any]:
    """
    Performs Stage 0-6 extraction:
    - Stage 0: Triage each page (digital, scanned, hybrid, broken-font)
    - Stage 1: Capture raw text untouched
    - Stage 2: Character repair with logged audit ledger
    - Stage 3: Reading order & gutter detection
    - Stage 4: Type every block against outline & protected headers
    - Stage 5: Rebuild paragraphs with document-vocabulary de-hyphenation
    - Stage 6: Build canonical text and exact offset spans
    """
    doc = pymupdf.open(file_path)
    if doc.needs_pass or getattr(doc, "is_encrypted", False):
        raise AppException("PDF_ENCRYPTED")
    total_pages = doc.page_count
    telemetry_data = extract_document_telemetry(doc)
    raw_text_path = RAW_DIR / f"{doc_id}.txt"
    raw_text_file = None

    try:
        raw_text_file = raw_text_path.open("w", encoding="utf-8")
        # Stage 0: Page Triage
        triage_data = triage_document(
            doc,
            include_pages=True,
            progress_callback=(
                (lambda current, total: progress_callback("triage", current, total))
                if progress_callback
                else None
            ),
        )
        ocr_page_blocks = _ocr_suspect_pages(
            doc, triage_data["pages"], progress_callback
        )

        page_blocks_list: List[List[Dict[str, Any]]] = []
        empty_pages_count = 0
        multi_col_pages_count = 0
        total_words = 0

        for page_idx in range(total_pages):
            page = doc[page_idx]
            w = page.rect.width
            h = page.rect.height

            # Extract sorted text blocks (tuples: x0, y0, x1, y1, text, block_no, block_type)
            if page_idx in ocr_page_blocks:
                text_blocks = [
                    (
                        *block["bbox"],
                        "\n".join(
                            line["text"] for line in block.get("lines", [])
                        ),
                        block_idx,
                        0,
                    )
                    for block_idx, block in enumerate(ocr_page_blocks[page_idx])
                ]
            else:
                raw_blocks = page.get_text("blocks", sort=True)
                text_blocks = [b for b in raw_blocks if len(b) >= 7 and b[6] == 0]

            page_char_count = 0
            page_blocks: List[Dict[str, Any]] = []
            left_col_count = 0
            right_col_count = 0

            for b in text_blocks:
                x0, y0, x1, y1, text = b[0], b[1], b[2], b[3], b[4]
                non_space_chars = len(re.sub(r"\s+", "", text))
                page_char_count += non_space_chars
                total_words += len(text.split())

                block_w = x1 - x0
                if x1 < 0.55 * w and block_w > 0.2 * w:
                    left_col_count += 1
                if x0 > 0.45 * w and block_w > 0.2 * w:
                    right_col_count += 1

                page_blocks.append({
                    "bbox": (x0, y0, x1, y1),
                    "text": text,
                    "page_width": w,
                    "page_height": h,
                })
                raw_text_file.write(text)
                raw_text_file.write("\n")

            # Scanned check per page: < 20 non-space chars is "empty"
            if page_char_count < 20:
                empty_pages_count += 1

            # Multi-column check: left >= 3 and right >= 3
            if left_col_count >= 3 and right_col_count >= 3:
                multi_col_pages_count += 1

            page_blocks_list.append(page_blocks)

        raw_text_file.flush()
        raw_text_file.close()
        raw_text_file = None

        # Scanned PDF validation
        if (total_pages > 0 and empty_pages_count / total_pages > 0.5) or triage_data["is_primarily_scanned"]:
            raise AppException("SCANNED_NOT_SUPPORTED")

        # Total usable words validation
        if total_words < 50:
            raise AppException("NO_TEXT")

        # Initialize audit ledger for Stage 2 character repair
        ledger = RepairLedger()

        # Stages 1, 3, 4, 5: Structured extraction, reading order, typing, and paragraph rebuild
        struct = extract_document_structure(
            doc,
            ledger,
            page_blocks_overrides=ocr_page_blocks,
            progress_callback=(
                (lambda current, total: progress_callback("extracting", current, total))
                if progress_callback
                else None
            ),
        )

        # Multi-column layout warning
        layout_warning: Optional[str] = None
        if struct.get("uncertain_reading_order"):
            layout_warning = "reading_order_uncertain"
        elif (total_pages > 0 and (multi_col_pages_count / total_pages) >= 0.3) or struct.get("is_multi_column"):
            layout_warning = "multi_column"
        suspect_page_count = sum(1 for page in triage_data["pages"] if page.get("needs_ocr"))
        if suspect_page_count and len(ocr_page_blocks) < suspect_page_count:
            layout_warning = "text_extraction_unreliable"

        # Stage 6: Build canonical text and offset spans
        if struct.get("units"):
            canonical_text, spans = assemble_canonical_text(struct["units"])
        else:
            canonical_text, spans = normalize_document_blocks(page_blocks_list, total_pages)

        # Save unmodified raw extracted text to data/raw/{doc_id}.txt
        # Save repair ledger to data/raw/{doc_id}_ledger.json
        ledger_path = RAW_DIR / f"{doc_id}_ledger.json"
        with open(ledger_path, "w", encoding="utf-8") as f:
            json.dump(ledger.to_list(), f, indent=2)

        # Title determination:
        # 1. Edge AI semantic & front-matter title extractor
        front_matter_texts = []
        for p in range(min(15, total_pages)):
            if p < len(page_blocks_list):
                txt = "\n".join(b["text"] for b in page_blocks_list[p])
                if txt.strip():
                    front_matter_texts.append(txt)

        meta_title = (doc.metadata.get("title") or "").strip()
        title = extract_clean_book_title(meta_title, front_matter_texts, filename=original_filename)

        if not title:
            # Look for first heading unit
            for u in struct.get("units", []):
                if u.get("type") == "heading":
                    t = u.get("text", "").strip()
                    if 0 < len(t.split()) <= 12:
                        title = t
                        break

        if not title:
            for p_blocks in page_blocks_list:
                for idx, b in enumerate(p_blocks):
                    txt = b["text"].strip()
                    words = txt.split()
                    if 0 < len(words) <= 10 and not txt.endswith((".", ",", ";", ":")):
                        if txt[0].isupper() or txt[0].isdigit():
                            if idx + 1 < len(p_blocks) and len(p_blocks[idx + 1]["text"].split()) > 10:
                                title = txt
                                break
                if title:
                    break

        if not title:
            title = Path(original_filename).stem

        try:
            raw_toc = doc.get_toc(simple=True) or []
        except Exception:
            raw_toc = []

        return {
            "title": title[:120],
            "page_count": total_pages,
            "canonical_text": canonical_text,
            "spans": spans,
            "layout_warning": layout_warning,
            "raw_text_path": raw_text_path,
            "triage": triage_data,
            "repair_ledger": ledger.to_list(),
            "raw_toc": raw_toc,
            "printed_toc": struct.get("printed_toc", []),
            "telemetry": telemetry_data,
        }
    finally:
        if raw_text_file is not None:
            raw_text_file.close()
        doc.close()


def extract_toc_with_chunk_mapping(raw_toc: list, page_to_first_chunk: dict[int, int]) -> list[dict]:
    """
    Maps PyMuPDF's native TOC [level, title, page_1_based] to exact chunk sequence boundaries.
    """
    if not raw_toc:
        return []
    chapters = []
    for item in raw_toc:
        if len(item) < 3:
            continue
        level, title, page_1_based = item[0], str(item[1]).strip(), item[2]
        page_0 = max(0, page_1_based - 1)
        # Find closest chunk index starting on or after this page
        chunk_idx = page_to_first_chunk.get(page_0)
        if chunk_idx is None:
            candidates_after = [p for p in page_to_first_chunk if p >= page_0]
            if candidates_after:
                chunk_idx = page_to_first_chunk[min(candidates_after)]
            else:
                candidates_before = [p for p in page_to_first_chunk if p < page_0]
                chunk_idx = page_to_first_chunk[max(candidates_before)] if candidates_before else 1

        chapters.append({
            "level": int(level),
            "title": title,
            "start_page": page_0,
            "start_chunk_index": int(chunk_idx),
        })
    return chapters

