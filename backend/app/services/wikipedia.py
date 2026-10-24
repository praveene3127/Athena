import difflib
import hashlib
import json
import logging
import re
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional
import httpx

from app.config import (
    WIKI_CACHE_DIR,
    WIKI_CONTACT,
    WIKI_TIMEOUT_S,
)

logger = logging.getLogger(__name__)

DISALLOWED_WIKI_PATTERNS = re.compile(
    r"(\((?:song|single|album|band|ep|film|tv\s+series|television\s+series|video\s+game|comics|novel|soundtrack|fictional\s+character|disambiguation)\)|"
    r"\bis\s+a\s+song\s+by\b|\bis\s+a\s+single\s+by\b|\bdebut\s+album\b|\bstudio\s+album\b|\brecorded\s+by\b|"
    r"\bbillboard\s+hot\b|\bmusic\s+video\b|\bfictional\s+character\b|\bmay\s+refer\s+to:\b|\bepisodes\s+of\b)",
    re.IGNORECASE,
)


def title_matches(term: str, title: str) -> bool:
    """Checks if term matches title per CLAUDE.md §7.2:
    normalized term tokens ⊆ title tokens, OR difflib ratio >= 0.75.
    """
    if DISALLOWED_WIKI_PATTERNS.search(title):
        return False

    term_tokens = set(re.findall(r"\w+", term.lower()))
    title_tokens = set(re.findall(r"\w+", title.lower()))

    if term_tokens and term_tokens.issubset(title_tokens):
        return True

    ratio = difflib.SequenceMatcher(None, term.lower().strip(), title.lower().strip()).ratio()
    return ratio >= 0.75


class WikipediaClient:
    def __init__(
        self,
        client: Optional[httpx.Client] = None,
        cache_dir: Optional[Path] = None,
        user_agent: Optional[str] = None,
        timeout: float = WIKI_TIMEOUT_S,
    ):
        self.cache_dir = cache_dir or WIKI_CACHE_DIR
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.user_agent = user_agent or f"Athena/0.1 (hackathon; contact: {WIKI_CONTACT})"
        self.timeout = timeout
        self._client = client

    def _get_client(self) -> httpx.Client:
        if self._client is not None:
            return self._client
        return httpx.Client(
            headers={"User-Agent": self.user_agent},
            timeout=self.timeout,
            follow_redirects=True,
        )

    def _cache_path(self, term: str) -> Path:
        normalized = term.strip().lower()
        key = hashlib.sha1(normalized.encode("utf-8")).hexdigest()
        return self.cache_dir / f"{key}.json"

    def fetch_term(self, term: str) -> Optional[dict[str, Any]]:
        """Searches Wikipedia for a term, verifies candidate page,
        and returns validated summary & citation info. Caches all results to disk.
        """
        cache_file = self._cache_path(term)
        if cache_file.exists():
            try:
                cached = json.loads(cache_file.read_text(encoding="utf-8"))
                if not cached.get("matched", False):
                    return None
                data = cached.get("data")
                if data:
                    c_title = data.get("title", "")
                    c_extract = data.get("extract", "")
                    if DISALLOWED_WIKI_PATTERNS.search(c_title) or DISALLOWED_WIKI_PATTERNS.search(c_extract):
                        try:
                            cache_file.unlink()
                        except Exception:
                            pass
                        return None
                    return data
            except Exception as e:
                logger.warning(f"Error reading cache for '{term}': {e}")

        # Live lookup
        result = self._lookup_online(term)

        # Write to disk cache
        try:
            if result is None:
                cache_file.write_text(json.dumps({"matched": False, "term": term}), encoding="utf-8")
            else:
                cache_file.write_text(
                    json.dumps({"matched": True, "term": term, "data": result}), encoding="utf-8"
                )
        except Exception as e:
            logger.warning(f"Failed to write wiki cache for '{term}': {e}")

        return result

    def _lookup_online(self, term: str) -> Optional[dict[str, Any]]:
        client = self._get_client()
        should_close = self._client is None

        try:
            # 1. Search Wikipedia API for top 3 candidates
            search_url = "https://en.wikipedia.org/w/api.php"
            params = {
                "action": "query",
                "list": "search",
                "srsearch": term,
                "srlimit": 3,
                "format": "json",
                "utf8": 1,
            }

            resp = None
            for attempt in range(2):  # 1 retry per spec §7.2
                try:
                    resp = client.get(search_url, params=params)
                    if resp.status_code == 200:
                        break
                except httpx.RequestError as e:
                    if attempt == 1:
                        logger.warning(f"Wiki search failed for '{term}': {e}")
                        return None

            if not resp or resp.status_code != 200:
                return None

            search_data = resp.json()
            search_results = search_data.get("query", {}).get("search", [])
            if not search_results:
                return None

            # 2. Try top 3 hits in order
            for hit in search_results:
                candidate_title = hit.get("title", "")
                if not candidate_title or DISALLOWED_WIKI_PATTERNS.search(candidate_title):
                    continue

                # Check title match rule
                if not title_matches(term, candidate_title):
                    continue

                # Fetch page summary
                encoded_title = urllib.parse.quote(candidate_title.replace(" ", "_"), safe="")
                summary_url = f"https://en.wikipedia.org/api/rest_v1/page/summary/{encoded_title}"

                summary_resp = None
                for attempt in range(2):
                    try:
                        summary_resp = client.get(summary_url)
                        if summary_resp.status_code == 200:
                            break
                    except httpx.RequestError:
                        if attempt == 1:
                            break

                if not summary_resp or summary_resp.status_code != 200:
                    continue

                summary = summary_resp.json()

                # Rule checks:
                # - type == "standard" (reject disambiguation)
                # - extract >= 60 chars
                # - title & extract must not match pop-culture / song / entertainment patterns
                page_type = summary.get("type", "")
                extract = summary.get("extract", "") or ""
                summary_title = summary.get("title", candidate_title)
                if page_type != "standard":
                    continue
                if len(extract.strip()) < 60:
                    continue
                if DISALLOWED_WIKI_PATTERNS.search(summary_title) or DISALLOWED_WIKI_PATTERNS.search(extract):
                    logger.info("Rejecting Wikipedia hit '%s' due to pop-culture/entertainment filter", summary_title)
                    continue

                page_url = (
                    summary.get("content_urls", {}).get("desktop", {}).get("page")
                    or f"https://en.wikipedia.org/wiki/{encoded_title}"
                )

                now_iso = datetime.now(timezone.utc).isoformat()
                citation = {
                    "title": summary.get("title", candidate_title),
                    "publisher": "Wikipedia (Wikimedia Foundation)",
                    "url": page_url,
                    "license": "CC BY-SA 4.0",
                    "retrieved_at": now_iso,
                }

                return {
                    "title": summary.get("title", candidate_title),
                    "extract": extract.strip(),
                    "page_url": page_url,
                    "citation": citation,
                }

            return None
        finally:
            if should_close:
                client.close()
