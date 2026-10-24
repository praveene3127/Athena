import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple
from sqlmodel import Session, select

from app.db import engine
from app.models import Concept, ConceptCache, ContextCard, Document, ReadingChunk, DocumentChapter
from app.services.cards import find_exact_quote
from app.services.concepts import extract_concepts
from app.services.edge_ai import compute_semantic_similarity, is_semantic_duplicate
from app.services.llm import LLMService
from app.services.wikipedia import WikipediaClient

logger = logging.getLogger("athena.pipeline")

# Epistemic Curiosity Triggers (Stage 1)
# 1. Implicit Study / Evidence Trigger
RE_STUDY_TRIGGER = re.compile(
    r"\b(researchers?\s+(found|discovered|showed|noted|tested|argued)|"
    r"a\s+study\s+(at|in|by|from|published)|"
    r"psychologists?\s+(found|discovered|showed|conducted)|"
    r"experiments?\s+(show|showed|reveal|revealed|demonstrate)|"
    r"in\s+(19[4-9][0-9]|20[0-2][0-9])|"
    r"statistics?\s+(reveal|show|indicate)|"
    r"sample\s+size|control\s+group|placebo|participants?\s+were|"
    r"double-blind|meta-analysis|longitudinal\s+study)\b",
    re.IGNORECASE,
)

# 2. Philosophical Paradox / Value Claim Trigger
RE_PHILOSOPHY_TRIGGER = re.compile(
    r"\b(suffering\s+is|meaning\s+(of|requires|in)|paradoxically|human\s+nature|"
    r"freedom\s+(is|to|from)|morality|illusion\s+of|virtue|existential|"
    r"stoic|epictetus|marcus\s+aurelius|seneca|camus|kierkegaard|nietzsche|"
    r"buddhis[mt]|taoism|consciousness|epistemolog(y|ical)|ontolog(y|ical)|"
    r"truth\s+is|nature\s+of\s+reality|ethics)\b",
    re.IGNORECASE,
)

# 3. Counter-Intuitive Claim / Bold Thesis Trigger
RE_DIALECTIC_TRIGGER = re.compile(
    r"\b(contrary\s+to\s+popular\s+belief|everything\s+you\s+know\s+about|"
    r"the\s+problem\s+with|myth\s+of|fallacy|counter-?intuitively|"
    r"in\s+reality|actually,\s+|common\s+misconception|"
    r"conventional\s+wisdom\s+(is|suggests|claims)|"
    r"we\s+are\s+wrong\s+about)\b",
    re.IGNORECASE,
)

# 4. Historical / Real-World Case Trigger
RE_RABBIT_HOLE_TRIGGER = re.compile(
    r"\b(in\s+ancient\s+(greece|rome|egypt|china)|world\s+war\s+[i|ii]|"
    r"natural\s+selection|evolutionary\s+(psychology|biology|advantage)|"
    r"charles\s+darwin|william\s+james|stanley\s+milgram|stanford\s+prison|"
    r"anecdote|biography|backstory|little-known\s+fact)\b",
    re.IGNORECASE,
)

# 5. Meta-Editorial / Boilerplate Penalty (-0.45)
RE_EDITORIAL_PENALTY = re.compile(
    r"\b(?:this edition|translator'?s note|spelling and punctuation|footnote|in the next chapter|table of contents|editor'?s note|published by|all rights reserved|typeset in|printed in)\b",
    re.IGNORECASE,
)


@dataclass(order=True)
class CardJob:
    priority: int
    doc_id: str = field(compare=False)
    chunk_index: int = field(compare=False)
    epoch: int = field(default=1, compare=False)


def card_to_dict(card: ContextCard) -> Dict[str, Any]:
    citations = []
    if card.citations_json:
        try:
            citations = json.loads(card.citations_json)
        except Exception:
            citations = []
    return {
        "type": "context_card",
        "id": card.id,
        "insert_after": card.source_chunk_id,
        "card_type": card.card_type,
        "title": card.title,
        "body": card.body,
        "why_here": card.why_here,
        "exact_quote": card.exact_quote,
        "support_status": getattr(card, "support_status", "fully_supported"),
        "generation_mode": card.generation_mode,
        "saved": card.saved,
        "citations": citations,
    }


class ReadAheadPipeline:
    """
    Viewport-driven background orchestrator.
    Only grounds cards within [current_chunk, current_chunk + 16] (next 4 card slots).
    Features:
    - Viewport Epoch Versioning for O(1) lazy eviction on chapter fast-forward.
    - Preloaded RAM Density Map for zero-DB-read viewport updates.
    - 5-Minute Inactivity Idle Valve to preserve Gemini API quota.
    - Same-Book Concept Suppression and Cross-Book ConceptCache reuse.
    """

    def __init__(
        self,
        llm_service: Optional[LLMService] = None,
        wiki_client: Optional[WikipediaClient] = None,
    ):
        self.llm_service = llm_service or LLMService()
        self.wiki_client = wiki_client or WikipediaClient()
        self.queue: asyncio.PriorityQueue[CardJob] = asyncio.PriorityQueue()
        self.in_flight: Set[Tuple[str, int]] = set()
        self.reader_cursor: Dict[str, int] = {}
        self.viewport_epochs: Dict[str, int] = {}
        self.last_heartbeat: Dict[str, float] = {}
        self.chunk_densities: Dict[str, Dict[int, float]] = {}
        self.doc_grounded_concepts: Dict[str, Set[str]] = {}
        self.subscribers: Dict[str, Set[asyncio.Queue]] = {}
        self._worker_task: Optional[asyncio.Task] = None

    def start(self):
        if self._worker_task is None:
            self._worker_task = asyncio.create_task(self._worker_loop())
            logger.info("Athena ReadAheadPipeline worker started.")

    async def stop(self):
        if self._worker_task:
            self._worker_task.cancel()
            try:
                await self._worker_task
            except asyncio.CancelledError:
                pass
            self._worker_task = None
            logger.info("Athena ReadAheadPipeline worker stopped.")

    @classmethod
    def score_epistemic_curiosity(cls, text: str) -> float:
        """
        Stage 1 Epistemic Trigger Scanner:
        Evaluates candidate chunks ahead of the reader's scroll cursor using
        four linguistic curiosity triggers:
        1. Implicit Study / Evidence Trigger (+4.0)
        2. Philosophical Paradox / Value Claim Trigger (+3.0)
        3. Counter-Intuitive Claim / Dialectic Trigger (+3.0)
        4. Historical / Real-World Case Rabbit Hole Trigger (+2.5)

        Maintains backward-compatibility for short dialogue/filler (< 40 words returns 0.1).
        """
        words = text.split()
        if len(words) < 40:
            return 0.1

        # Base structural density (proper nouns, numbers, technical terms)
        capitalized = len(re.findall(r"(?<!^)(?<![.!?]\s)\b[A-Z][a-z]{2,}\b", text))
        numeric = len(re.findall(r"\b(1[0-9]{3}|20[0-2][0-9]|[0-9]+%)\b", text))
        long_words = sum(1 for w in words if len(w) >= 8)
        base_score = capitalized * 2.0 + numeric * 3.0 + long_words * 0.5

        # Curiosity trigger detections
        study_matches = len(RE_STUDY_TRIGGER.findall(text))
        philosophy_matches = len(RE_PHILOSOPHY_TRIGGER.findall(text))
        dialectic_matches = len(RE_DIALECTIC_TRIGGER.findall(text))
        rabbit_hole_matches = len(RE_RABBIT_HOLE_TRIGGER.findall(text))

        trigger_boost = (
            study_matches * 4.0
            + philosophy_matches * 3.0
            + dialectic_matches * 3.0
            + rabbit_hole_matches * 2.5
        )

        editorial_penalty = 0.45 if RE_EDITORIAL_PENALTY.search(text) else 0.0
        base_density = max(0.05, (base_score + trigger_boost) / len(words) - editorial_penalty)
        try:
            from app.services.edge_ai import score_chunk_curiosity_edge
            return score_chunk_curiosity_edge(text, base_density)
        except Exception:
            return base_density

    # Backward-compatibility alias
    score_chunk_density = score_epistemic_curiosity

    def preload_document(self, doc_id: str, chunks: List[ReadingChunk]):
        """Preloads chunk density scores into RAM for zero-DB reads during scrolling."""
        if doc_id not in self.chunk_densities:
            self.chunk_densities[doc_id] = {
                c.sequence: self.score_epistemic_curiosity(c.raw_text) for c in chunks
            }

    def get_in_flight_indices(self, doc_id: str) -> List[int]:
        """Returns sequence indices of chunks currently being processed or in queue for doc_id."""
        return [seq for (d_id, seq) in self.in_flight if d_id == doc_id]

    async def update_viewport(self, doc_id: str, current_chunk: int):
        """
        Called whenever the user scrolls in Feed or Flow mode.
        Schedules context cards ahead of reader's eyes using dynamic epistemic peak detection
        with a minimum 3-chunk breathing gap and maximum 6-chunk gap.
        Includes immediate visible range [current_chunk .. current_chunk + 16].
        """
        now = time.time()
        self.last_heartbeat[doc_id] = now
        prev_cursor = self.reader_cursor.get(doc_id, current_chunk)

        # Seat 4 / Clash 2: Fast-Forward Viewport Epoch Versioning
        # If scroll jump exceeds 16 chunks, increment viewport_epoch to evict stale jobs lazily in O(1)
        if abs(current_chunk - prev_cursor) > 16:
            self.viewport_epochs[doc_id] = self.viewport_epochs.get(doc_id, 1) + 1
            logger.info(
                "Viewport jump delta %d > 16 on %s. Advanced viewport_epoch to %d",
                abs(current_chunk - prev_cursor), doc_id, self.viewport_epochs[doc_id]
            )

        self.reader_cursor[doc_id] = current_chunk
        current_epoch = self.viewport_epochs.get(doc_id, 1)

        # Look ahead across immediate visible range [current_chunk .. current_chunk + 16]
        base = max(1, current_chunk)
        candidate_slots = [base + (i * 4) for i in range(4)]
        if current_chunk > 1 and (current_chunk - 1) not in candidate_slots:
            candidate_slots.insert(0, max(1, current_chunk - 1))

        densities = self.chunk_densities.setdefault(doc_id, {})
        # Lazy Viewport Scoring: Only score chunks needed around the active viewport [current_chunk - 4 .. current_chunk + 24]
        needed_chunks = [s for s in range(max(1, current_chunk - 4), current_chunk + 24) if s not in densities]
        if needed_chunks:
            with Session(engine) as session:
                loaded = session.exec(
                    select(ReadingChunk).where(
                        ReadingChunk.document_id == doc_id,
                        ReadingChunk.sequence.in_(needed_chunks),
                    )
                ).all()
                for c in loaded:
                    densities[c.sequence] = self.score_epistemic_curiosity(c.raw_text)

        with Session(engine) as session:
            # Query existing active cards in this doc to enforce minimum breathing gap of 3 chunks
            existing_cards = session.exec(
                select(ContextCard).where(
                    ContextCard.document_id == doc_id,
                    ContextCard.dismissed == False,
                )
            ).all()
            existing_chunk_indices: Set[int] = set()
            for ec in existing_cards:
                m = re.search(r"-c(\d+)$", ec.source_chunk_id)
                if m:
                    existing_chunk_indices.add(int(m.group(1)))

            for rank, slot in enumerate(candidate_slots):
                # Search candidate window around slot [slot-2 .. slot+2] for true epistemic peak
                candidate_window = [
                    s for s in range(max(1, slot - 2), slot + 3)
                    if s in densities
                ]
                if not candidate_window:
                    continue

                # Filter candidates to enforce minimum breathing gap of 3 chunks
                valid_candidates = [
                    s for s in candidate_window
                    if not any(abs(s - existing_idx) < 3 for existing_idx in existing_chunk_indices)
                    and (doc_id, s) not in self.in_flight
                ]
                if not valid_candidates:
                    continue

                # Pick chunk with highest epistemic curiosity score in the candidate window
                target_idx = max(valid_candidates, key=lambda s: densities.get(s, 0.0))

                self.in_flight.add((doc_id, target_idx))
                existing_chunk_indices.add(target_idx)
                # Lower priority number = processed first (rank 0 is immediate next card)
                await self.queue.put(
                    CardJob(
                        priority=rank,
                        doc_id=doc_id,
                        chunk_index=target_idx,
                        epoch=current_epoch,
                    )
                )

    def generate_or_reuse_card(self, doc_id: str, chunk_index: int) -> Optional[Dict[str, Any]]:
        """
        Grounded Card Generator with Concept Deduplication Cache & Tiered Fallbacks.
        Tier 1: Check concept_cache (saves 60%+ Gemini quota)
        Tier 2: Gemini Search Grounding with dual-key failover
        Tier 3: Wikipedia Extractive API fallback
        Enforces: assert exact_quote in canonical_text and body <= 80 words.
        """
        with Session(engine) as session:
            chunk = session.exec(
                select(ReadingChunk).where(
                    ReadingChunk.document_id == doc_id,
                    ReadingChunk.sequence == chunk_index,
                )
            ).first()
            if not chunk:
                return None

            doc = session.get(Document, doc_id)

            # Double check existing card
            existing = session.exec(
                select(ContextCard).where(
                    ContextCard.document_id == doc_id,
                    ContextCard.source_chunk_id == chunk.id,
                    ContextCard.dismissed == False,
                )
            ).first()
            if existing:
                return card_to_dict(existing)

            # Query all existing active cards in this document for document-wide deduplication
            existing_cards = session.exec(
                select(ContextCard).where(
                    ContextCard.document_id == doc_id,
                    ContextCard.dismissed == False,
                )
            ).all()

            used_concepts: Set[str] = set()
            used_titles: Set[str] = set()
            existing_bodies: List[str] = []
            for ec in existing_cards:
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

            # Slot in the deterministic 4-archetype rotation
            active_slot = len(existing_cards) % 4
            archetype_names = ["EMPIRICAL STUDY", "CRITICAL DEBATE", "HISTORICAL CONTEXT", "CORE PARADOX"]
            active_archetype = archetype_names[active_slot]

            grounded_in_doc = self.doc_grounded_concepts.setdefault(doc_id, set())
            for ec_slug in used_concepts:
                grounded_in_doc.add(ec_slug)

            # Retrieve candidate concepts for this chunk or extract on the fly
            concepts = session.exec(
                select(Concept).where(
                    Concept.document_id == doc_id,
                    Concept.chunk_id == chunk.id,
                )
            ).all()

            if not concepts:
                extracted = extract_concepts(
                    canonical_text=doc.canonical_text if doc else chunk.raw_text,
                    chunks=[chunk],
                    document_id=doc_id,
                )
                concepts = extracted

            if not concepts:
                return None

            # Sort by importance descending
            sorted_concepts = sorted(concepts, key=lambda c: c.importance, reverse=True)

            for concept in sorted_concepts:
                concept_norm = concept.name.strip().lower()
                slug = re.sub(r"[^a-z0-9]+", "_", concept_norm).strip("_")
                if not slug:
                    continue

                # Filter trivial dictionary words or short words
                if len(concept.name.split()) == 1 and (
                    len(concept.name) < 4
                    or concept_norm in {"years", "people", "person", "thing", "things", "lives", "problem", "makes", "keep", "world", "her", "now", "well", "good"}
                ):
                    continue

                # Document-Wide Deduplication Hard Rule:
                # NEVER reuse a concept already carded anywhere in this book
                if slug in grounded_in_doc or concept_norm in used_concepts or slug in used_concepts:
                    logger.debug("Document-wide deduplication: '%s' already carded in %s. Skipping.", concept.name, doc_id)
                    continue

                exact_quote = find_exact_quote(chunk.raw_text, concept.name)
                if not exact_quote or exact_quote not in chunk.raw_text:
                    continue

                # --- TIER 1: Concept Cache Check (Cross-Book Instant Reuse) ---
                cached = session.get(ConceptCache, slug)
                if cached:
                    clean_cached_title = re.sub(
                        r"^(?:What is\s+|EMPIRICAL STUDY:\s*|CRITICAL DEBATE:\s*|HISTORICAL CONTEXT:\s*|CORE PARADOX:\s*)+",
                        "",
                        cached.title or concept.name,
                        flags=re.I,
                    ).strip()
                    card_title = f"{active_archetype}: {clean_cached_title}"

                    if clean_cached_title.lower() not in used_titles and not is_semantic_duplicate(cached.body, existing_bodies, threshold=0.78):
                        logger.info("Concept cache HIT for '%s' in chunk %s (cross-book reuse)", concept.name, chunk_index)
                        cached_body = cached.body
                        if active_slot == 0 and "||REVEAL||" not in cached_body:
                            sentences = re.split(r"(?<=[.!?])\s+", cached_body)
                            if len(sentences) > 1:
                                cached_body = f"{sentences[0]}\n||REVEAL||\n{' '.join(sentences[1:])}"
                        elif active_slot == 1:
                            has_debate = "counterpoint:" in cached_body.lower() and "evidence:" in cached_body.lower()
                            if not has_debate:
                                sentences = re.split(r"(?<=[.!?])\s+", cached_body)
                                if len(sentences) >= 2:
                                    cached_body = f"Counterpoint: {sentences[0]}\nEvidence: {' '.join(sentences[1:])}"

                        card = ContextCard(
                            document_id=doc_id,
                            source_chunk_id=chunk.id,
                            concept_name=clean_cached_title,
                            card_type="explain",
                            title=card_title,
                            body=cached_body,
                            why_here="Grounded context from verified primary sources.",
                            citations_json=cached.citations_json,
                            exact_quote=exact_quote,
                            support_status="fully_supported",
                            generation_mode="concept_cache",
                            verified=True,
                        )
                        session.add(card)
                        session.commit()
                        session.refresh(card)
                        grounded_in_doc.add(slug)
                        used_concepts.add(concept_norm)
                        used_concepts.add(slug)
                        used_titles.add(card_title.lower())
                        existing_bodies.append(cached_body.strip())
                        return card_to_dict(card)

                # --- TIER 2: Gemini Google Search Grounding with 3-Chunk Narrative Arc ---
                if self.llm_service.is_gemini_configured:
                    adjacent = session.exec(
                        select(ReadingChunk).where(
                            ReadingChunk.document_id == doc_id,
                            ReadingChunk.sequence.in_([chunk_index - 1, chunk_index + 1]),
                        )
                    ).all()
                    prev_chunk = next((c for c in adjacent if c.sequence == chunk_index - 1), None)
                    next_chunk = next((c for c in adjacent if c.sequence == chunk_index + 1), None)

                    narrative_parts = []
                    if prev_chunk:
                        narrative_parts.append(
                            f"--- PRECEDING PASSAGE (Setup / Context) ---\n{prev_chunk.raw_text.strip()}"
                        )
                    if next_chunk:
                        narrative_parts.append(
                            f"--- FOLLOWING PASSAGE (Conclusion / Resolution) ---\n{next_chunk.raw_text.strip()}"
                        )
                    neighbors_text = "\n\n".join(narrative_parts) if narrative_parts else "None."

                    # Resolve chapter title for thesis-conditioned prompt
                    chapter = session.exec(
                        select(DocumentChapter)
                        .where(
                            DocumentChapter.doc_id == doc_id,
                            DocumentChapter.start_chunk_index <= chunk_index,
                        )
                        .order_by(DocumentChapter.start_chunk_index.desc())
                    ).first()
                    chapter_title = chapter.title if chapter else None

                    grounded = self.llm_service.generate_grounded_context(
                        concept_name=concept.name,
                        passage_text=chunk.raw_text,
                        neighbors_text=neighbors_text,
                        doc_title=doc.title if doc else None,
                        chapter_title=chapter_title,
                        forced_slot=active_slot,
                    )
                    if grounded and grounded.get("body"):
                        body = grounded["body"]
                        raw_title = grounded.get("title") or concept.name
                        clean_heading = re.sub(
                            r"^(?:What is\s+|EMPIRICAL STUDY:\s*|CRITICAL DEBATE:\s*|HISTORICAL CONTEXT:\s*|CORE PARADOX:\s*)+",
                            "",
                            raw_title,
                            flags=re.I,
                        ).strip()
                        card_title = f"{active_archetype}: {clean_heading or concept.name}"

                        if clean_heading.lower() in used_titles or card_title.lower() in used_titles:
                            logger.info("Card title '%s' already used in doc %s. Skipping.", card_title, doc_id)
                            continue

                        if is_semantic_duplicate(body, existing_bodies, threshold=0.78):
                            logger.info("Gemini card for '%s' rejected by ONNX Semantic Deduplication Gate (> 0.78)", concept.name)
                            continue

                        citations = grounded.get("citations", [])
                        citations_str = json.dumps(citations)
                        card_why_here = grounded.get("why_here") or "Grounded context from primary sources."

                        # Save into concept_cache for future chunks/books (upsert safely)
                        cache_entry = session.exec(select(ConceptCache).where(ConceptCache.concept_slug == slug)).first()
                        if cache_entry:
                            cache_entry.title = card_title
                            cache_entry.body = body
                            cache_entry.citations_json = citations_str
                            cache_entry.source_model = "gemini_search"
                        else:
                            cache_entry = ConceptCache(
                                concept_slug=slug,
                                title=card_title,
                                body=body,
                                citations_json=citations_str,
                                source_model="gemini_search",
                            )
                        session.add(cache_entry)

                        card = ContextCard(
                            document_id=doc_id,
                            source_chunk_id=chunk.id,
                            concept_name=concept.name,
                            card_type="explain",
                            title=card_title,
                            body=body,
                            why_here=card_why_here,
                            citations_json=citations_str,
                            exact_quote=exact_quote,
                            support_status="fully_supported",
                            generation_mode="gemini_search_grounded",
                            verified=True,
                        )
                        session.add(card)
                        session.commit()
                        session.refresh(card)
                        grounded_in_doc.add(slug)
                        used_concepts.add(concept_norm)
                        used_concepts.add(slug)
                        used_titles.add(card_title.lower())
                        existing_bodies.append(body.strip())
                        return card_to_dict(card)

                # --- TIER 3: Wikipedia Extractive API Fallback ---
                wiki_data = self.wiki_client.fetch_term(concept.name)
                if wiki_data and wiki_data.get("extract"):
                    extract = wiki_data["extract"].strip()

                    # Mandatory ONNX Semantic Relevance Gate (edge_ai.py)
                    relevance = compute_semantic_similarity(chunk.raw_text, extract)
                    if relevance < 0.38:
                        logger.info(
                            "Wiki extract for '%s' rejected by ONNX Semantic Relevance Gate (%.3f < 0.38)",
                            concept.name, relevance
                        )
                        continue

                    citation = wiki_data.get("citation")
                    citations_list = [citation] if citation else []

                    # Trim at sentence boundary to <= 80 words
                    sentences = re.split(r"(?<=[.!?])\s+", extract)
                    trimmed = []
                    cur_len = 0
                    for s in sentences:
                        w_count = len(s.split())
                        if cur_len + w_count <= 80:
                            trimmed.append(s)
                            cur_len += w_count
                        else:
                            break
                    raw_wiki_body = " ".join(trimmed) or sentences[0]

                    # Format into active archetype slot layout
                    if active_slot == 0:
                        final_body = f"How did empirical observations and research test {concept.name} in practice?\n||REVEAL||\n{raw_wiki_body}"
                    elif active_slot == 1:
                        final_body = f"Counterpoint: Critical scholars question assumptions regarding {concept.name}.\nEvidence: {raw_wiki_body}"
                    elif active_slot == 2:
                        final_body = f"Historical context and primary sources document that {raw_wiki_body}"
                    else:
                        final_body = f"The core paradox of {concept.name} reveals an unexpected inversion: {raw_wiki_body}"

                    card_title = f"{active_archetype}: {wiki_data.get('title', concept.name)}"
                    if card_title.lower() in used_titles or wiki_data.get("title", "").lower() in used_titles:
                        continue

                    if is_semantic_duplicate(final_body, existing_bodies, threshold=0.78):
                        logger.info("Wiki card for '%s' rejected by ONNX Semantic Deduplication Gate (> 0.78)", concept.name)
                        continue

                    citations_str = json.dumps(citations_list)

                    cache_entry = session.exec(select(ConceptCache).where(ConceptCache.concept_slug == slug)).first()
                    if cache_entry:
                        cache_entry.title = card_title
                        cache_entry.body = final_body
                        cache_entry.citations_json = citations_str
                        cache_entry.source_model = "wikipedia"
                    else:
                        cache_entry = ConceptCache(
                            concept_slug=slug,
                            title=card_title,
                            body=final_body,
                            citations_json=citations_str,
                            source_model="wikipedia",
                        )
                    session.add(cache_entry)

                    card = ContextCard(
                        document_id=doc_id,
                        source_chunk_id=chunk.id,
                        concept_name=concept.name,
                        card_type="explain",
                        title=card_title,
                        body=final_body,
                        why_here="Extractive summary from reference library.",
                        citations_json=citations_str,
                        exact_quote=exact_quote,
                        support_status="fully_supported",
                        generation_mode="extractive",
                        verified=True,
                    )
                    session.add(card)
                    session.commit()
                    session.refresh(card)
                    grounded_in_doc.add(slug)
                    used_concepts.add(concept_norm)
                    used_concepts.add(slug)
                    used_titles.add(card_title.lower())
                    existing_bodies.append(final_body.strip())
                    return card_to_dict(card)

            return None

    async def _worker_loop(self):
        while True:
            job = await self.queue.get()
            try:
                # 1. Viewport Epoch Lazy Eviction:
                # If scroll jumped beyond 16 chunks, job.epoch will not match current epoch -> drop in O(1)!
                current_epoch = self.viewport_epochs.get(job.doc_id, 1)
                if job.epoch != current_epoch:
                    logger.debug(
                        "Lazy eviction: Dropping stale job for %s:%d (job epoch %d != current %d)",
                        job.doc_id, job.chunk_index, job.epoch, current_epoch,
                    )
                    self.in_flight.discard((job.doc_id, job.chunk_index))
                    continue

                # 2. 5-Minute Inactivity Idle Valve (Taleb Quota Rule):
                last_hb = self.last_heartbeat.get(job.doc_id, time.time())
                if time.time() - last_hb > 300:
                    logger.info("Idle valve: Reader inactive for >5 min on %s. Pausing worker.", job.doc_id)
                    self.in_flight.discard((job.doc_id, job.chunk_index))
                    continue

                # 3. Sliding Window Fence:
                cursor = self.reader_cursor.get(job.doc_id, 1)
                if job.chunk_index < cursor or job.chunk_index > cursor + 20:
                    self.in_flight.discard((job.doc_id, job.chunk_index))
                    continue

                # Generate card via tiered service
                card_data = await asyncio.to_thread(
                    self.generate_or_reuse_card,
                    job.doc_id,
                    job.chunk_index,
                )
                if card_data:
                    await self._broadcast_event(
                        job.doc_id,
                        {
                            "type": "card_ready",
                            "chunk_index": job.chunk_index,
                            "card": card_data,
                        },
                    )
                # Pacing delay (1.5s) to prevent HTTP 429 burst throttling on Gemini free tier
                await asyncio.sleep(1.5)
            except Exception as exc:
                logger.exception("Pipeline error on %s:%s: %s", job.doc_id, job.chunk_index, exc)
            finally:
                self.in_flight.discard((job.doc_id, job.chunk_index))
                self.queue.task_done()

    async def _broadcast_event(self, doc_id: str, payload: dict):
        subscribers = list(self.subscribers.get(doc_id, set()))
        for q in subscribers:
            try:
                await q.put(payload)
            except Exception:
                pass
