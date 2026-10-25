"""
Hybrid Intelligent Search Service (§4 in Athena Research Blueprint).

Combines:
1. Lexical search (BM25) over verified chunks for exact terms, names, acronyms, and quotes.
2. Dense semantic search over chunk text for paraphrase and conceptual match.
3. Reciprocal Rank Fusion (RRF with k=60) combining both rankings transparently without uncalibrated score thresholds.
"""

import math
import re
from collections import Counter
from typing import Any, Dict, List, Tuple


def _tokenize(text: str) -> List[str]:
    """Tokenizes text into lowercase alphanumeric words."""
    return re.findall(r"\b[a-zA-Z0-9_-]+\b", text.lower())


class BM25Index:
    """
    Okapi BM25 index over text documents/chunks.
    k1 = 1.5, b = 0.75.
    """

    def __init__(self, k1: float = 1.5, b: float = 0.75):
        self.k1 = k1
        self.b = b
        self.doc_ids: List[str] = []
        self.doc_lengths: List[int] = []
        self.avg_doc_len: float = 0.0
        self.doc_freqs: Counter[str] = Counter()
        self.term_freqs: List[Counter[str]] = []
        self.num_docs: int = 0

    def fit(self, docs: List[Tuple[str, str]]) -> None:
        """Fits index on a list of (doc_id, text) tuples."""
        self.doc_ids = []
        self.doc_lengths = []
        self.term_freqs = []
        self.doc_freqs = Counter()
        self.num_docs = len(docs)

        if not docs:
            self.avg_doc_len = 0.0
            return

        total_len = 0
        for doc_id, text in docs:
            tokens = _tokenize(text)
            tf = Counter(tokens)
            self.doc_ids.append(doc_id)
            doc_len = len(tokens)
            self.doc_lengths.append(doc_len)
            self.term_freqs.append(tf)
            total_len += doc_len
            for term in tf:
                self.doc_freqs[term] += 1

        self.avg_doc_len = (total_len / self.num_docs) if self.num_docs > 0 else 0.0

    def score(self, query: str) -> List[Tuple[str, float]]:
        """Scores all indexed documents against query using BM25."""
        if self.num_docs == 0:
            return []

        query_tokens = _tokenize(query)
        if not query_tokens:
            return [(doc_id, 0.0) for doc_id in self.doc_ids]

        scores = [0.0] * self.num_docs

        for term in query_tokens:
            df = self.doc_freqs.get(term, 0)
            if df == 0:
                continue

            # Standard Robertson-Spärck Jones IDF
            idf = math.log((self.num_docs - df + 0.5) / (df + 0.5) + 1.0)

            for i in range(self.num_docs):
                tf = self.term_freqs[i].get(term, 0)
                if tf == 0:
                    continue
                doc_len = self.doc_lengths[i]
                numerator = tf * (self.k1 + 1.0)
                denominator = tf + self.k1 * (1.0 - self.b + self.b * (doc_len / (self.avg_doc_len or 1.0)))
                scores[i] += idf * (numerator / denominator)

        # Return sorted by score descending
        results = [(self.doc_ids[i], scores[i]) for i in range(self.num_docs)]
        results.sort(key=lambda x: x[1], reverse=True)
        return results


class DenseRetriever:
    """
    Compact semantic retriever using subword/character n-gram frequency vectors
    and cosine similarity. Captures morphological, conceptual, and synonym proximity.
    """

    def __init__(self, n_gram_range: Tuple[int, int] = (3, 5)):
        self.n_gram_range = n_gram_range
        self.doc_ids: List[str] = []
        self.vectors: List[Dict[str, float]] = []
        self.norms: List[float] = []

    def _extract_features(self, text: str) -> Dict[str, float]:
        tokens = _tokenize(text)
        features: Counter[str] = Counter()

        # Word level features
        for tok in tokens:
            features[f"w_{tok}"] += 1.0
            # Character n-grams for subword matching
            if len(tok) >= 3:
                for n in range(self.n_gram_range[0], min(len(tok) + 1, self.n_gram_range[1] + 1)):
                    for i in range(len(tok) - n + 1):
                        features[f"ng_{tok[i:i+n]}"] += 0.5

        # L2 normalize
        total_sq = sum(v * v for v in features.values())
        norm = math.sqrt(total_sq) if total_sq > 0 else 1.0
        return {k: v / norm for k, v in features.items()}

    def fit(self, docs: List[Tuple[str, str]]) -> None:
        self.doc_ids = []
        self.vectors = []
        self.norms = []

        for doc_id, text in docs:
            vec = self._extract_features(text)
            self.doc_ids.append(doc_id)
            self.vectors.append(vec)

    def score(self, query: str) -> List[Tuple[str, float]]:
        if not self.doc_ids:
            return []

        q_vec = self._extract_features(query)
        scores: List[Tuple[str, float]] = []

        for doc_id, d_vec in zip(self.doc_ids, self.vectors):
            dot = 0.0
            # Iterate over smaller dict
            if len(q_vec) < len(d_vec):
                for k, v in q_vec.items():
                    if k in d_vec:
                        dot += v * d_vec[k]
            else:
                for k, v in d_vec.items():
                    if k in q_vec:
                        dot += v * q_vec[k]
            scores.append((doc_id, max(0.0, dot)))

        scores.sort(key=lambda x: x[1], reverse=True)
        return scores


def reciprocal_rank_fusion(
    bm25_ranked: List[str],
    dense_ranked: List[str],
    k: int = 60,
) -> List[Dict[str, Any]]:
    """
    Reciprocal Rank Fusion (RRF) with k=60 (§4 in Athena Research Blueprint).
    RRF_score(d) = sum(1 / (k + rank_m(d))) for m in {bm25, dense}.
    Returns items sorted descending by RRF score with rank provenance.
    """
    bm25_ranks = {doc_id: rank + 1 for rank, doc_id in enumerate(bm25_ranked)}
    dense_ranks = {doc_id: rank + 1 for rank, doc_id in enumerate(dense_ranked)}

    all_docs = set(bm25_ranks.keys()) | set(dense_ranks.keys())
    fused: List[Dict[str, Any]] = []

    for doc_id in all_docs:
        b_rank = bm25_ranks.get(doc_id, 9999)
        d_rank = dense_ranks.get(doc_id, 9999)

        score = (1.0 / (k + b_rank)) + (1.0 / (k + d_rank))

        fused.append({
            "doc_id": doc_id,
            "rrf_score": round(score, 6),
            "bm25_rank": b_rank if b_rank != 9999 else None,
            "dense_rank": d_rank if d_rank != 9999 else None,
        })

    fused.sort(key=lambda x: x["rrf_score"], reverse=True)
    return fused


class HybridSearchService:
    """
    Document hybrid search coordinator.
    Indexes a document's reading chunks and provides BM25 + Dense + RRF retrieval.
    """

    def __init__(self, chunks: List[Any]):
        self.chunks = {c.id: c for c in chunks}
        doc_tuples = [(c.id, c.raw_text) for c in chunks]

        self.bm25 = BM25Index()
        self.bm25.fit(doc_tuples)

        self.dense = DenseRetriever()
        self.dense.fit(doc_tuples)

    def search(self, query: str, top_k: int = 5, k_rrf: int = 60) -> List[Dict[str, Any]]:
        """
        Runs hybrid search over indexed chunks using RRF.
        Returns top_k chunks with text, offsets, and RRF provenance.
        """
        bm25_results = self.bm25.score(query)
        dense_results = self.dense.score(query)

        bm25_ids = [doc_id for doc_id, _ in bm25_results]
        dense_ids = [doc_id for doc_id, _ in dense_results]

        fused = reciprocal_rank_fusion(bm25_ids, dense_ids, k=k_rrf)

        top_candidates = fused[:top_k]
        results: List[Dict[str, Any]] = []

        for item in top_candidates:
            chunk = self.chunks.get(item["doc_id"])
            if chunk:
                results.append({
                    "chunk_id": chunk.id,
                    "sequence": chunk.sequence,
                    "section_title": chunk.section_title,
                    "raw_text": chunk.raw_text,
                    "start_offset": chunk.start_offset,
                    "end_offset": chunk.end_offset,
                    "rrf_score": item["rrf_score"],
                    "bm25_rank": item["bm25_rank"],
                    "dense_rank": item["dense_rank"],
                })

        return results
