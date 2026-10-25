import re
from collections import Counter
from typing import List, Optional
import yake

from app.models import Concept, ReadingChunk

STOPWORDS = {
    "about", "above", "after", "again", "against", "all", "also", "and", "any", "are",
    "because", "been", "before", "being", "below", "between", "both", "but", "by", "could",
    "did", "does", "doing", "down", "during", "each", "even", "few", "first", "for",
    "from", "further", "had", "has", "have", "having", "here", "how", "into", "itself",
    "just", "more", "most", "other", "only", "over", "same", "should", "some", "such",
    "than", "that", "the", "their", "theirs", "them", "themselves", "then", "there",
    "these", "they", "this", "those", "through", "under", "until", "very", "were",
    "what", "when", "where", "which", "while", "who", "whom", "why", "with", "would",
    "your", "yours", "yourself", "yourselves",
    # Generic conversational nouns/verbs that cause irrelevant wiki lookups
    "people", "person", "thing", "things", "years", "time", "lives", "life", "world",
    "makes", "keep", "feels", "feel", "good", "well", "man", "many", "much", "said",
    "says", "like", "way", "get", "come", "make", "know", "see", "take", "give",
    "look", "think", "tell", "become", "leave", "feel good", "feels good", "day", "days",
}

COMMON_ACRONYM_EXCLUSIONS = {"PDF", "URL", "HTTP", "HTTPS", "HTML", "USA", "THE", "AND", "FOR"}


def is_stopword(text: str) -> bool:
    tokens = text.lower().strip().split()
    return all(tok in STOPWORDS for tok in tokens)


def extract_concepts(
    canonical_text: str,
    chunks: List[ReadingChunk],
    document_id: str,
) -> List[Concept]:
    """Extracts high-precision candidate concepts from canonical text
    per CLAUDE.md §7.1.
    """
    if not canonical_text or not chunks:
        return []

    # Map of normalized_term -> (display_name, type, importance)
    candidates: dict[str, tuple[str, str, float]] = {}

    # 1. YAKE keywords (lan="en", n=3, top=40)
    try:
        kw_extractor = yake.KeywordExtractor(lan="en", n=3, top=40)
        yake_kws = kw_extractor.extract_keywords(canonical_text)
        for term, score in yake_kws:
            cleaned = term.strip()
            if len(cleaned) < 4:
                continue
            if is_stopword(cleaned):
                continue
            importance = 1.0 / (1.0 + float(score))
            norm = cleaned.lower()
            candidates[norm] = (cleaned, "yake", importance)
    except Exception:
        pass

    # 2. Acronyms \b[A-Z]{2,6}\b
    acronym_matches = re.findall(r"\b[A-Z]{2,6}\b", canonical_text)
    for acr in set(acronym_matches):
        if acr in COMMON_ACRONYM_EXCLUSIONS:
            continue
        if len(acr) < 2:
            continue
        norm = acr.lower()
        if norm not in candidates:
            candidates[norm] = (acr, "acronym", 0.5)

    # 3. Capitalized multi-word phrases (2–4 words) that appear >= 2 times
    phrase_pattern = re.compile(r"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}\b")
    all_phrases = phrase_pattern.findall(canonical_text)
    phrase_counts = Counter(all_phrases)

    for phrase, count in phrase_counts.items():
        if count >= 2:
            cleaned = phrase.strip()
            if len(cleaned) < 4:
                continue
            if is_stopword(cleaned):
                continue
            norm = cleaned.lower()
            if norm not in candidates:
                candidates[norm] = (cleaned, "entity", 0.5)

    # Apply strict filters:
    # - >= 4 chars (unless acronym >= 3 chars)
    # - single words must be >= 5 chars and either acronyms, mid-sentence capitalized, or appear >= 2 times
    # - drop small English stopword set
    filtered_candidates: list[tuple[str, str, float]] = []

    for norm, (display_name, c_type, importance) in candidates.items():
        if is_stopword(display_name):
            continue

        words = display_name.split()
        if len(words) == 1:
            word = words[0]
            is_acronym = word.isupper() and 2 <= len(word) <= 6
            if not is_acronym:
                if len(word) < 5:
                    continue
                mid_sentence = bool(re.search(r"[a-z,]\s+" + re.escape(word) + r"\b", canonical_text))
                freq = len(re.findall(r"\b" + re.escape(word) + r"\b", canonical_text, re.IGNORECASE))
                if not (mid_sentence or freq >= 2):
                    continue
        else:
            if len(display_name) < 4:
                continue

        filtered_candidates.append((display_name, c_type, importance))

    # Sort descending by importance
    filtered_candidates.sort(key=lambda x: x[2], reverse=True)

    # Locate chunk of FIRST whole-word, case-insensitive occurrence
    concepts: List[Concept] = []
    seen_terms: set[str] = set()

    for display_name, c_type, importance in filtered_candidates:
        norm = display_name.lower()
        if norm in seen_terms:
            continue
        seen_terms.add(norm)

        # Find first occurrence offset in canonical text
        match = re.search(r"\b" + re.escape(display_name) + r"\b", canonical_text, re.IGNORECASE)
        chunk_id: Optional[str] = None

        if match:
            first_offset = match.start()
            for ch in chunks:
                if ch.start_offset <= first_offset < ch.end_offset:
                    chunk_id = ch.id
                    break

        # Fallback search directly in chunk texts if offset fell on boundary
        if not chunk_id:
            for ch in chunks:
                if re.search(r"\b" + re.escape(display_name) + r"\b", ch.raw_text, re.IGNORECASE):
                    chunk_id = ch.id
                    break

        if chunk_id:
            concepts.append(
                Concept(
                    document_id=document_id,
                    chunk_id=chunk_id,
                    name=display_name,
                    type=c_type,
                    importance=round(importance, 4),
                    status="candidate",
                )
            )

    return concepts
