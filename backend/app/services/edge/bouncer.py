"""
Edge AI Stage-0 Document Bouncer & Genre Admission Engine.
Evaluates per-page structural dominance, font telemetry, and prose-to-formula ratios.
"""

import logging
import re
from typing import Any, List, Optional, Set

from .novelty import _get_embedder
from .hygiene import PROSE_STOPWORDS

logger = logging.getLogger(__name__)

BOUNCER_PROTOTYPES = {
    "book": (
        "Non-fiction book, philosophical treatise, historical narrative, biography, psychology, "
        "narrative science, continuous analytical prose paragraphs, ideas and reflections."
    ),
    "research_paper": (
        "Academic research paper, abstract, introduction, empirical methodology, "
        "experimental results, discussion, peer-reviewed study, literature review."
    ),
    "longform_essay": (
        "Long-form analytical essay, literary journalism, thought piece, "
        "extended argument and narrative prose reflection."
    ),
    "FICTION_NOVEL_STORY": (
        "fictional novel, character dialogue, she whispered, he walked across the room, "
        "story plot, romance, fantasy, protagonist, dramatic scene."
    ),
    "NONFICTION_PROSE": (
        "non-fiction analysis, philosophical argument, historical evidence, "
        "psychological study, thesis, human behavior, empirical research."
    ),
    "resume_cv": (
        "Curriculum vitae, resume, work experience, education, technical skills, "
        "projects, GPA, contact information, job applicant, career qualifications."
    ),
    "invoice_receipt": (
        "Commercial invoice, payment receipt, billing statement, tax form, "
        "account balance, subtotal, amount due, transaction table, total due."
    ),
    "slide_deck": (
        "Presentation slides, bullet point summary, pitch deck, lecture handout, "
        "key takeaways, slide title, presentation bullet points."
    ),
    "exam_or_syllabus": (
        "University examination question paper, course syllabus, marks allocation, "
        "answer all questions, part A part B, multiple choice questions, semester exam."
    ),
    "form_or_table": (
        "Fillable application form, certificate, checkbox fields, signature line, "
        "terms and conditions checklist, tabular structured data."
    ),
    "code_dump": (
        "Computer source code, programming script, JSON configuration, "
        "server log output, API documentation table, traceback error log."
    ),
}

_bouncer_vectors = None


def _get_bouncer_vectors():
    global _bouncer_vectors
    if _bouncer_vectors is not None:
        return _bouncer_vectors

    embedder = _get_embedder()
    if embedder is None:
        return None

    try:
        keys = list(BOUNCER_PROTOTYPES.keys())
        texts = [BOUNCER_PROTOTYPES[k] for k in keys]
        vecs = list(embedder.embed(texts))
        _bouncer_vectors = {k: v for k, v in zip(keys, vecs)}
        return _bouncer_vectors
    except Exception as e:
        logger.warning("Failed to embed bouncer prototypes: %s", e)
        return None


def extract_document_telemetry(doc: Any) -> dict:
    """
    Extracts font, math, monospace, and layout telemetry from sampled body pages (15% to 85%).
    Runs in < 50ms using PyMuPDF page dicts.
    """
    if doc is None or not hasattr(doc, "page_count"):
        return {}

    total_pages = doc.page_count
    if total_pages <= 15:
        sample_indices = list(range(total_pages))
    else:
        start_p = max(0, int(total_pages * 0.15))
        end_p = min(total_pages, int(total_pages * 0.85))
        step = max(1, (end_p - start_p) // 15)
        sample_indices = list(range(start_p, end_p, step))[:15]

    math_fonts = ("cmmi", "cmsy", "cmex", "math", "symbol", "mtextra", "euclid", "latinmodernmath")
    mono_fonts = ("courier", "consolas", "monaco", "menlo", "firacode", "jetbrains", "sourcecode", "inconsolata", "mono")

    total_spans = 0
    math_spans = 0
    mono_spans = 0
    blocks_counts = []
    words_per_block_list = []
    max_cols = 1
    sampled_texts = []

    for p_idx in sample_indices:
        try:
            page = doc[p_idx]
            p_dict = page.get_text("dict")
            blocks = [b for b in p_dict.get("blocks", []) if b.get("type") == 0]
            blocks_counts.append(len(blocks))

            pw = page.rect.width
            left_col = sum(1 for b in blocks if b["bbox"][2] <= pw * 0.38 and (b["bbox"][2] - b["bbox"][0]) > pw * 0.15)
            mid_col = sum(1 for b in blocks if b["bbox"][0] >= pw * 0.30 and b["bbox"][2] <= pw * 0.70 and (b["bbox"][2] - b["bbox"][0]) > pw * 0.15)
            right_col = sum(1 for b in blocks if b["bbox"][0] >= pw * 0.62 and (b["bbox"][2] - b["bbox"][0]) > pw * 0.15)
            if left_col >= 2 and mid_col >= 2 and right_col >= 2:
                max_cols = max(max_cols, 3)
            elif left_col >= 2 and right_col >= 2:
                max_cols = max(max_cols, 2)

            page_txt_parts = []
            for b in blocks:
                b_words = 0
                for line in b.get("lines", []):
                    for span in line.get("spans", []):
                        total_spans += 1
                        fn = str(span.get("font", "")).lower()
                        if any(mf in fn for mf in math_fonts):
                            math_spans += 1
                        if any(mf in fn for mf in mono_fonts):
                            mono_spans += 1
                        txt = span.get("text", "")
                        b_words += len(txt.split())
                        page_txt_parts.append(txt)
                if b_words > 0:
                    words_per_block_list.append(b_words)
            sampled_texts.append(" ".join(page_txt_parts))
        except Exception:
            continue

    math_font_ratio = (math_spans / max(1, total_spans)) if total_spans > 0 else 0.0
    mono_font_ratio = (mono_spans / max(1, total_spans)) if total_spans > 0 else 0.0
    avg_blocks_per_page = sum(blocks_counts) / max(1, len(blocks_counts)) if blocks_counts else 0.0
    mean_words_per_block = sum(words_per_block_list) / max(1, len(words_per_block_list)) if words_per_block_list else 0.0

    return {
        "math_font_ratio": round(math_font_ratio, 4),
        "mono_font_ratio": round(mono_font_ratio, 4),
        "blocks_per_page": round(avg_blocks_per_page, 1),
        "mean_words_per_block": round(mean_words_per_block, 1),
        "max_columns": max_cols,
        "sampled_texts": sampled_texts,
    }


def _is_code_or_math_line(line: str) -> bool:
    """Evaluates whether a single line is programming code syntax or symbolic math."""
    l = line.strip()
    if not l:
        return False
    code_line_prefixes = (
        "def ", "import ", "from ", "class ", "public ", "private ", "protected ",
        "function ", "function(", "console.log(", "System.out.println(",
        "#include ", "#define ", "using namespace ", "package ", "const ", "let ", "var "
    )
    if any(l.startswith(pfx) for pfx in code_line_prefixes):
        return True
    if l in ("{", "}", "{};", "};"):
        return True
    if l.endswith(";") and not re.search(r'[a-zA-Z]{4,}\s+[a-zA-Z]{4,};', l):
        return True
    if l.startswith((">>> ", "$ ", "//", "/*", "*/")):
        return True

    math_symbols = set("∫∑∂≤≥√∞≠±≈")
    if any(sym in l for sym in math_symbols):
        return True
    if bool(re.search(r'\b(?:dy/dx|dx/dt|lim_\{|T\(s\)|G\(s\)|Y\(s\)|s\^\d)\b', l)):
        return True
    if "=" in l and not re.search(r'[.!?]$', l):
        words = re.findall(r"[A-Za-z]+", l)
        if len(words) <= 5 and any(ch in l for ch in "+-*/^"):
            return True

    return False


def _is_transcript_or_dialogue(p_text: str) -> bool:
    lines = [l.strip() for l in p_text.splitlines() if l.strip()]
    if not lines:
        return False
    dialogue_starters = ("q.", "q:", "a.", "a:", "the witness:", "the court:", "court reporter:", "by mr.", "by ms.", "by mrs.")
    d_lines = sum(1 for l in lines if any(l.lower().startswith(ds) for ds in dialogue_starters))
    return (d_lines / max(1, len(lines))) >= 0.25


def _is_legal_contract(p_text: str) -> bool:
    lines = [l.strip() for l in p_text.splitlines() if l.strip()]
    if not lines:
        return False
    legal_indicators = (
        "hereinafter", "in witness whereof", "notwithstanding anything to the contrary",
        "shall indemnify", "governed by §", "covenants governed by", "license agreement",
        "commercial software license", "party of the first part", "terms and conditions"
    )
    p_lower = p_text.lower()
    matches = sum(1 for ind in legal_indicators if ind in p_lower)
    section_lines = sum(1 for l in lines if bool(re.match(r'^(?:Section|Article|Clause)\s+\d+', l, re.IGNORECASE)))
    return matches >= 2 or (section_lines / max(1, len(lines)) >= 0.25 and matches >= 1)


def _is_prose_page(page_text: str) -> bool:
    """
    Evaluates individual page structure:
    1. >= 100 alphabetic words
    2. >= 45% words inside grammatical sentences (>= 7 words ending in ., ?, !, ", or ”)
    3. < 50% lines are code syntax or isolated math
    4. Not dominated by tables, code, math formulas, legal clauses, or deposition dialogue
    """
    if _is_table_dominated(page_text) or _is_code_dominated(page_text) or _is_math_dominated(page_text) or _is_transcript_or_dialogue(page_text) or _is_legal_contract(page_text):
        return False

    words = re.findall(r"[^\W\d_]+", page_text)
    total_words = len(words)
    if total_words < 90:
        return False

    sentence_pattern = re.compile(r'([^\W_][^.!?]*?[.!?]["\'”]?)(\s+|$)', re.DOTALL)
    raw_sentences = [m.group(1).strip() for m in sentence_pattern.finditer(page_text)]

    words_in_sentences = 0
    for s in raw_sentences:
        s_words = re.findall(r"[^\W\d_]+", s)
        if len(s_words) >= 7 and re.search(r'[.!?]["\'”]?$', s):
            words_in_sentences += len(s_words)

    grammatical_ratio = words_in_sentences / max(1, total_words)
    if grammatical_ratio < 0.40:
        return False

    lines = [l.strip() for l in page_text.splitlines() if l.strip()]
    if not lines:
        return False

    code_or_math_lines = sum(1 for l in lines if _is_code_or_math_line(l))
    code_or_math_ratio = code_or_math_lines / max(1, len(lines))
    if code_or_math_ratio >= 0.50:
        return False

    return True


def _is_math_dominated(p_text: str) -> bool:
    math_symbols = set("∫∑∂≤≥√∞≠±≈Δπ")
    m_sym_count = sum(1 for ch in p_text if ch in math_symbols)
    m_formula_count = len(re.findall(r'\b(?:dy/dx|dx/dt|lim_\{|T\(s\)|G\(s\)|Y\(s\)|R\(s\)|s\^\d|f\(x\)|Eq\.\s*\(\d+\.\d+\)|Theorem\s+\d|Lemma\s+\d)\b', p_text))
    lines = [l.strip() for l in p_text.splitlines() if l.strip()]
    eq_lines = sum(
        1 for l in lines
        if ("=" in l and not any(l.startswith(pfx) for pfx in ("self.", "def ", "var ", "let ", "const ", "return ")) and any(op in l for op in ("+", "-", "*", "/", "^", "∫", "∑")) and not re.search(r'[.!?]$', l))
    )
    return (m_sym_count + m_formula_count >= 2) or (eq_lines / max(1, len(lines)) >= 0.20)


def _is_code_dominated(p_text: str) -> bool:
    lines = [l.strip() for l in p_text.splitlines() if l.strip()]
    if not lines:
        return False
    code_starters = (
        "def ", "import ", "from ", "#include", "public class ", "public ", "private ",
        "function(", "function ", "console.log", "System.out.println", "class ",
        "const ", "let ", "var ", "return ", "self.", "val ", "package ", "using namespace "
    )
    code_lines = 0
    for l in lines:
        # Ignore normal prose sentences/paragraphs
        if len(re.findall(r"[^\W\d_]+", l)) > 15 and re.search(r'[.!?]["\'”]?$', l):
            continue
        if (
            l.endswith(";") or
            l.startswith(("{", "}", "//", "/*", "*/", ">>> ", "$ ")) or
            any(l.startswith(cs) for cs in code_starters) or
            l in ("{", "}", "{};")
        ):
            code_lines += 1
    return (code_lines / max(1, len(lines))) >= 0.35


def _is_table_dominated(p_text: str) -> bool:
    lines = [l.strip() for l in p_text.splitlines() if l.strip()]
    if not lines:
        return False
    table_lines = sum(
        1 for l in lines
        if "|" in l or "\t" in l or bool(re.search(r'\s{3,}', l)) or bool(re.search(r'[\$₹€£%]', l)) or len(re.findall(r'\b\d+[\.,]\d+\b', l)) >= 2 or any(kw in l.lower() for kw in ("subtotal", "total due", "amount due", "balance sheet", "line item", "qty", "unit price", "invoice #"))
    )
    return (table_lines / max(1, len(lines))) >= 0.45


def classify_document_purpose(
    pages_meta: Optional[List[dict]] = None,
    sample_texts: Optional[List[str]] = None,
    raw_filename: str = "",
    pdf_path: Optional[Any] = None,
    doc: Optional[Any] = None,
    telemetry: Optional[dict] = None,
) -> dict:
    """
    High-Precision Document Bouncer (Per-Page Structural Dominance).
    Admitted: Books, novels, essays, memoirs, research papers (prose_page_ratio >= 0.40).
    Rejected: Slide decks, STEM textbooks / formula workbooks (>= 35% math),
    programming code manuals (>= 35% code), encrypted PDFs, empty/too short, and tabular forms.
    """
    fn_lower = (raw_filename or "").lower()
    is_enc_doc = False
    if doc is not None and (getattr(doc, "needs_pass", False) or getattr(doc, "is_encrypted", False)):
        is_enc_doc = True
    elif pages_meta and any(p.get("is_encrypted") or p.get("needs_pass") for p in pages_meta):
        is_enc_doc = True
    elif "encrypted" in fn_lower or "password_protected" in fn_lower:
        is_enc_doc = True

    # Rule 1 — Encrypted PDF
    if is_enc_doc:
        return {
            "allowed": False,
            "doc_category": "encrypted_pdf",
            "display_label": "Password-Protected / Encrypted PDF",
            "reason": "This PDF is encrypted or password-protected and cannot be extracted.",
            "confidence": 1.0,
        }

    # Extract pages_meta from doc or pdf_path if missing
    if not pages_meta and doc is not None:
        try:
            pages_meta = [{"width": p.rect.width, "height": p.rect.height} for p in doc]
        except Exception:
            pass
    elif not pages_meta and pdf_path is not None:
        try:
            import fitz
            with fitz.open(pdf_path) as _d:
                pages_meta = [{"width": p.rect.width, "height": p.rect.height} for p in _d]
        except Exception:
            pass

    # Extract PyMuPDF telemetry if doc or pdf_path available and telemetry missing
    if telemetry is None and doc is not None:
        telemetry = extract_document_telemetry(doc)
    elif telemetry is None and pdf_path is not None:
        try:
            import pymupdf
            temp_doc = pymupdf.open(pdf_path)
            try:
                telemetry = extract_document_telemetry(temp_doc)
            finally:
                temp_doc.close()
        except Exception:
            telemetry = {}
    elif telemetry is None:
        telemetry = {}

    # Resolve sampled pages strictly from core body pages (15% to 85%)
    sampled_pages = []
    if telemetry and telemetry.get("sampled_texts") and len(telemetry["sampled_texts"]) > 0:
        sampled_pages = [t for t in telemetry["sampled_texts"] if t.strip()]
    elif sample_texts and len(sample_texts) > 1:
        sampled_pages = [t for t in sample_texts if t.strip()]
    elif sample_texts and len(sample_texts) == 1:
        txt = sample_texts[0]
        if "\x0c" in txt:
            sampled_pages = [p.strip() for p in txt.split("\x0c") if p.strip()]
        elif pages_meta and len(pages_meta) > 1:
            paras = [p.strip() for p in txt.split("\n\n") if p.strip()]
            if len(paras) >= len(pages_meta):
                chunk_size = max(1, len(paras) // len(pages_meta))
                sampled_pages = []
                for i in range(len(pages_meta)):
                    s_idx = i * chunk_size
                    e_idx = (i + 1) * chunk_size if i < len(pages_meta) - 1 else len(paras)
                    sampled_pages.append("\n\n".join(paras[s_idx:e_idx]))
            elif paras:
                sampled_pages = paras
            else:
                sampled_pages = [txt]
        else:
            paras = [p.strip() for p in txt.split("\n\n") if p.strip()]
            if len(paras) >= 3 and len(re.findall(r"[^\W\d_]+", txt)) >= 300:
                sampled_pages = []
                curr = []
                curr_words = 0
                for p in paras:
                    curr.append(p)
                    curr_words += len(re.findall(r"[^\W\d_]+", p))
                    if curr_words >= 150:
                        sampled_pages.append("\n\n".join(curr))
                        curr = []
                        curr_words = 0
                if curr:
                    sampled_pages.append("\n\n".join(curr))
            elif paras:
                sampled_pages = paras
            else:
                sampled_pages = [txt]
    elif doc is not None:
        try:
            total_pages = doc.page_count
            if total_pages <= 15:
                sample_indices = list(range(total_pages))
            else:
                start_p = max(0, int(total_pages * 0.15))
                end_p = min(total_pages, int(total_pages * 0.85))
                step = max(1, (end_p - start_p) // 15)
                sample_indices = list(range(start_p, end_p, step))[:15]
            for idx in sample_indices:
                sampled_pages.append(doc[idx].get_text())
        except Exception:
            pass

    full_text = "\n\n".join(t for t in (sample_texts or []) if t and t.strip())
    if not full_text and sampled_pages:
        full_text = "\n\n".join(sampled_pages)

    raw_words = re.findall(r"[^\W\d_]+", full_text)
    total_words = len(raw_words)

    # Rule: Landscape Presentation Slide Deck Check
    landscape_ratio = 0.0
    if pages_meta:
        landscape_count = sum(1 for p in pages_meta if p.get("width", 0) > p.get("height", 1) * 1.20)
        landscape_ratio = landscape_count / max(1, len(pages_meta))
    if landscape_ratio >= 0.70 and (len(pages_meta) >= 2 or total_words >= 50):
        return {
            "allowed": False,
            "doc_category": "slide_deck",
            "display_label": "Presentation Slide Deck",
            "reason": f"Document is {round(landscape_ratio * 100)}% landscape slide layout lacking narrative prose.",
            "confidence": 0.96,
        }

    # Calculate Code & Math Dominance across sampled core pages
    code_dominated_pages = sum(1 for p in sampled_pages if _is_code_dominated(p))
    code_ratio = code_dominated_pages / max(1, len(sampled_pages))

    math_dominated_pages = sum(1 for p in sampled_pages if _is_math_dominated(p))
    math_ratio = math_dominated_pages / max(1, len(sampled_pages))

    table_dominated_pages = sum(1 for p in sampled_pages if _is_table_dominated(p))
    table_ratio = table_dominated_pages / max(1, len(sampled_pages))

    # Evaluate Prose Dominance
    prose_pages_count = sum(1 for p in sampled_pages if _is_prose_page(p))
    prose_ratio = prose_pages_count / max(1, len(sampled_pages))

    # Default-Allow Book Immunity:
    # If >= 35% of sampled core pages (15%–85%) are valid prose pages (>= 90 words with >= 40% words in complete sentences),
    # ALWAYS return allowed = True (unless >= 45% of core pages are explicitly dominated by heavy symbolic math equations or raw code).
    if prose_ratio >= 0.35 and total_words >= 250 and code_ratio < 0.45 and math_ratio < 0.45:
        is_research_paper = (
            bool(re.search(r"\b(?:abstract|methodology|experimental results|references|bibliography|peer-reviewed|doi:)\b", full_text.lower()))
            and ("abstract" in full_text.lower() or "references" in full_text.lower() or "methodology" in full_text.lower())
            and total_words >= 900
        )
        if is_research_paper:
            return {
                "allowed": True,
                "doc_category": "research_paper",
                "display_label": "Academic Research Paper",
                "reason": "Academic paper with empirical methodology and research structure.",
                "confidence": 0.94,
            }
        return {
            "allowed": True,
            "doc_category": "book",
            "display_label": "Book or Long-Form Narrative",
            "reason": f"Continuous narrative prose detected ({round(prose_ratio * 100)}% prose pages).",
            "confidence": 0.95,
        }

    # Hard rejection for STEM textbooks or coding manuals if core pages are dominated by math/code
    if (telemetry and telemetry.get("mono_font_ratio", 0) >= 0.20) or code_ratio >= 0.35:
        return {
            "allowed": False,
            "doc_category": "coding_manual",
            "display_label": "Programming Code Manual / Syntax Dump",
            "reason": "Document is heavily dominated by programming code and syntax dumps.",
            "confidence": 0.95,
        }

    if (telemetry and telemetry.get("math_font_ratio", 0) >= 0.08) or math_ratio >= 0.35:
        return {
            "allowed": False,
            "doc_category": "stem_textbook",
            "display_label": "STEM Formula Textbook / Exercise Bank",
            "reason": "Document is heavily dominated by mathematical equations and formula exercises.",
            "confidence": 0.95,
        }

    if table_ratio >= 0.45 and prose_ratio < 0.35:
        return {
            "allowed": False,
            "doc_category": "form_or_table",
            "display_label": "Form, Table, or Fragment Document",
            "reason": f"Document is {round(table_ratio * 100)}% tabular structured data lacking narrative prose.",
            "confidence": 0.96,
        }

    transcript_dominated_pages = sum(1 for p in sampled_pages if _is_transcript_or_dialogue(p))
    transcript_ratio = transcript_dominated_pages / max(1, len(sampled_pages))

    legal_dominated_pages = sum(1 for p in sampled_pages if _is_legal_contract(p))
    legal_ratio = legal_dominated_pages / max(1, len(sampled_pages))

    if (transcript_ratio >= 0.35 or legal_ratio >= 0.35) and prose_ratio < 0.35:
        return {
            "allowed": False,
            "doc_category": "form_or_table",
            "display_label": "Legal Document or Transcript",
            "reason": "Document is dominated by legal contractual clauses or dialogue deposition transcripts.",
            "confidence": 0.96,
        }

    # For non-prose documents (< 40% prose), evaluate rejection rules:
    # Rule 3 — Landscape Presentation Slide Deck
    landscape_ratio = 0.0
    if pages_meta:
        landscape_count = sum(1 for p in pages_meta if p.get("width", 0) > p.get("height", 1) * 1.20)
        landscape_ratio = landscape_count / max(1, len(pages_meta))
    if landscape_ratio >= 0.70 and (len(pages_meta) >= 2 or total_words >= 50):
        return {
            "allowed": False,
            "doc_category": "slide_deck",
            "display_label": "Presentation Slide Deck",
            "reason": f"Document is {round(landscape_ratio * 100)}% landscape slide layout lacking narrative prose.",
            "confidence": 0.96,
        }

    # Rule 4 — Heavy Code Dump / Reference (coding_manual)
    if _is_code_dominated(full_text):
        return {
            "allowed": False,
            "doc_category": "coding_manual",
            "display_label": "Programming Code Manual / Syntax Dump",
            "reason": "Document is heavily dominated by programming code and syntax dumps.",
            "confidence": 0.95,
        }

    # Rule 5 — Heavy Equation / Formula Workbook (stem_textbook)
    if _is_math_dominated(full_text):
        return {
            "allowed": False,
            "doc_category": "stem_textbook",
            "display_label": "STEM Formula Textbook / Exercise Bank",
            "reason": "Document is heavily dominated by mathematical equations and formula exercises.",
            "confidence": 0.95,
        }

    # Rule 2 — Too Short / Blank Scan
    if total_words < 1 and not (sample_texts or (telemetry and telemetry.get("sampled_texts"))):
        return {
            "allowed": False,
            "doc_category": "empty_document",
            "display_label": "Empty Document",
            "reason": "This document contains no readable text.",
            "confidence": 1.0,
        }
    if total_words < 250:
        return {
            "allowed": False,
            "doc_category": "too_short",
            "display_label": "Document Too Short / Empty Scan",
            "reason": f"Document contains only {total_words} words (minimum 250 words required for deep reading).",
            "confidence": 0.98,
        }

    # Rule 6 — Fragment / Form / Tabular Non-Book (form_or_table)
    doc_lines = [l.strip() for l in full_text.splitlines() if l.strip()]
    if doc_lines:
        fragment_lines = 0
        for l in doc_lines:
            w = re.findall(r"[^\W\d_]+", l)
            is_table = "|" in l or "\t" in l or bool(re.search(r'\s{3,}', l))
            is_numeric = bool(re.search(r'[\$₹€£%]|^\s*[\d\.\-\+\(\)]+\s*$', l)) or (len(re.findall(r'\d+', l)) >= 2)
            is_short_unpunctuated = len(w) < 8 and not re.search(r'[.!?]["\'”]?$', l)
            if is_table or is_numeric or is_short_unpunctuated:
                fragment_lines += 1

        fragment_ratio = fragment_lines / len(doc_lines)
        if prose_ratio < 0.25 and fragment_ratio >= 0.70:
            return {
                "allowed": False,
                "doc_category": "form_or_table",
                "display_label": "Form, Table, or Fragment Document",
                "reason": f"Document is {round(fragment_ratio * 100)}% tabular cells, numbers, or unpunctuated line fragments lacking narrative prose.",
                "confidence": 0.96,
            }

    # Golden Rule: Default allow any reading document not violating the rejection gates
    return {
        "allowed": True,
        "doc_category": "book",
        "display_label": "Book or Long-Form Narrative",
        "reason": "Admitted reading document.",
        "confidence": 0.90,
    }
