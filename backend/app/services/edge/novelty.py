"""
Edge AI Novelty & Epistemic Curiosity Engine (FastEmbed ONNX + Vector Gating).
"""

import logging
import re
from typing import Any, List, Optional

logger = logging.getLogger(__name__)

PROTO_FRONT_MATTER = "Title page series editor credits translated by publisher imprint ISBN copyright all rights reserved dedication cataloging"
PROTO_NARRATIVE_PROSE = "The author discusses the fundamental philosophical argument and historical development of the narrative prose."
PROTO_EMPIRICAL_STUDY = "Scientific experiment psychological study researchers discovered statistical evidence sample size clinical trial participants control group"
PROTO_PHILOSOPHY_PARADOX = "Philosophical paradox human nature stoic virtue existential meaning moral duty contradiction illusion ethics consciousness"
PROTO_HISTORICAL_CASE = "Historical biography ancient battle emperor roman empire real-world event century archival backstory anecdote"

_embedder_instance = None
_embedder_failed = False
_proto_vectors = None


def _get_embedder():
    """Lazy singleton loader for fastembed ONNX embedder with graceful fallback."""
    global _embedder_instance, _embedder_failed
    if _embedder_instance is not None:
        return _embedder_instance
    if _embedder_failed:
        return None

    try:
        from fastembed import TextEmbedding
        from app.config import FASTEMBED_CACHE_DIR
        _embedder_instance = TextEmbedding(
            model_name="BAAI/bge-small-en-v1.5",
            cache_dir=str(FASTEMBED_CACHE_DIR),
        )
        return _embedder_instance
    except Exception as e:
        logger.warning("FastEmbed not available, falling back to pure mathematical filters: %s", e)
        _embedder_failed = True
        return None


def _get_proto_vectors():
    """Lazily computes prototype ONNX embeddings."""
    global _proto_vectors
    if _proto_vectors is not None:
        return _proto_vectors

    embedder = _get_embedder()
    if embedder is None:
        return None

    try:
        texts = [
            PROTO_FRONT_MATTER,
            PROTO_NARRATIVE_PROSE,
            PROTO_EMPIRICAL_STUDY,
            PROTO_PHILOSOPHY_PARADOX,
            PROTO_HISTORICAL_CASE,
        ]
        vecs = list(embedder.embed(texts))
        _proto_vectors = {
            "front_matter": vecs[0],
            "narrative_prose": vecs[1],
            "empirical": vecs[2],
            "philosophy": vecs[3],
            "history": vecs[4],
        }
        return _proto_vectors
    except Exception as e:
        logger.warning("FastEmbed prototype vector computation failed: %s", e)
        return None


def _cosine_similarity(v1, v2) -> float:
    import numpy as np
    dot = np.dot(v1, v2)
    norm1 = np.linalg.norm(v1)
    norm2 = np.linalg.norm(v2)
    if norm1 == 0 or norm2 == 0:
        return 0.0
    return float(dot / (norm1 * norm2))


RE_EDITORIAL_PENALTY_EDGE = re.compile(
    r"\b(?:this edition|translator'?s note|spelling and punctuation|footnote|in the next chapter|table of contents|editor'?s note|published by|all rights reserved|typeset in|printed in)\b",
    re.IGNORECASE,
)


def score_chunk_curiosity_edge(text: str, regex_base_score: float) -> float:
    """
    Blends fast ONNX prototype similarity with regex curiosity score
    so Athena accurately identifies epistemic peaks across all genres.
    Penalizes dry meta-editorial chunks by -0.45 to skip non-reading boilerplate.
    """
    if RE_EDITORIAL_PENALTY_EDGE.search(text):
        regex_base_score = max(0.05, regex_base_score - 0.45)

    proto_vecs = _get_proto_vectors()
    embedder = _get_embedder()
    if proto_vecs is None or embedder is None:
        return regex_base_score

    try:
        sample = text[:500]
        vec = list(embedder.embed([sample]))[0]

        sim_emp = _cosine_similarity(vec, proto_vecs["empirical"])
        sim_phil = _cosine_similarity(vec, proto_vecs["philosophy"])
        sim_hist = _cosine_similarity(vec, proto_vecs["history"])

        max_semantic_sim = max(sim_emp, sim_phil, sim_hist)
        semantic_boost = max(0.0, (max_semantic_sim - 0.40) * 1.5)
        return regex_base_score + semantic_boost
    except Exception as e:
        logger.debug("Edge AI curiosity scoring fallback: %s", e)
        return regex_base_score


BANNED_GENERIC_SLOP_PHRASES: List[str] = [
    "in this passage",
    "in the passage",
    "the author explains",
    "the author highlights",
    "the author argues",
    "the author reminds",
    "the author emphasizes",
    "the author discusses",
    "this passage illustrates",
    "this passage reflects",
    "this passage serves",
    "reminds the reader",
    "is a central theme",
    "underscores the importance",
    "highlights the importance",
    "serves as a reminder",
    "studies have shown that",
    "was a famous philosopher",
    "was a philosopher who lived",
    "was a roman emperor",
]


def evaluate_card_novelty(
    chunk_text: str,
    card_title: str,
    card_body: str,
) -> dict:
    """
    Evaluates a generated Context Card for High Bayesian Surprise & Orthogonal Information Gain:
    1. Banned Generic Slop Phrases Check:
       Blocks lazy AI summary openings ("in this passage", "the author highlights", "studies have shown that").
    2. Novel External Entity & Quantitative Anchor Count (new_entity_count):
       Requires >= 2 new named entities, archival years, or empirical metrics not present in chunk_text.
    3. ONNX Anti-Echo Cosine Similarity (echo_similarity):
       Embeds chunk and card using local FastEmbed (BAAI/bge-small-en-v1.5).
       If echo_similarity > 0.81, the card merely paraphrases the chunk (Semantic Echoing).
    Returns:
       {"passed": bool, "new_entity_count": int, "echo_similarity": float, "reason": str}
    """
    body_clean = (card_body or "").strip()
    chunk_clean = (chunk_text or "").strip()

    if not body_clean:
        return {
            "passed": False,
            "new_entity_count": 0,
            "echo_similarity": 0.0,
            "reason": "Card body is empty.",
        }

    # 1. Banned Generic Slop Phrases Check
    body_lower = body_clean.lower()
    for phrase in BANNED_GENERIC_SLOP_PHRASES:
        if phrase in body_lower:
            return {
                "passed": False,
                "new_entity_count": 0,
                "echo_similarity": 1.0,
                "reason": f"Contains banned generic slop phrase: '{phrase}'",
            }

    # 2. Extract Novel External Entities & Quantitative Anchors
    common_sentence_starters = {
        "the", "this", "that", "these", "those", "when", "what", "where", "which", "who", "why", "how",
        "and", "but", "for", "nor", "yet", "so", "wait", "part", "note", "first", "second", "third",
        "instead", "however", "moreover", "furthermore", "according", "although", "while", "after",
        "before", "with", "without", "from", "into", "during", "revealed", "reveal", "evidence", "counterpoint"
    }

    raw_proper_nouns = re.findall(r"\b[A-Z][a-z]{2,}(?:\s+[A-Z][a-z]{2,})*\b", body_clean)
    valid_proper_nouns = set()
    for noun in raw_proper_nouns:
        words = noun.split()
        if len(words) == 1 and words[0].lower() in common_sentence_starters:
            continue
        valid_proper_nouns.add(noun)

    years = set(re.findall(r"\b(?:1\d{3}|20\d{2}|\d{2,4}\s*(?:AD|BC|BCE|CE))\b", body_clean, re.IGNORECASE))
    sample_sizes = set(re.findall(r"\b(?:N\s*=\s*\d+|\d+(?:,\d{3})*\s+(?:participants|subjects|winners|patients|people|respondents|students))\b", body_clean, re.IGNORECASE))
    percentages = set(re.findall(r"\b\d+(?:\.\d+)?%\b", body_clean))

    all_card_entities = valid_proper_nouns | years | sample_sizes | percentages

    # Filter out entities that appear in chunk_text (case-insensitive)
    chunk_lower = chunk_clean.lower()
    new_entities = set()
    for entity in all_card_entities:
        ent_str = entity.strip()
        if ent_str.lower() not in chunk_lower:
            new_entities.add(ent_str)

    new_entity_count = len(new_entities)

    # 3. ONNX Anti-Echo Cosine Similarity
    echo_similarity = 0.50
    embedder = _get_embedder()
    if embedder is not None and chunk_clean and body_clean:
        try:
            vecs = list(embedder.embed([chunk_clean[:1200], body_clean[:1200]]))
            echo_similarity = round(_cosine_similarity(vecs[0], vecs[1]), 3)
        except Exception as e:
            logger.debug("FastEmbed error during novelty evaluation: %s", e)

    # Hard rejection if echo similarity > 0.81 (1-hop paraphrase echo)
    if echo_similarity > 0.81:
        return {
            "passed": False,
            "new_entity_count": new_entity_count,
            "echo_similarity": echo_similarity,
            "reason": f"Echo similarity {echo_similarity} > 0.81 indicates paraphrase echoing without orthogonal information gain.",
        }

    # Hard admission requirement: new_entity_count >= 2
    if new_entity_count < 2:
        return {
            "passed": False,
            "new_entity_count": new_entity_count,
            "echo_similarity": echo_similarity,
            "reason": f"Insufficient novel external anchors ({new_entity_count} < 2). Card must introduce >= 2 new named entities, years, or empirical metrics not in the passage.",
        }

    return {
        "passed": True,
        "new_entity_count": new_entity_count,
        "echo_similarity": echo_similarity,
        "reason": "High Bayesian Surprise: Sufficient novel anchors and orthogonal information gain.",
    }


def compute_semantic_similarity(text1: str, text2: str) -> float:
    """Computes ONNX cosine similarity between text1 and text2 using FastEmbed (BAAI/bge-small-en-v1.5).
    Falls back gracefully to token-overlap on embedder unavailability.
    """
    if not text1 or not text2:
        return 0.0
    embedder = _get_embedder()
    if embedder is None:
        t1_words = set(re.findall(r"\w+", text1.lower()))
        t2_words = set(re.findall(r"\w+", text2.lower()))
        if not t1_words or not t2_words:
            return 0.0
        return len(t1_words & t2_words) / len(t1_words | t2_words)
    try:
        vecs = list(embedder.embed([text1[:1200], text2[:1200]]))
        return float(_cosine_similarity(vecs[0], vecs[1]))
    except Exception as e:
        logger.debug("FastEmbed error during compute_semantic_similarity: %s", e)
        return 0.5


def is_semantic_duplicate(
    candidate_body: str,
    existing_bodies: List[str],
    threshold: float = 0.78,
) -> bool:
    """Checks if candidate_body has cosine similarity > threshold with ANY existing body in the document.
    Enforces document-wide semantic deduplication.
    """
    if not candidate_body or not existing_bodies:
        return False
    embedder = _get_embedder()
    if embedder is None:
        return False
    try:
        cand_vec = list(embedder.embed([candidate_body[:1200]]))[0]
        for eb in existing_bodies:
            if not eb:
                continue
            eb_vec = list(embedder.embed([eb[:1200]]))[0]
            sim = float(_cosine_similarity(cand_vec, eb_vec))
            if sim > threshold:
                logger.info(
                    "Card candidate rejected as semantic clone: similarity %.3f > %.2f",
                    sim,
                    threshold,
                )
                return True
        return False
    except Exception as e:
        logger.debug("FastEmbed error during is_semantic_duplicate: %s", e)
        return False
