"""
Stage 0 (Page Triage) and Stage 7 (Quality Grading) service.

Classifies every page separately:
- real text volume
- image area coverage
- unmapped / private-use character ratio
- page rotation and dimensions

Produces page classification: digital | scanned | hybrid | broken_font.
Scores quality from Grade A to Grade D.
"""

import re
from typing import Any, Callable, Dict
import pymupdf



def triage_page(page: pymupdf.Page, page_index: int) -> Dict[str, Any]:
    """
    Analyzes a single PyMuPDF page and returns detailed triage metrics and classification.
    """
    rect = page.rect
    page_area = max(1.0, rect.width * rect.height)

    # 1. Image coverage
    image_list = page.get_images()
    image_area = 0.0
    for img_info in image_list:
        xref = img_info[0]
        # Get bounding rects where this image is placed on page
        for img_rect in page.get_image_rects(xref):
            image_area += img_rect.width * img_rect.height

    image_ratio = min(1.0, image_area / page_area)

    # 2. Text metrics
    text = page.get_text()
    non_space_chars = len([c for c in text if not c.isspace()])
    total_chars = len(text)

    # 3. Unmapped / odd characters
    unmapped_count = 0
    private_use_count = 0
    c1_control_count = 0

    for ch in text:
        code = ord(ch)
        if code == 0xFFFD:
            unmapped_count += 1
        elif 0xE000 <= code <= 0xF8FF:
            private_use_count += 1
        elif 0x0080 <= code <= 0x009F:
            c1_control_count += 1

    # In PDFs where missing font encodings substitute question marks (e.g., ???)
    for q_run in re.findall(r"\?{3,}", text):
        unmapped_count += len(q_run)

    bad_char_count = unmapped_count + private_use_count
    odd_ratio = (bad_char_count / max(1, total_chars)) if total_chars > 0 else 0.0

    # Some PDFs have a broken ToUnicode map that substitutes ordinary ASCII
    # punctuation for letters. These files look normal to the PDF parser (and
    # evade the replacement-character check above), but the extracted words are
    # unusable. Backslashes and several glyph fragments in this set are rare in
    # prose; require both an absolute count and a ratio to avoid flagging code.
    encoding_anomaly_count = sum(text.count(char) for char in "\\~`{}|")
    encoding_anomaly_ratio = encoding_anomaly_count / max(1, non_space_chars)
    suspicious_encoding = (
        encoding_anomaly_count >= 10 and encoding_anomaly_ratio >= 0.005
    )


    # 4. Classification
    if non_space_chars < 30 and (image_ratio > 0.4 or len(image_list) > 0):
        classification = "scanned"
    elif odd_ratio > 0.05 or suspicious_encoding:
        classification = "broken_font"
    elif non_space_chars > 100 and image_ratio > 0.3:
        classification = "hybrid"
    elif non_space_chars >= 30:
        classification = "digital"
    elif non_space_chars == 0:
        classification = "scanned" if (image_ratio > 0.1 or len(image_list) > 0) else "empty"
    else:
        classification = "digital"

    # 5. Quality Grading (Stage 7: A, B, C, D)
    if classification == "broken_font" or classification == "scanned":
        grade = "D"
        flag = "broken_or_scanned"
    elif classification == "empty":
        grade = "C"
        flag = "empty_page"
    elif odd_ratio > 0.01 or (classification == "hybrid" and odd_ratio > 0.005):
        grade = "C"
        flag = "high_unmapped_characters"
    elif odd_ratio > 0.001 or c1_control_count > 0:
        grade = "B"
        flag = "repaired_characters"
    else:
        grade = "A"
        flag = "clean"


    return {
        "page_number": page_index + 1,
        "width": rect.width,
        "height": rect.height,
        "rotation": page.rotation,
        "classification": classification,
        "grade": grade,
        "flag": flag,
        "total_chars": total_chars,
        "non_space_chars": non_space_chars,
        "image_ratio": round(image_ratio, 3),
        "odd_char_ratio": round(odd_ratio, 4),
        "encoding_anomaly_count": encoding_anomaly_count,
        "encoding_anomaly_ratio": round(encoding_anomaly_ratio, 4),
        "needs_ocr": suspicious_encoding or odd_ratio > 0.05,
        "unmapped_count": unmapped_count,
        "private_use_count": private_use_count,
        "c1_control_count": c1_control_count,
    }


def triage_document(
    doc: pymupdf.Document,
    *,
    include_pages: bool = True,
    progress_callback: Callable[[int, int], None] | None = None,
) -> Dict[str, Any]:
    """
    Triages all pages in a document and produces document-level summary metrics.
    """
    pages_triage = []
    scanned_count = 0
    broken_count = 0
    grades_count = {"A": 0, "B": 0, "C": 0, "D": 0}

    for idx, page in enumerate(doc):
        t = triage_page(page, idx)
        if include_pages:
            pages_triage.append(t)
        if t["classification"] == "scanned":
            scanned_count += 1
        elif t["classification"] == "broken_font":
            broken_count += 1
        grades_count[t["grade"]] = grades_count.get(t["grade"], 0) + 1
        if progress_callback:
            progress_callback(idx + 1, len(doc))

    total_pages = max(1, len(doc))
    is_primarily_scanned = (scanned_count / total_pages) > 0.5
    has_broken_fonts = broken_count > 0

    return {
        "total_pages": len(doc),
        "pages": pages_triage if include_pages else [],
        "grades_count": grades_count,
        "is_primarily_scanned": is_primarily_scanned,
        "has_broken_fonts": has_broken_fonts,
        "scanned_pages_count": scanned_count,
        "broken_font_pages_count": broken_count,
    }
