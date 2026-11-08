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
    # Mundane and structural book words (§7.1)
    "chapter", "author", "section", "example", "question", "part", "history", "system",
    "process", "page", "book", "reader", "text", "case", "fact", "point", "matter", "idea",
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
    """Extracts high-precision candidate concepts from canonical text."""
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

    # 4. Causal claims, named mechanisms, paradoxes, and phenomena
    claim_pattern = re.compile(
        r"\b([A-Z][a-z]+(?:\s+[a-z]+){0,2}\s+(?:effect|bias|fallacy|paradox|hypothesis|theory|law|syndrome|dilemma|illusion|principle))\b",
        re.IGNORECASE,
    )
    for match in claim_pattern.finditer(canonical_text):
        cl = match.group(1).strip()
        if len(cl) >= 6 and not is_stopword(cl):
            norm = cl.lower()
            candidates[norm] = (cl, "mechanism", 0.92)

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


def detect_passage_flavor(passage: str) -> str:
    """Classifies passage into: scientific_claim, historical_event, human_behavior_or_narrative, philosophical_argument."""
    lowered = passage.lower()

    hist_markers = [
        "century", "war", "emperor", "president", "king", "queen", "empire",
        "treaty", "revolution", "dynasty", "reign", "archival", "in 18", "in 19",
        "in 17", "in 16", "in 15", "in 14", "b.c.", "a.d.", "historian", "battle"
    ]
    if any(m in lowered for m in hist_markers):
        return "historical_event"

    phil_markers = [
        "morality", "ethics", "free will", "consciousness", "epistemol", "metaphys",
        "virtue", "truth", "justice", "existential", "axiom", "ontolog", "teleolog"
    ]
    if any(m in lowered for m in phil_markers):
        return "philosophical_argument"

    narrative_markers = [
        "he said", "she said", "thought to himself", "felt", "whispered", "smiled",
        "cried", "gazed", "walked toward", "character", "relationship", "family",
        "childhood", "emotion", "anxiety", "fear", "habit", "behavior", "psychology"
    ]
    if any(m in lowered for m in narrative_markers):
        return "human_behavior_or_narrative"

    return "scientific_claim"


def build_search_query_for_concept(concept_name: str, passage: str = "", archetype: str = "") -> str:
    """Constructs a high-precision academic / web search query targeting empirical studies,
    counter-arguments, or historical receipts for a concept with adaptive genre routing.
    """
    clean_name = re.sub(r"[^\w\s-]", "", concept_name).strip()
    arch_upper = archetype.upper()
    flavor = detect_passage_flavor(passage) if passage else "scientific_claim"

    if "EMPIRICAL" in arch_upper:
        if flavor == "human_behavior_or_narrative":
            return f"{clean_name} behavioral psychology cognitive science experiment findings"
        elif flavor == "historical_event":
            return f"{clean_name} historical data demographic economic study findings"
        return f"{clean_name} empirical study experiment data findings"

    elif "DEBATE" in arch_upper or "CRITICAL" in arch_upper:
        if flavor == "historical_event":
            return f"{clean_name} historian dispute declassified records controversy"
        elif flavor == "human_behavior_or_narrative":
            return f"{clean_name} psychological counterpoint cognitive critique"
        return f"{clean_name} critique debate counterpoint controversy"

    elif "PARADOX" in arch_upper:
        if flavor == "human_behavior_or_narrative":
            return f"{clean_name} behavioral paradox decision bias contradiction"
        return f"{clean_name} paradox counter-intuitive dilemma contradiction"

    elif "HISTORICAL" in arch_upper:
        if flavor == "human_behavior_or_narrative":
            return f"{clean_name} historical origin case real life inspiration"
        return f"{clean_name} history archival origin case study"

    return f"{clean_name} research study analysis"


def extract_salient_concept_4tier(passage: str, section_texts: Optional[List[str]] = None) -> str:
    """
    Non-Fiction & Multi-Genre 4-Tier Concept Extractor (FP-12).
    Never returns empty or None on an eligible conceptual chunk! Fall back through:
      1) Multi-word capitalized phrase (2–4 words)
      2) Single non-initial capitalized entity (>= 4 letters)
      3) Top section-recurring non-stopword conceptual term (TF-IDF / frequency >= 2 in section)
      4) Strongest noun phrase / domain bigram in the passage.
    """
    if not passage or not passage.strip():
        return "Core Concept"

    # 1. Multi-word capitalized phrase (2-4 words)
    phrase_pattern = re.compile(r"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}\b")
    for m in phrase_pattern.finditer(passage):
        ph = m.group(0).strip()
        words = ph.lower().split()
        if 2 <= len(words) <= 4 and not any(w in STOPWORDS for w in words):
            return ph

    # 2. Single non-initial capitalized entity (>= 4 letters)
    entity_pattern = re.compile(r"(?<![.!?]\s)\b[A-Z][a-z]{3,}\b")
    for m in entity_pattern.finditer(passage):
        ent = m.group(0).strip()
        if ent.lower() not in STOPWORDS:
            return ent

    # 3. Top section-recurring non-stopword conceptual term (frequency >= 2 in section)
    if section_texts:
        section_counts = Counter()
        for st in section_texts:
            tokens = [w.lower() for w in re.findall(r"\b[A-Za-z]{4,}\b", st) if w.lower() not in STOPWORDS]
            section_counts.update(tokens)
        passage_tokens = set(w.lower() for w in re.findall(r"\b[A-Za-z]{4,}\b", passage) if w.lower() not in STOPWORDS)
        best_word = None
        max_c = 1
        for pt in passage_tokens:
            if section_counts[pt] > max_c:
                max_c = section_counts[pt]
                best_word = pt
        if best_word:
            return best_word.capitalize()

    # 4. Strongest noun phrase / domain bigram in the passage
    content_words = [w for w in re.findall(r"\b[A-Za-z]{4,}\b", passage) if w.lower() not in STOPWORDS]
    if len(content_words) >= 2:
        for i in range(len(content_words) - 1):
            pair = f"{content_words[i]} {content_words[i+1]}"
            if pair.lower() in passage.lower():
                return pair
        return f"{content_words[0]} {content_words[1]}"
    elif content_words:
        return content_words[0]

    return "Core Thesis"


