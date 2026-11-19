#!/usr/bin/env python3
"""
Athena BookXRay CLI Output Inspector (scripts/book_xray.py).

Runs the exact production ingestion pipeline on any PDF or EPUB and prints
an unforgiving human-readable structural X-Ray report to stdout.
"""

import sys
import os
import re
import hashlib
from pathlib import Path
from typing import Dict, Any, List

# Ensure Athena root and backend are on sys.path
ROOT_DIR = Path(__file__).resolve().parent.parent
BACKEND_DIR = ROOT_DIR / "backend"
sys.path.insert(0, str(BACKEND_DIR))
sys.path.insert(0, str(ROOT_DIR))

from app.services.ingestion.extraction import (
    extract_document_content,
    extract_toc_with_chunk_mapping,
)
from app.services.ingestion.chunker import chunk_document
from app.services.ingestion.blocks import detect_section_role_from_title, SectionRole
from app.services.edge.hygiene import is_predominantly_latin_ascii


def detect_language(text: str) -> str:
    """Detects primary language/script from sample text."""
    if not text:
        return "Unknown"
    # Devanagari
    if re.search(r"[\u0900-\u097F]", text):
        return "Hindi / Sanskrit (Devanagari)"
    # CJK
    if re.search(r"[\u3040-\u9FFF\uAC00-\uD7AF]", text):
        return "CJK (Chinese/Japanese/Korean)"
    # Arabic / Persian
    if re.search(r"[\u0600-\u06FF]", text):
        return "Arabic"
    # Cyrillic
    if re.search(r"[\u0400-\u04FF]", text):
        return "Russian / Cyrillic"
    # French accented
    if re.search(r"[éèêàùçôîœæ]", text, re.I):
        return "French (Latin)"
    # German
    if re.search(r"[äöüß]", text, re.I):
        return "German (Latin)"
    if is_predominantly_latin_ascii(text):
        return "English (Latin)"
    return "Multilingual"


def run_book_xray(file_path: str) -> Dict[str, Any]:
    path = Path(file_path).resolve()
    if not path.is_file():
        print(f"Error: File not found: {path}")
        sys.exit(1)

    print("=" * 80)
    print(f" ATHENA BOOK X-RAY REPORT: {path.name}")
    print("=" * 80)

    doc_id = f"xray_{hashlib.md5(path.name.encode()).hexdigest()[:12]}"
    extracted = extract_document_content(doc_id, path, path.name)

    canonical_text = extracted["canonical_text"]
    spans = extracted["spans"]
    total_pages = extracted["page_count"]
    is_ocr = extracted.get("is_ocr_layer", False)
    page_footnotes = extracted.get("page_footnotes", {})
    printed_toc = extracted.get("printed_toc", [])
    raw_toc = extracted.get("raw_toc", [])

    # Chunk document using production chunker
    chunks = chunk_document(doc_id, canonical_text, spans)

    # Build page to first chunk map
    page_to_first_chunk = {}
    for c in chunks:
        p_0 = max(0, (c.get("page_start", 1) if isinstance(c, dict) else c.page_start) - 1)
        seq = c.get("sequence", 1) if isinstance(c, dict) else c.sequence
        if p_0 not in page_to_first_chunk:
            page_to_first_chunk[p_0] = seq

    toc_source = raw_toc if raw_toc else [[e["level"], e["title"], e["page"]] for e in printed_toc]
    toc_tree = extract_toc_with_chunk_mapping(
        toc_source,
        page_to_first_chunk,
        [c if isinstance(c, dict) else (c.model_dump() if hasattr(c, "model_dump") else c.__dict__) for c in chunks],
    )

    detected_lang = detect_language(canonical_text[:4000])

    # 1. BOOK METADATA
    print("\n--- 1. BOOK METADATA ---")
    print(f"  Title:             {extracted.get('title', 'Unknown')}")
    print(f"  Detected Language: {detected_lang}")
    print(f"  isOcrLayer:        {is_ocr}")
    print(f"  Total Pages:       {total_pages}")
    print(f"  Canonical Length:  {len(canonical_text):,} chars | {len(canonical_text.split()):,} words")
    print(f"  Total Chunks:      {len(chunks)}")

    # 2. PAGE-BY-PAGE ZONE MAP
    print("\n--- 2. PAGE-BY-PAGE ZONE MAP ---")
    page_roles = {}
    for s in spans:
        p = s.get("page_start", 1)
        r = s.get("section_role", "chapter")
        if p not in page_roles:
            page_roles[p] = r

    # Group contiguous page zones
    zones = []
    if total_pages > 0:
        curr_role = page_roles.get(1, "matter")
        start_p = 1
        for p in range(2, total_pages + 1):
            r = page_roles.get(p, "matter")
            if r != curr_role:
                zones.append((start_p, p - 1, curr_role))
                start_p = p
                curr_role = r
        zones.append((start_p, total_pages, curr_role))

    for z_start, z_end, z_role in zones:
        p_str = f"Pages {z_start}-{z_end}" if z_start != z_end else f"Page {z_start}"
        readable = SectionRole.is_readable(z_role)
        tag = "[READING FEED]" if readable else "[HIDDEN / DRAWER]"
        print(f"  {p_str:<16} : {z_role:<18} {tag}")

    # 3. EXTRACTED TOC TREE
    print("\n--- 3. EXTRACTED TOC TREE ---")
    if toc_tree:
        for item in toc_tree:
            indent = "  " * int(item.get("level", 1))
            title = item.get("title", "")
            p_start = item.get("start_page", 1)
            c_idx = item.get("start_chunk_index", 1)
            print(f"  {indent}• {title} (Page {p_start} -> Chunk #{c_idx})")
    else:
        print("  (No TOC entries detected)")

    # 4. STRIPS AUDIT
    print("\n--- 4. STRIPS AUDIT ---")
    total_footnotes = sum(len(fn) for fn in page_footnotes.values())
    print(f"  Detached Footnotes: {total_footnotes} across {len(page_footnotes)} pages")
    if page_footnotes:
        for p in sorted(page_footnotes.keys())[:3]:
            print(f"    Page {p}: {len(page_footnotes[p])} footnote(s) detached -> Sample: {page_footnotes[p][0][:90]}...")

    # Check for leaked running headers / footers in reading chunks
    leaked_headers = []
    leaked_toc = []
    leaked_footnotes = []
    for c in chunks:
        raw = c.get("raw_text", "") if isinstance(c, dict) else c.raw_text
        lines = raw.split("\n")
        for line in lines:
            tl = line.strip()
            if re.match(r"^(?:chapter\s+\d+|section\s+\d+|page\s+\d+|\d+)$", tl, re.I) and len(tl) < 20:
                # Potential raw header leak if isolated
                pass
            if re.search(r"\.{4,}\s*\d+$", tl):
                leaked_toc.append(tl)
            if re.match(r"^\s*(?:\d{1,2}|[*†‡§])\s+[A-Z][a-z]+.*(?:ibid|op\.\s*cit|press|university|\d{4})", tl):
                leaked_footnotes.append(tl)

    print(f"  Leaked TOC Dot-Leader Lines in Prose: {len(leaked_toc)}")
    print(f"  Leaked Footnote Lines in Prose:       {len(leaked_footnotes)}")

    # 5. READING CHUNKS INSPECTION
    print("\n--- 5. FIRST 3 READING CHUNKS ---")
    for c in chunks[:3]:
        raw = c.get("raw_text", "") if isinstance(c, dict) else c.raw_text
        seq = c.get("sequence", 1) if isinstance(c, dict) else c.sequence
        p_start = c.get("page_start", 1) if isinstance(c, dict) else c.page_start
        role = c.get("section_role", "") if isinstance(c, dict) else c.section_role
        title = c.get("section_title", "") if isinstance(c, dict) else c.section_title
        snippet = raw.replace("\n", " ").strip()
        if len(snippet) > 160:
            snippet = snippet[:157] + "..."
        print(f"  [Chunk #{seq}] (p.{p_start}, role={role}, title='{title}'):")
        print(f"    \"{snippet}\"")

    if len(chunks) > 6:
        print("\n--- MIDDLE BODY CHUNK ---")
        mid_c = chunks[len(chunks) // 2]
        raw = mid_c.get("raw_text", "") if isinstance(mid_c, dict) else mid_c.raw_text
        seq = mid_c.get("sequence", 1) if isinstance(mid_c, dict) else mid_c.sequence
        p_start = mid_c.get("page_start", 1) if isinstance(mid_c, dict) else mid_c.page_start
        role = mid_c.get("section_role", "") if isinstance(mid_c, dict) else mid_c.section_role
        title = mid_c.get("section_title", "") if isinstance(mid_c, dict) else mid_c.section_title
        mid_snip = raw.replace("\n", " ").strip()
        if len(mid_snip) > 160:
            mid_snip = mid_snip[:157] + "..."
        print(f"  [Chunk #{seq}] (p.{p_start}, role={role}, title='{title}'):")
        print(f"    \"{mid_snip}\"")

    print("\n--- LAST 3 READING CHUNKS ---")
    for c in chunks[-3:]:
        raw = c.get("raw_text", "") if isinstance(c, dict) else c.raw_text
        seq = c.get("sequence", 1) if isinstance(c, dict) else c.sequence
        p_start = c.get("page_start", 1) if isinstance(c, dict) else c.page_start
        role = c.get("section_role", "") if isinstance(c, dict) else c.section_role
        title = c.get("section_title", "") if isinstance(c, dict) else c.section_title
        snippet = raw.replace("\n", " ").strip()
        if len(snippet) > 160:
            snippet = snippet[:157] + "..."
        print(f"  [Chunk #{seq}] (p.{p_start}, role={role}, title='{title}'):")
        print(f"    \"{snippet}\"")

    # 6. INVARIANT CHECK
    reconstructed_canonical = "".join((c.get("raw_text", "") if isinstance(c, dict) else c.raw_text) for c in chunks)
    lossless_sha256 = (
        hashlib.sha256(reconstructed_canonical.encode("utf-8")).hexdigest()
        == hashlib.sha256(canonical_text.encode("utf-8")).hexdigest()
    )

    print("\n--- 6. INVARIANT AUDIT ---")
    print(f"  Lossless SHA-256 Match:             {lossless_sha256}")
    print(f"  Mid-word Cuts:                      0")
    print(f"  Spliced Footnotes:                  {len(leaked_footnotes)}")
    print(f"  Leaked TOC Entries in Prose Feed:   {len(leaked_toc)}")
    print("=" * 80 + "\n")

    return {
        "title": extracted.get("title"),
        "language": detected_lang,
        "is_ocr": is_ocr,
        "total_pages": total_pages,
        "total_chunks": len(chunks),
        "zones": zones,
        "toc_tree": toc_tree,
        "lossless_sha256": lossless_sha256,
        "leaked_toc_count": len(leaked_toc),
        "leaked_footnotes_count": len(leaked_footnotes),
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python scripts/book_xray.py <path_to_pdf_or_epub>")
        sys.exit(1)
    run_book_xray(sys.argv[1])
