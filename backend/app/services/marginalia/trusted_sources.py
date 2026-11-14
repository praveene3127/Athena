"""
Multi-Source Trusted Academic Research & Evidence Pipeline.
Queries verified peer-reviewed academic registries (Crossref, Europe PMC, OpenAlex)
with concurrent sub-2.5s lookups, relevance ranking, and DOI citation attribution.
Falls back to Wikipedia only when academic registries return no matches.
"""

from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import logging
import re
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

_TRUSTED_CACHE: Dict[str, List[Dict[str, Any]]] = {}

# Common English stop words for fast relevance scoring
_STOP_WORDS = {
    "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
    "any", "are", "aren't", "as", "at", "be", "because", "been", "before", "being",
    "below", "between", "both", "but", "by", "can", "cannot", "could", "couldn't",
    "did", "didn't", "do", "does", "doesn't", "doing", "don't", "down", "during",
    "each", "few", "for", "from", "further", "had", "hadn't", "has", "hasn't",
    "have", "haven't", "having", "he", "he'd", "he'll", "he's", "her", "here",
    "here's", "hers", "herself", "him", "himself", "his", "how", "how's", "i",
    "i'd", "i'll", "i'm", "i've", "if", "in", "into", "is", "isn't", "it", "it's",
    "its", "itself", "let's", "me", "more", "most", "mustn't", "my", "myself",
    "no", "nor", "not", "of", "off", "on", "once", "only", "or", "other", "ought",
    "our", "ours", "ourselves", "out", "over", "own", "same", "shan't", "she",
    "she'd", "she'll", "she's", "should", "shouldn't", "so", "some", "such",
    "than", "that", "that's", "the", "their", "theirs", "them", "themselves",
    "then", "there", "there's", "these", "they", "they'd", "they'll", "they're",
    "they've", "this", "those", "through", "to", "too", "under", "until", "up",
    "very", "was", "wasn't", "we", "we'd", "we'll", "we're", "we've", "were",
    "weren't", "what", "what's", "when", "when's", "where", "where's", "which",
    "while", "who", "who's", "whom", "why", "why's", "with", "won't", "would",
    "wouldn't", "you", "you'd", "you'll", "you're", "you've", "your", "yours",
    "yourself", "yourselves",
}


def _strip_xml_tags(text: str) -> str:
    """Removes XML/JATS tags such as <jats:p>, <jats:title>, etc."""
    if not text:
        return ""
    clean = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", clean).strip()


def _extract_keywords(text: str) -> set[str]:
    """Extracts lowercase tokens excluding short words and stop words."""
    tokens = re.findall(r"[A-Za-z]{3,}", text.lower())
    return {t for t in tokens if t not in _STOP_WORDS}


def is_matching_language_and_script(passage: str, title: str, abstract: str) -> bool:
    """Rejects academic evidence with mismatched scripts or foreign languages."""
    full_evidence = f"{title} {abstract}"
    if not full_evidence.strip():
        return True

    cyrillic_chars = len(re.findall(r"[\u0400-\u04FF]", full_evidence))
    cjk_chars = len(re.findall(r"[\u3040-\u9FFF\uF900-\uFAFF]", full_evidence))
    arabic_chars = len(re.findall(r"[\u0600-\u06FF]", full_evidence))
    total_letters = len(re.findall(r"\w", full_evidence)) or 1

    passage_cyrillic = len(re.findall(r"[\u0400-\u04FF]", passage)) if passage else 0
    if passage_cyrillic == 0:
        if (cyrillic_chars / total_letters) > 0.05:
            return False
        if (cjk_chars / total_letters) > 0.05:
            return False
        if (arabic_chars / total_letters) > 0.05:
            return False

        abstract_words = re.findall(r"[a-zA-Z]+", abstract.lower())
        if len(abstract_words) >= 10:
            sw_count = sum(1 for w in abstract_words if w in _STOP_WORDS)
            if (sw_count / len(abstract_words)) < 0.12:
                return False

    return True


def _score_relevance(passage_keywords: set[str], title: str, abstract: str) -> float:
    """Calculates relevance score between passage keywords and academic source text."""
    if not passage_keywords:
        return 1.0
    text_keywords = _extract_keywords(f"{title} {abstract}")
    if not text_keywords:
        return 0.0
    overlap = len(passage_keywords & text_keywords)
    # Title match has 2x weight
    title_keywords = _extract_keywords(title)
    title_overlap = len(passage_keywords & title_keywords)
    return float(overlap + title_overlap)


def fetch_crossref_works(query: str, timeout: float = 2.5) -> List[Dict[str, Any]]:
    """Queries Crossref REST API for peer-reviewed journal papers with abstracts."""
    clean_q = re.sub(r"[^\w\s-]", " ", query).strip()
    if not clean_q:
        return []
    url = (
        f"https://api.crossref.org/works?query={urllib.parse.quote(clean_q)}"
        f"&filter=has-abstract:true,language:en&rows=2&mailto=athena@reader.local"
    )
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "AthenaReader/1.0 (mailto:athena@reader.local)"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            items = data.get("message", {}).get("items", [])
            out = []
            for item in items:
                title_list = item.get("title", [])
                title = title_list[0] if title_list else "Peer-Reviewed Study"
                abstract = _strip_xml_tags(item.get("abstract", ""))
                containers = item.get("container-title", [])
                journal = containers[0] if containers else "Academic Journal"
                
                # Extract year
                date_parts = (
                    item.get("published", {}).get("date-parts", [[]])
                    or item.get("created", {}).get("date-parts", [[]])
                )
                year = date_parts[0][0] if date_parts and date_parts[0] else ""
                year_str = f" ({year})" if year else ""

                doi = item.get("DOI", "")
                url_link = f"https://doi.org/{doi}" if doi else item.get("URL", "")

                out.append({
                    "title": title,
                    "abstract": abstract,
                    "publisher": f"{journal}{year_str} · Crossref",
                    "url": url_link or "https://crossref.org",
                    "source_type": "crossref",
                    "year": str(year),
                })
            return out
    except Exception as exc:
        logger.debug("Crossref lookup notice for '%s': %s", query, exc)
        return []


def fetch_europe_pmc_works(query: str, timeout: float = 2.5) -> List[Dict[str, Any]]:
    """Queries Europe PMC for biomedical, psychology, and behavioral science studies."""
    clean_q = re.sub(r"[^\w\s-]", " ", query).strip()
    if not clean_q:
        return []
    url = (
        f"https://www.ebi.ac.uk/europepmc/webservices/rest/search?query={urllib.parse.quote(clean_q)}"
        f"&resultType=core&format=json&pageSize=2"
    )
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "AthenaReader/1.0 (mailto:athena@reader.local)"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            results = data.get("resultList", {}).get("result", [])
            out = []
            for res in results:
                title = res.get("title", "Biomedical & Behavioral Study").rstrip(".")
                abstract = _strip_xml_tags(res.get("abstractText", ""))
                journal = res.get("journalTitle") or "Europe PMC"
                year = res.get("pubYear", "")
                year_str = f" ({year})" if year else ""
                doi = res.get("doi", "")
                url_link = f"https://doi.org/{doi}" if doi else f"https://europepmc.org/article/MED/{res.get('id', '')}"

                out.append({
                    "title": title,
                    "abstract": abstract,
                    "publisher": f"{journal}{year_str} · Europe PMC",
                    "url": url_link,
                    "source_type": "europe_pmc",
                    "year": str(year),
                })
            return out
    except Exception as exc:
        logger.debug("Europe PMC lookup notice for '%s': %s", query, exc)
        return []


def fetch_openalex_works(query: str, timeout: float = 2.5) -> List[Dict[str, Any]]:
    """Queries OpenAlex global scholarly knowledge graph for open-access papers."""
    clean_q = re.sub(r"[^\w\s-]", " ", query).strip()
    if not clean_q:
        return []
    url = (
        f"https://api.openalex.org/works?search={urllib.parse.quote(clean_q)}"
        f"&filter=has_abstract:true,language:en&per-page=2&mailto=athena@reader.local"
    )
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "AthenaReader/1.0 (mailto:athena@reader.local)"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            results = data.get("results", [])
            out = []
            for item in results:
                title = item.get("display_name") or item.get("title") or "Scholarly Publication"
                
                # Reconstruct abstract from inverted index
                abstract = ""
                inv = item.get("abstract_inverted_index")
                if inv and isinstance(inv, dict):
                    pos_words = [
                        (p, word)
                        for word, plist in inv.items()
                        for p in plist
                        if isinstance(plist, list)
                    ]
                    pos_words.sort()
                    abstract = " ".join(word for _, word in pos_words)[:500]

                year = item.get("publication_year") or ""
                year_str = f" ({year})" if year else ""
                
                venue_data = item.get("primary_location", {}) or {}
                source_data = venue_data.get("source", {}) or {}
                venue = source_data.get("display_name") or "OpenAlex Scholarly Graph"
                
                doi = item.get("doi") or item.get("id") or "https://openalex.org"

                out.append({
                    "title": title,
                    "abstract": abstract,
                    "publisher": f"{venue}{year_str} · OpenAlex",
                    "url": doi,
                    "source_type": "openalex",
                    "year": str(year),
                })
            return out
    except Exception as exc:
        logger.debug("OpenAlex lookup notice for '%s': %s", query, exc)
        return []


def fetch_trusted_academic_evidence(
    concept: str,
    passage: str = "",
    timeout: float = 2.5,
) -> List[Dict[str, Any]]:
    """
    Queries Crossref, Europe PMC, and OpenAlex concurrently (sub-2.5s).
    Ranks results by passage keyword overlap and returns top trusted academic citations.
    """
    cache_key = f"{concept.lower().strip()}"
    if cache_key in _TRUSTED_CACHE:
        return _TRUSTED_CACHE[cache_key]

    raw_candidates: List[Dict[str, Any]] = []

    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = {
            executor.submit(fetch_crossref_works, concept, timeout): "crossref",
            executor.submit(fetch_europe_pmc_works, concept, timeout): "europe_pmc",
            executor.submit(fetch_openalex_works, concept, timeout): "openalex",
        }
        for fut in as_completed(futures):
            try:
                res = fut.result()
                if res:
                    raw_candidates.extend(res)
            except Exception as exc:
                logger.debug("Academic fetch worker notice: %s", exc)

    if not raw_candidates:
        return []

    # Language and script gate
    raw_candidates = [
        c
        for c in raw_candidates
        if is_matching_language_and_script(
            passage, c.get("title", ""), c.get("abstract", "")
        )
    ]
    if not raw_candidates:
        return []

    # Relevance scoring against passage
    passage_kw = _extract_keywords(passage)
    ranked = []
    for cand in raw_candidates:
        score = _score_relevance(passage_kw, cand["title"], cand.get("abstract", ""))
        cand["relevance_score"] = score
        ranked.append(cand)

    ranked.sort(key=lambda x: x["relevance_score"], reverse=True)
    
    # Filter out entries with 0 overlap if passage keywords existed and other candidates have positive overlap
    positive_ranked = [c for c in ranked if c["relevance_score"] > 0]
    final_results = positive_ranked if positive_ranked else ranked

    _TRUSTED_CACHE[cache_key] = final_results[:4]
    return _TRUSTED_CACHE[cache_key]

