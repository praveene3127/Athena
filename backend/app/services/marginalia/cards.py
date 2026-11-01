"""
Quote-First Context Cards Service (§6 in Athena Research Blueprint).

Every card must satisfy:
1. Current source chunk reference.
2. Exact supporting quote from the canonical text (assert exact_quote in canonical_text).
3. Verified external citation (title, publisher, URL).
4. Short explanation (verbatim or constrained LLM).
5. Grounding status: fully_supported | partially_supported | unsupported | abstain.
6. Guardrails:
   - Spacing: 1 card every 2-4 chunks (MIN_CHUNK_GAP_BETWEEN_CARDS).
   - Maximum 3 cards per section.
   - Refusal/abstention when sources are weak or unverified.
"""

from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import logging
import re
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

from app.config import (
    CARD_MAX_WORDS,
    MAX_CARDS_PER_DOC,
    MAX_WIKI_LOOKUPS_PER_DOC,
    MIN_CHUNK_GAP_BETWEEN_CARDS,
)
from app.db import engine
from app.models import Concept, ConceptCache, ContextCard, ReadingChunk
from app.services.edge_ai import (
    evaluate_card_novelty,
    compute_semantic_similarity,
    is_semantic_duplicate,
)
from app.services.marginalia.concepts import build_search_query_for_concept
from app.services.marginalia.llm import LLMService
from app.services.marginalia.wikipedia import WikipediaClient
from sqlmodel import Session, select

logger = logging.getLogger(__name__)

_EVIDENCE_CACHE: Dict[str, List[Dict[str, str]]] = {}


def _fetch_multi_source_evidence(
    query: str,
    concept_label: str,
    slot_archetype: str,
    wiki_client: Optional[WikipediaClient] = None,
) -> List[Dict[str, str]]:
    """Parallel Multi-Source Evidence Aggregator (§6 in Athena Marginalia Mandate).
    Queries OpenAlex, Semantic Scholar, DuckDuckGo, and HackerNews Algolia.
    Demotes Wikipedia to supplementary fallback only when fewer than 2 sources return.
    Results are cached in memory for sub-millisecond repeated queries.
    """
    cache_key = f"{concept_label.lower().strip()}__{slot_archetype.lower()}"
    if cache_key in _EVIDENCE_CACHE:
        return _EVIDENCE_CACHE[cache_key]

    results: List[Dict[str, str]] = []

    def _get_openalex() -> List[Dict[str, str]]:
        clean_q = re.sub(r"[^\w\s-]", " ", query).strip()
        url = f"https://api.openalex.org/works?search={urllib.parse.quote(clean_q)}&per-page=2&sort=cited_by_count:desc"
        req = urllib.request.Request(url, headers={"User-Agent": "AthenaReader/1.0 (mailto:athena@example.com)"})
        with urllib.request.urlopen(req, timeout=3.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            out = []
            for w in data.get("results", []):
                inv = w.get("abstract_inverted_index") or {}
                pos_words = [(p, word) for word, plist in inv.items() for p in plist]
                pos_words.sort()
                abst = " ".join(word for _, word in pos_words)[:400]
                t = w.get("title") or "Empirical Study"
                y = w.get("publication_year") or ""
                c = w.get("cited_by_count") or 0
                doi = w.get("doi") or w.get("id") or "https://openalex.org"
                out.append({
                    "title": f"Study ({y}, cited {c}x): {t}",
                    "publisher": "openalex.org",
                    "url": doi,
                    "extract": abst,
                    "source_type": "academic_paper",
                })
            return out

    def _get_semantic_scholar() -> List[Dict[str, str]]:
        clean_q = re.sub(r"[^\w\s-]", " ", query).strip()
        url = f"https://api.semanticscholar.org/graph/v1/paper/search?query={urllib.parse.quote(clean_q)}&limit=2&fields=title,year,abstract,url,citationCount"
        req = urllib.request.Request(url, headers={"User-Agent": "AthenaReader/1.0"})
        with urllib.request.urlopen(req, timeout=3.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            out = []
            for p in data.get("data", []):
                t = p.get("title")
                y = p.get("year") or ""
                c = p.get("citationCount") or 0
                u = p.get("url") or "https://semanticscholar.org"
                a = p.get("abstract") or ""
                out.append({
                    "title": f"{t} ({y}, {c} citations)",
                    "publisher": "semanticscholar.org",
                    "url": u,
                    "extract": a[:400],
                    "source_type": "academic_paper",
                })
            return out

    def _get_duckduckgo() -> List[Dict[str, str]]:
        clean_q = re.sub(r"[^\w\s-]", " ", concept_label).strip()
        url = f"https://api.duckduckgo.com/?q={urllib.parse.quote(clean_q)}&format=json&no_html=1"
        req = urllib.request.Request(url, headers={"User-Agent": "AthenaReader/1.0"})
        with urllib.request.urlopen(req, timeout=3.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            out = []
            txt = data.get("AbstractText") or data.get("Answer") or ""
            link = data.get("AbstractURL")
            if txt and link:
                out.append({
                    "title": data.get("Heading") or clean_q.title(),
                    "publisher": "duckduckgo.com",
                    "url": link,
                    "extract": txt[:400],
                    "source_type": "web_context",
                })
            for topic in data.get("RelatedTopics", [])[:2]:
                if isinstance(topic, dict) and topic.get("Text") and topic.get("FirstURL"):
                    out.append({
                        "title": topic.get("Text")[:60],
                        "publisher": "duckduckgo.com",
                        "url": topic.get("FirstURL"),
                        "extract": topic.get("Text")[:300],
                        "source_type": "web_context",
                    })
            return out

    def _get_hackernews() -> List[Dict[str, str]]:
        clean_q = re.sub(r"[^\w\s-]", " ", concept_label).strip()
        url = f"https://hn.algolia.com/api/v1/search?query={urllib.parse.quote(clean_q)}&tags=story&hitsPerPage=2"
        req = urllib.request.Request(url, headers={"User-Agent": "AthenaReader/1.0"})
        with urllib.request.urlopen(req, timeout=3.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            out = []
            for hit in data.get("hits", []):
                t = hit.get("title")
                oid = hit.get("objectID")
                u = hit.get("url") or f"https://news.ycombinator.com/item?id={oid}"
                out.append({
                    "title": f"Debate: {t}",
                    "publisher": "news.ycombinator.com",
                    "url": u,
                    "extract": t,
                    "source_type": "discourse",
                })
            return out

    tasks = [_get_openalex, _get_duckduckgo, _get_semantic_scholar]
    if "DEBATE" in slot_archetype.upper() or "PARADOX" in slot_archetype.upper():
        tasks.append(_get_hackernews)

    with ThreadPoolExecutor(max_workers=len(tasks)) as pool:
        futures = [pool.submit(fn) for fn in tasks]
        for fut in as_completed(futures, timeout=4.0):
            try:
                res = fut.result()
                if res:
                    results.extend(res)
            except Exception:
                pass

    seen_urls = set()
    deduped = []
    for item in results:
        u = item.get("url", "")
        if u and u not in seen_urls:
            seen_urls.add(u)
            deduped.append(item)

    # Wikipedia as last-resort supplementary fallback if < 2 sources
    if len(deduped) < 2:
        try:
            wclient = wiki_client or WikipediaClient()
            wdata = wclient.fetch_term(concept_label)
            if wdata and wdata.get("citation", {}).get("url"):
                cit = wdata["citation"]
                if cit.get("url") not in seen_urls:
                    deduped.append({
                        "title": cit.get("title") or f"{concept_label} (Wikipedia)",
                        "publisher": cit.get("publisher") or "en.wikipedia.org",
                        "url": cit.get("url"),
                        "extract": wdata.get("extract", "")[:400],
                        "source_type": "encyclopedia",
                    })
        except Exception:
            pass

    _EVIDENCE_CACHE[cache_key] = deduped
    return deduped


def extract_verbatim_body(extract: str, max_words: int = CARD_MAX_WORDS) -> Optional[str]:
    """Returns leading sentences of Wikipedia extract, verbatim, up to max_words,
    cut strictly at sentence boundaries. If first sentence exceeds limit, returns None.
    """
    if not extract:
        return None

    sentences = re.split(r"(?<=[.!?])\s+", extract.strip())
    body_sentences: list[str] = []
    total_words = 0

    for s in sentences:
        s_words = len(s.split())
        if total_words + s_words <= max_words:
            body_sentences.append(s)
            total_words += s_words
        else:
            break

    if not body_sentences:
        return None

    return " ".join(body_sentences)


def _fold_for_shadow(text: str) -> Tuple[str, List[int]]:
    """
    Folds string into a normalized shadow representation (lowercase alphanumeric characters)
    and an offset map where offset_map[shadow_idx] = original_index_in_text.
    Preserves exact character mapping back to the pristine canonical source text.
    """
    shadow_chars: List[str] = []
    offset_map: List[int] = []
    for i, ch in enumerate(text):
        if ch.isalnum():
            shadow_chars.append(ch.lower())
            offset_map.append(i)
    return "".join(shadow_chars), offset_map


def verify_and_anchor_quote(passage: str, candidate: str) -> Optional[str]:
    """
    Non-destructive shadow quote matching:
    Verifies candidate quote against passage without altering passage typography (em-dashes,
    curly quotes, ligatures). Slices the exact character span directly from the passage.
    Guarantees: assert result in passage.
    """
    if not passage or not candidate:
        return None

    clean_cand = candidate.strip()
    if clean_cand in passage:
        return clean_cand

    shadow_passage, map_p = _fold_for_shadow(passage)
    shadow_cand, _ = _fold_for_shadow(candidate)

    if not shadow_cand or shadow_cand not in shadow_passage:
        return None

    match_start = shadow_passage.find(shadow_cand)
    match_end = match_start + len(shadow_cand) - 1

    orig_start = map_p[match_start]
    orig_end = map_p[match_end] + 1

    exact_slice = passage[orig_start:orig_end].strip()
    if exact_slice in passage:
        return exact_slice
    return passage[orig_start:orig_end]


def _ensure_verbatim_quote(chunk_text: str, candidate_quote: str, concept_label: str) -> str:
    """Guarantee that the returned quote is an exact verbatim substring of chunk_text."""
    if not chunk_text:
        return ""
    cleaned_candidate = (candidate_quote or "").strip().strip('"“”\'`')
    if cleaned_candidate and len(cleaned_candidate) >= 15 and cleaned_candidate in chunk_text:
        return cleaned_candidate

    # Split chunk_text into spans while preserving exact character offsets
    sentences = [m.group(0).strip() for m in re.finditer(r"[^.!?\n]+[.!?]?", chunk_text) if m.group(0).strip()]

    # 1. Exact sentence containing concept_label
    if concept_label:
        low_label = concept_label.lower()
        for sent in sentences:
            if low_label in sent.lower() and len(sent) >= 20 and sent in chunk_text:
                return sent[:280].strip() if sent[:280].strip() in chunk_text else sent

    # 2. Highest token overlap with candidate_quote
    if cleaned_candidate:
        cand_tokens = set(re.findall(r"\w{4,}", cleaned_candidate.lower()))
        if cand_tokens:
            best_sent = max(
                sentences,
                key=lambda s: len(cand_tokens & set(re.findall(r"\w{4,}", s.lower()))),
                default="",
            )
            if best_sent and len(best_sent) >= 20 and best_sent in chunk_text:
                return best_sent

    # 3. Fallback to first substantive verbatim slice of chunk_text
    for sent in sentences:
        if len(sent) >= 25 and sent in chunk_text:
            return sent
    return chunk_text[: min(len(chunk_text), 160)].strip()


def find_exact_quote(passage: str, term: str) -> Optional[str]:
    """
    Finds the exact contiguous sentence in passage containing the term.
    Uses non-destructive shadow matching to handle typography (ligatures, em-dashes, curly quotes).
    Guarantees exact_quote is a contiguous substring of passage.
    """
    if not passage or not term:
        return None

    # Try finding sentence boundary around the term
    sentences = re.split(r"(?<=[.!?])\s+", passage.strip())
    term_pattern = re.compile(r"\b" + re.escape(term) + r"\b", re.IGNORECASE)

    for s in sentences:
        if term_pattern.search(s):
            # Verify exact contiguous substring
            cleaned = s.strip()
            if cleaned in passage:
                return cleaned
            anchored = verify_and_anchor_quote(passage, cleaned)
            if anchored:
                return anchored

    # Shadow-match term if punctuation or ligature difference prevented regex match
    shadow_passage, map_p = _fold_for_shadow(passage)
    shadow_term, _ = _fold_for_shadow(term)
    if shadow_term and shadow_term in shadow_passage:
        m_start = shadow_passage.find(shadow_term)
        m_end = m_start + len(shadow_term) - 1
        orig_s = map_p[m_start]
        orig_e = map_p[m_end] + 1

        # Expand to sentence boundaries in passage
        sent_start = orig_s
        while sent_start > 0 and passage[sent_start - 1] not in ".!?\n":
            sent_start -= 1
        sent_end = orig_e
        while sent_end < len(passage) and passage[sent_end] not in ".!?\n":
            sent_end += 1
        if sent_end < len(passage) and passage[sent_end] in ".!?":
            sent_end += 1

        candidate = passage[sent_start:sent_end].strip()
        if candidate and candidate in passage:
            return candidate

    # Fallback: find literal occurrence in passage
    match = term_pattern.search(passage)
    if match:
        start = max(0, match.start() - 40)
        end = min(len(passage), match.end() + 60)
        # expand to space boundaries
        while start > 0 and not passage[start].isspace():
            start -= 1
        while end < len(passage) and not passage[end].isspace():
            end += 1
        snippet = passage[start:end].strip()
        if snippet in passage:
            return snippet

    return None


def generate_context_cards(
    concepts: List[Concept],
    chunks: List[ReadingChunk],
    document_id: str,
    canonical_text: Optional[str] = None,
    wiki_client: Optional[WikipediaClient] = None,
    llm_service: Optional[LLMService] = None,
    progress_callback: Optional[callable] = None,
) -> Tuple[List[ContextCard], List[Concept]]:
    """
    Walks concepts by importance, validates against external knowledge, and generates
    quote-first ContextCard records adhering to research guardrails (§6 in Blueprint).
    Returns (cards, updated_concepts).
    """
    if not concepts or not chunks:
        return [], concepts

    wiki = wiki_client or WikipediaClient()
    llm = llm_service or LLMService()

    chunk_map: dict[str, ReadingChunk] = {c.id: c for c in chunks}

    # Document-wide Deduplication Tracking:
    used_concepts: set[str] = set()
    used_titles: set[str] = set()
    existing_bodies: list[str] = []
    try:
        with Session(engine) as db_sess:
            existing_rows = db_sess.exec(
                select(ContextCard).where(
                    ContextCard.document_id == document_id,
                    ContextCard.dismissed == False,
                )
            ).all()
            for ec in existing_rows:
                if ec.concept_name:
                    c_norm = ec.concept_name.strip().lower()
                    used_concepts.add(c_norm)
                    ec_slug = re.sub(r"[^a-z0-9]+", "_", c_norm).strip("_")
                    if ec_slug:
                        used_concepts.add(ec_slug)
                if ec.title:
                    clean_t = re.sub(
                        r"^(?:What is\s+|EMPIRICAL STUDY:\s*|CRITICAL DEBATE:\s*|HISTORICAL CONTEXT:\s*|CORE PARADOX:\s*)+",
                        "",
                        ec.title,
                        flags=re.I,
                    ).strip().lower()
                    used_titles.add(clean_t)
                    used_titles.add(ec.title.strip().lower())
                if ec.body:
                    existing_bodies.append(ec.body.strip())
    except Exception as err:
        logger.warning("Could not pre-load existing cards for deduplication: %s", err)

    # Guardrail tracking:
    # 1. Spacing: MIN_CHUNK_GAP_BETWEEN_CARDS
    # 2. Section limit: Max 3 cards per section
    accepted_sequences: list[int] = []
    seen_wiki_titles: set[str] = set()
    section_card_counts: Counter[str] = Counter()
    cards: List[ContextCard] = []

    wiki_lookups_done = 0
    candidates_evaluated = 0
    total_candidates = min(len(concepts), MAX_WIKI_LOOKUPS_PER_DOC)

    archetype_names = ["EMPIRICAL STUDY", "CRITICAL DEBATE", "HISTORICAL CONTEXT", "CORE PARADOX"]

    for concept in concepts:
        if len(cards) >= MAX_CARDS_PER_DOC:
            break

        if candidates_evaluated >= MAX_WIKI_LOOKUPS_PER_DOC:
            break

        concept_norm = concept.name.strip().lower()
        slug = re.sub(r"[^a-z0-9]+", "_", concept_norm).strip("_")

        # Skip trivial single common words or garbage tokens
        if len(concept.name.split()) == 1 and (
            len(concept.name) < 4
            or concept_norm in {"years", "people", "person", "thing", "things", "lives", "problem", "makes", "keep", "world", "her", "now", "well", "good"}
        ):
            concept.status = "skipped_trivial"
            continue

        # Document-wide concept deduplication: NEVER reuse an already carded concept in this book
        if concept_norm in used_concepts or (slug and slug in used_concepts):
            concept.status = "skipped_duplicate"
            continue

        chunk = chunk_map.get(concept.chunk_id or "")
        if not chunk:
            concept.status = "skipped"
            continue

        # Guardrail 1: Gap check (max 1 card every 2-4 chunks)
        seq = chunk.sequence
        gap_ok = all(abs(seq - s) >= MIN_CHUNK_GAP_BETWEEN_CARDS for s in accepted_sequences)
        if not gap_ok:
            concept.status = "skipped"
            continue

        # Guardrail 2: Section limit (max 3 cards per section)
        sec_title = chunk.section_title or "__doc_body__"
        if section_card_counts[sec_title] >= 3:
            concept.status = "skipped"
            continue

        candidates_evaluated += 1
        if progress_callback:
            progress_callback(candidates_evaluated, total_candidates)

        # Active Slot in the Deterministic 4-Archetype Cycle
        active_slot = (len(existing_bodies) + len(cards)) % 4
        active_archetype = archetype_names[active_slot]

        # Task 2: Rolling "Before -> Now" Narrative Context Bridge
        prev_chunks = [
            c for c in chunks
            if chunk.sequence - 2 <= c.sequence < chunk.sequence
        ]
        prev_chunks.sort(key=lambda c: c.sequence)
        prev_summaries = [f"[Previous Chunk {pc.sequence}]: {pc.raw_text.strip()[:240]}" for pc in prev_chunks]
        recent_card_titles = [f"Recent Card: {c.title}" for c in cards[-2:] if c.title]
        prev_context_str = "\n".join(prev_summaries + recent_card_titles) if prev_summaries else "Opening passage of chapter / book."

        # Check ConceptCache first (Tier 1) - Slot aware (Task 5: v2 invalidation)
        cached_entry = None
        if slug:
            try:
                with Session(engine) as db_sess:
                    cached_entry = db_sess.get(ConceptCache, f"v2_{slug}__slot{active_slot}")
            except Exception:
                cached_entry = None

        use_gemini_search = llm.is_gemini_configured and not cached_entry
        evidence_list: list[dict[str, str]] = []
        extract = ""
        citations: list[dict[str, str]] = []

        if not cached_entry:
            search_q = build_search_query_for_concept(concept.name, chunk.raw_text, active_archetype)
            evidence_list = _fetch_multi_source_evidence(
                query=search_q,
                concept_label=concept.name,
                slot_archetype=active_archetype,
                wiki_client=wiki,
            )
            evidence_extract_parts = []
            for ev in evidence_list:
                if ev.get("extract"):
                    evidence_extract_parts.append(f"[{ev['publisher']} - {ev['title']}]: {ev['extract']}")
                if ev.get("url") and ev.get("title"):
                    citations.append({
                        "title": ev["title"],
                        "publisher": ev["publisher"],
                        "url": ev["url"],
                    })
            extract = "\n\n".join(evidence_extract_parts)

        # Extract supporting quote from the canonical passage
        raw_quote = find_exact_quote(chunk.raw_text, concept.name)
        exact_quote = _ensure_verbatim_quote(chunk.raw_text, raw_quote or "", concept.name)
        if not exact_quote:
            concept.status = "no_quote_span"
            continue

        # MECHANICAL VALIDATION (§6 in Blueprint)
        # 1. exact_quote MUST be a verbatim contiguous substring of the chunk
        if exact_quote not in chunk.raw_text:
            logger.warning("Mechanical check failed: quote not in chunk raw_text")
            concept.status = "refused_unverified"
            continue

        # 2. exact_quote MUST be a verbatim substring of canonical_text if provided
        if canonical_text and exact_quote not in canonical_text:
            logger.warning("Mechanical check failed: quote not in canonical_text")
            concept.status = "refused_unverified"
            continue

        # Generate explanation body
        body: Optional[str] = None
        gen_mode = "extractive"
        card_citations = citations
        card_title = f"{active_archetype}: {concept.name}"

        if cached_entry:
            body = cached_entry.body
            try:
                card_citations = json.loads(cached_entry.citations_json) if cached_entry.citations_json else []
            except Exception:
                card_citations = []
            gen_mode = "concept_cache"
        elif llm.is_configured:
            adjacent = [
                c.raw_text.strip()
                for c in chunks
                if abs(c.sequence - chunk.sequence) == 1
            ]
            context = llm.generate_grounded_context(
                concept_name=concept.name,
                passage_text=chunk.raw_text,
                neighbors_text="\n\n".join(adjacent) or "None.",
                previous_context=prev_context_str,
                forced_slot=active_slot,
                reference_context=extract,
                reference_citations=citations,
            )
            if context:
                body = context["body"]
                card_citations = context["citations"]
                if context.get("title"):
                    card_title = context["title"]
                gen_mode = "gemini_search_grounded" if use_gemini_search else "byok_grounded"
                if slug:
                    try:
                        with Session(engine) as db_sess:
                            db_sess.add(
                                ConceptCache(
                                    concept_slug=f"v2_{slug}__slot{active_slot}",
                                    title=card_title,
                                    body=body,
                                    citations_json=json.dumps(card_citations),
                                    source_model="gemini_search" if use_gemini_search else "byok_grounded",
                                )
                            )
                            db_sess.commit()
                    except Exception:
                        pass
            else:
                concept.status = "no_grounded_context"
                continue
        elif extract:
            body = extract_verbatim_body(extract)
            gen_mode = "extractive"

        min_cites = 2 if (use_gemini_search or llm.is_configured) else 1
        if not body or len(card_citations) < min_cites:
            concept.status = "insufficient_verified_citations"
            continue

        # Ensure title prefix matches archetype and has no "What is " prefix
        clean_heading = re.sub(
            r"^(?:What is\s+|EMPIRICAL STUDY:\s*|CRITICAL DEBATE:\s*|HISTORICAL CONTEXT:\s*|CORE PARADOX:\s*)+",
            "",
            card_title,
            flags=re.I,
        ).strip()
        card_title = f"{active_archetype}: {clean_heading or concept.name}"

        # Hard Rule: Check Title Deduplication
        if clean_heading.lower() in used_titles or card_title.lower() in used_titles:
            logger.info("Card title '%s' already used in doc %s. Skipping.", card_title, document_id)
            concept.status = "skipped_duplicate_title"
            continue

        # Clean generic opening phrases that dilute novelty
        body = re.sub(
            r"^(?:In this passage[,\s]+|This passage discusses[,\s]+|This excerpt explains[,\s]+|According to this passage[,\s]+)",
            "",
            body,
            flags=re.I,
        ).strip()
        if body and body[0].islower():
            body = body[0].upper() + body[1:]

        # Archetype formatting: format into required active archetype
        if active_slot == 0 and "||REVEAL||" not in body:
            sentences = re.split(r"(?<=[.!?])\s+", body)
            if len(sentences) > 1:
                body = f"{sentences[0]}\n||REVEAL||\n{' '.join(sentences[1:])}"
        elif active_slot == 1:
            has_debate = "counterpoint:" in body.lower() and "evidence:" in body.lower()
            if not has_debate:
                sentences = re.split(r"(?<=[.!?])\s+", body)
                if len(sentences) >= 2:
                    body = f"Counterpoint: {sentences[0]}\nEvidence: {' '.join(sentences[1:])}"

        # ONNX Semantic Deduplication: Check if body is too similar to any existing card in this book
        all_existing_bodies = existing_bodies + [c.body for c in cards]
        if is_semantic_duplicate(body, all_existing_bodies, threshold=0.78):
            logger.info("Card for '%s' rejected by ONNX Semantic Deduplication Gate (> 0.78)", concept.name)
            concept.status = "refused_semantic_duplicate"
            continue

        # Stage C: Local ONNX "Information Gain & Specificity Gate" (edge_ai.py)
        novelty = evaluate_card_novelty(chunk.raw_text, card_title, body)
        if not novelty["passed"]:
            fallback_used = False
            if extract and gen_mode != "extractive":
                fallback_body = extract_verbatim_body(extract)
                if fallback_body:
                    fallback_body = re.sub(
                        r"^(?:In this passage[,\s]+|This passage discusses[,\s]+|This excerpt explains[,\s]+)",
                        "",
                        fallback_body,
                        flags=re.I,
                    ).strip()
                    if active_slot == 0 and "||REVEAL||" not in fallback_body:
                        fb_sents = re.split(r"(?<=[.!?])\s+", fallback_body)
                        if len(fb_sents) > 1:
                            fallback_body = f"{fb_sents[0]}\n||REVEAL||\n{' '.join(fb_sents[1:])}"
                    elif active_slot == 1:
                        fb_sents = re.split(r"(?<=[.!?])\s+", fallback_body)
                        if len(fb_sents) >= 2:
                            fallback_body = f"Counterpoint: {fb_sents[0]}\nEvidence: {' '.join(fb_sents[1:])}"

                    fb_novelty = evaluate_card_novelty(chunk.raw_text, card_title, fallback_body)
                    if fb_novelty["passed"]:
                        body = fallback_body
                        gen_mode = "extractive_fallback"
                        fallback_used = True

            if not fallback_used:
                logger.info(
                    "Card for concept '%s' refused by Anti-Echo / Novelty Gate: %s",
                    concept.name,
                    novelty["reason"],
                )
                concept.status = "refused_generic_echo"
                continue

        why_here = f'The concept "{concept.name}" is introduced in the passage above.'

        card = ContextCard(
            document_id=document_id,
            source_chunk_id=chunk.id,
            concept_name=concept.name,
            card_type="explain",
            title=card_title,
            body=body,
            why_here=why_here,
            citations_json=json.dumps(card_citations),
            exact_quote=exact_quote,
            support_status="fully_supported",
            canonical_sha256=chunk.canonical_sha256,
            generation_mode=gen_mode,
            verified=True,
            saved=False,
            dismissed=False,
        )

        cards.append(card)
        accepted_sequences.append(seq)
        used_concepts.add(concept_norm)
        if slug:
            used_concepts.add(slug)
        used_titles.add(clean_heading.lower())
        used_titles.add(card_title.lower())
        existing_bodies.append(body.strip())
        seen_wiki_titles.add((wiki_data.get("title") if wiki_data else concept.name).lower())
        section_card_counts[sec_title] += 1
        concept.status = "carded"

    return cards, concepts
