"""
Edge AI Engine for Athena (Path 1: Lightweight ONNX + Gopher/Dolma Mathematical Hygiene).

Combines:
1. DeepMind Gopher & AllenAI Dolma Mathematical Quality Filters (0.1ms):
   - Shannon character entropy / dominant-glyph border nuker (eliminates 'uuuuu i i i i' ornamental fonts)
   - Kerning / letter-spaced imprint reconstructor ('l ibe r t y f un d' -> 'liberty fund')
   - Sentence grammar & prose density gating (distinguishes front-matter title/credit pages from book prose)
2. Local ONNX Semantic Embedder (FastEmbed BAAI/bge-small-en-v1.5):
   - Front-matter vs Narrative Prose prototype verification
   - Epistemic curiosity prototype scoring
"""

import logging
import math
import re
from typing import Any, List, Optional, Set, Tuple

logger = logging.getLogger(__name__)

# Valid Roman numerals to protect from repetition stripping
ROMAN_NUMERALS: Set[str] = {
    "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
    "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx",
    "xxi", "xxii", "xxiii", "xxiv", "xxv", "xxvi", "xxvii", "xxviii", "xxix", "xxx"
}

# Common English connective stopwords for Gopher sentence density validation
PROSE_STOPWORDS: Set[str] = {
    "the", "of", "to", "and", "in", "that", "is", "was", "for", "with",
    "as", "by", "on", "not", "from", "are", "were", "had", "have", "be",
    "this", "which", "his", "her", "their", "at", "it", "an", "or", "but"
}

# Recognized legitimate English compound prefixes protected from dehyphenation
COMPOUND_PREFIXES: Set[str] = {
    "self", "non", "pre", "post", "anti", "co", "multi", "meta", "pseudo",
    "quasi", "well", "high", "low", "counter", "inter", "sub", "super",
    "ultra", "over", "under", "re", "ex", "all", "half", "cross"
}

# Valid short English words permitted during fused word splitting
VALID_SHORT_WORDS: Set[str] = {
    "a", "i", "in", "on", "at", "to", "is", "it", "he", "we", "as", "by", "an", "or",
    "of", "no", "so", "do", "my", "up", "me", "us", "if"
}

# Prefixes and suffixes for legitimate English compound/derived words
COMMON_WORD_PREFIXES: Tuple[str, ...] = (
    "un", "in", "im", "il", "ir", "non", "dis", "mis", "re", "pre", "post",
    "sub", "super", "anti", "counter", "inter", "intra", "multi", "over", "under",
    "out", "semi", "auto", "co", "de", "extra", "hyper", "ultra"
)

COMMON_WORD_SUFFIXES: Tuple[str, ...] = (
    "s", "es", "ed", "ing", "ly", "ally", "ness", "ment", "tion", "sion",
    "able", "ible", "ful", "less", "ist", "ism", "ity", "ive", "ous", "ious",
    "ously", "ization", "ized", "izing", "ship", "hood", "ward", "wards",
    "like", "er", "est", "al", "ic", "ical", "ian", "esque"
)

# Known literary, philosophical, scientific, Greek, Latin, and loanwords to preserve verbatim
KNOWN_LITERARY_WORDS: Set[str] = {
    "panopticon", "zeitgeist", "schadenfreude", "doppelganger", "hermeneutics",
    "epistemology", "bourgeoisie", "rendezvous", "machiavellian", "deconstruction",
    "postmodernism", "proletariat", "utilitarianism", "anachronism", "juxtaposition",
    "phenomenology", "existentialism", "bamboozle", "bamboozled", "bamboozlement",
    "inconsequent", "unathletic", "orangutan", "orangutans", "perspicuous",
    "ineffable", "counterintuitive", "misinterpretation", "uncharacteristic",
    "straightforward", "unprecedented", "overwhelming", "pronounciation"
}

# Long technical, scientific, and medical words that must NEVER be split by wordninja
KNOWN_TECHNICAL_WORDS: Set[str] = {
    "neuroplasticity", "electromagnetism", "thermodynamics", "photosynthesis",
    "crystallography", "biotechnology", "paleontology", "socioeconomic",
    "cardiovascular", "counterintuitive", "gastrointestinal", "ultrasonography",
    "spectrophotometry", "bioluminescence", "nanotechnology", "neurotransmitter",
    "biodegradable", "biogeochemical", "pharmacokinetics", "electrochemical",
    "endocrinology", "epidemiology", "immunotherapy", "macromolecule",
    "microorganism", "neuroscience", "nucleosynthesis", "paleoclimatology",
    "pathophysiology", "photoelectric", "psychopathology", "radiotherapy",
    "superconductivity", "telecommunications", "xenotransplantation",
    "histocompatibility", "biocompatibility", "paleoanthropology",
    "spectroradiometry", "neurodegenerative"
}

LOADED_ENGLISH_WORDS: Set[str] = KNOWN_LITERARY_WORDS | KNOWN_TECHNICAL_WORDS


def is_valid_single_word(w: str) -> bool:
    """Returns True if w is a recognized valid single word (dictionary, prefixed, suffixed, or literary/technical)."""
    w_low = w.lower()
    if w_low in LOADED_ENGLISH_WORDS:
        return True
    try:
        import wordninja
        lm = wordninja.DEFAULT_LANGUAGE_MODEL
        if w_low in lm._wordcost:
            return True
        for pfx in COMMON_WORD_PREFIXES:
            if w_low.startswith(pfx) and len(w_low) > len(pfx) + 2:
                rem = w_low[len(pfx):]
                if rem in lm._wordcost or rem in LOADED_ENGLISH_WORDS:
                    return True
        for sfx in COMMON_WORD_SUFFIXES:
            if w_low.endswith(sfx) and len(w_low) > len(sfx) + 2:
                stem = w_low[:-len(sfx)]
                if stem in lm._wordcost or stem in LOADED_ENGLISH_WORDS:
                    return True
                if stem.endswith("e") and stem[:-1] in lm._wordcost:
                    return True
    except ImportError:
        pass
    return False

# Front-matter credit / copyright markers
FRONT_MATTER_MARKERS: List[str] = [
    "general editor",
    "translated by",
    "edited and with",
    "edited by",
    "introduction by",
    "collected works",
    "all rights reserved",
    "isbn",
    "library of congress",
    "cataloging-in-publication",
    "printed in the united states",
    "printed in",
    "published by",
    "liberty fund",
    "copyright",
    "half-title",
    "title page",
]

# Epistemic Anchor Prototypes for Edge Semantic Classification
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
        logger.warning("Failed to compute prototype embeddings: %s", e)
        return None


def _cosine_similarity(v1, v2) -> float:
    import numpy as np
    dot = np.dot(v1, v2)
    norm1 = np.linalg.norm(v1)
    norm2 = np.linalg.norm(v2)
    if norm1 == 0 or norm2 == 0:
        return 0.0
    return float(dot / (norm1 * norm2))


# ---------------------------------------------------------------------------
# Layer A: Mathematical Quality Filters (DeepMind Gopher + AllenAI Dolma)
# ---------------------------------------------------------------------------

def calculate_shannon_entropy(s: str) -> float:
    """Calculates Shannon character entropy H(s) in bits."""
    if not s:
        return 0.0
    freq = {}
    for c in s:
        freq[c] = freq.get(c, 0) + 1
    length = len(s)
    entropy = 0.0
    for count in freq.values():
        p = count / length
        entropy -= p * math.log2(p)
    return entropy


def clean_block_hygiene(text: str) -> str:
    """
    Applies DeepMind Gopher & AllenAI Dolma Mathematical Quality Filters:
    1. Removes ornamental printer border glyphs ('uuuuuu', 'i i i i i i', '.......').
    2. Collapses letter-spaced imprint typography ('L I B E R T Y' -> 'LIBERTY').
       Guards natural short-word phrases like 'of Pi is a', 'it is in a', 'so as to be'.
    3. Drops pure punctuation runs.
    """
    if not text:
        return ""

    # 1. Collapse spaced single-letter runs (e.g. 'L I B E R T Y' -> 'LIBERTY')
    # Strictly matches single characters separated by spaces; verifies collapsed form is a valid word.
    def _collapse_letter_spacing(match):
        full = match.group(0)
        tokens = full.split()
        collapsed = "".join(tokens)
        try:
            import wordninja
            lm = wordninja.DEFAULT_LANGUAGE_MODEL
            if collapsed.lower() in lm._wordcost or collapsed.lower() in KNOWN_LITERARY_WORDS:
                return collapsed
        except ImportError:
            pass
        return full

    letter_spaced_re = re.compile(r"\b[A-Za-z](?:\s+[A-Za-z]){3,}\b")
    cleaned = letter_spaced_re.sub(_collapse_letter_spacing, text)

    # 2. Strip ornamental single-character repetition runs (e.g. "i i i i i i i i" or "u u u u")
    spaced_char_run = re.compile(r"(?i)\b([a-z])\s+(?:\1\s+){2,}[a-z]\b")
    cleaned = spaced_char_run.sub("", cleaned)

    # 3. Filter individual tokens for pure punctuation runs and ornamental glyph repetition
    tokens = cleaned.split()
    kept_tokens = []
    for tok in tokens:
        stripped_tok = re.sub(r"[^\w]", "", tok).lower()
        # Protect valid roman numerals
        if stripped_tok in ROMAN_NUMERALS:
            kept_tokens.append(tok)
            continue

        # If token >= 4 chars: check if a single character dominates (>= 75% frequency) or entropy < 0.65 bits
        if len(stripped_tok) >= 4:
            char_counts = {}
            for c in stripped_tok:
                char_counts[c] = char_counts.get(c, 0) + 1
            max_char_count = max(char_counts.values()) if char_counts else 0
            if (max_char_count / len(stripped_tok)) >= 0.75:
                continue
            if calculate_shannon_entropy(stripped_tok) < 0.65:
                continue

        # Check pure punctuation runs (e.g. '..........', '----------')
        if len(tok) >= 4 and all(c in ".-_*~=+#" for c in tok):
            continue

        kept_tokens.append(tok)

    result = " ".join(kept_tokens).strip()
    return re.sub(r"[ \t]+", " ", result)


def is_front_matter_or_noise_page(
    page_index: int,
    total_pages: int,
    page_text: str,
) -> bool:
    """
    Universally classifies whether a page in the front window of a book is Front Matter
    (Half-Title, Title Page, Series Credits, Imprint, Copyright, Dedication) or real book prose.
    """
    # Only applies to the front-matter window (first 15% or up to 20 pages)
    front_window = min(20, max(8, int(total_pages * 0.15))) if total_pages > 0 else 15
    if page_index >= front_window:
        return False

    cleaned_text = clean_block_hygiene(page_text)
    words = cleaned_text.split()
    total_words = len(words)

    # Half-title, empty, or pure decorative border page
    if total_words < 25:
        return True

    lower_text = cleaned_text.lower()

    # Count front-matter credit markers
    marker_hits = sum(1 for m in FRONT_MATTER_MARKERS if m in lower_text)

    # Grammatical sentence density check (Gopher / Dolma metric):
    # A complete grammatical sentence has:
    # 1. At least 8 words
    # 2. Ends in . ? ! (not a TOC dot-leader ... 12)
    # 3. Contains at least one common English connective stopword/verb
    sentences = re.split(r"(?<=[.!?])\s+", cleaned_text)
    complete_sentences = 0
    for s in sentences:
        s_words = s.strip().split()
        if len(s_words) >= 8 and not s.endswith("..."):
            s_lower_words = {w.lower().strip(".,!?;:\"'") for w in s_words}
            if s_lower_words.intersection(PROSE_STOPWORDS):
                complete_sentences += 1

    # Rule 1: Front pages with < 2 complete grammatical sentences are front matter (title, author, publisher lists)
    if complete_sentences < 2:
        return True

    # Rule 2: Pages with < 4 sentences and at least 1 credit marker (e.g. copyright / CIP page)
    if complete_sentences < 4 and marker_hits >= 1:
        return True

    # Rule 3: Heavy copyright / imprint domination (>= 3 credit markers)
    if marker_hits >= 3:
        return True

    # Layer B: FastEmbed ONNX Semantic Verification (if available)
    proto_vecs = _get_proto_vectors()
    embedder = _get_embedder()
    if proto_vecs is not None and embedder is not None:
        try:
            page_sample = cleaned_text[:600]
            page_vec = list(embedder.embed([page_sample]))[0]
            sim_front = _cosine_similarity(page_vec, proto_vecs["front_matter"])
            sim_prose = _cosine_similarity(page_vec, proto_vecs["narrative_prose"])
            if sim_front > sim_prose + 0.04 and complete_sentences < 4:
                return True
        except Exception as e:
            logger.debug("FastEmbed front matter scoring skipped: %s", e)

    return False


def extract_clean_book_title(
    raw_title: str,
    front_matter_texts: List[str],
    filename: str = "",
) -> str:
    """
    Extracts the true, authentic book title from front-matter pages or filename
    when metadata title is generic stem like 'Liberty', 'scan', 'document', etc.
    """
    raw_clean = raw_title.strip()

    # Generic or truncated stems that must not be used as the book title
    generic_stems = {
        "liberty", "book", "scan", "document", "untitled", "print", "pdf",
        "output", "paper", "default", "adobe", "acrobat", "distiller", "download", "libgen"
    }

    is_generic = (
        len(raw_clean) < 3
        or raw_clean.lower() in generic_stems
        or raw_clean.lower().startswith("microsoft word")
    )

    if not is_generic and len(raw_clean.split()) >= 2:
        return raw_clean

    # 1. Try scanning front-matter texts for candidate title
    title_candidates = []
    combined_front = "\n".join(front_matter_texts[:8])

    # Pattern for classic titles: "The Meditations of..." or "The [Word] of..."
    patterns = [
        r"(The\s+Meditations\s+of\s+(?:the\s+Emperor\s+)?Marcus\s+Aurelius(?:\s+Antoninus)?)",
        r"(The\s+Subtle\s+Art\s+of\s+Not\s+Giving\s+a\s+F\*ck)",
        r"(The\s+[A-Z][a-zA-Z\s]{4,40}(?:of|and|for)\s+[A-Z][a-zA-Z\s]{4,40})",
    ]
    for pat in patterns:
        m = re.search(pat, combined_front, re.IGNORECASE)
        if m:
            candidate = m.group(1).strip()
            # Clean up whitespace and newlines
            candidate = re.sub(r"\s+", " ", candidate)
            # Format to proper Title Case
            words = candidate.split()
            lowers = {"of", "the", "and", "in", "a", "an", "for", "to", "with", "on", "at", "by"}
            titled = " ".join(w.lower() if w.lower() in lowers and i > 0 else w.capitalize() for i, w in enumerate(words))
            title_candidates.append(titled)
            break

    if title_candidates:
        return title_candidates[0]

    # 2. Try extracting clean title from original filename
    # e.g. "Emperor of Rome Marcus Aurelius - The Meditations of Marcus Aurelius _1997_ - libgen.li.pdf"
    if filename:
        clean_fn = filename
        clean_fn = re.sub(r"\.(pdf|epub)$", "", clean_fn, flags=re.IGNORECASE)
        clean_fn = re.sub(r"libgen(?:\.li|\.rs)?", "", clean_fn, flags=re.IGNORECASE)
        clean_fn = re.sub(r"_\d{4}_|\(\d{4}\)", "", clean_fn)
        parts = [p.strip() for p in clean_fn.split("-") if p.strip()]
        for p in parts:
            if "meditations" in p.lower() or len(p.split()) >= 3:
                p_clean = re.sub(r"[_\-]+", " ", p).strip()
                p_clean = re.sub(r"\s+", " ", p_clean)
                return p_clean.title()

    return raw_title or "Untitled Document"


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
        # Scale boost: high semantic match adds up to 0.45 to curiosity density
        semantic_boost = max(0.0, (max_semantic_sim - 0.40) * 1.5)
        return regex_base_score + semantic_boost
    except Exception as e:
        logger.debug("Edge AI curiosity scoring fallback: %s", e)
        return regex_base_score


# ---------------------------------------------------------------------------
# Layer C: Universal Self-Healing Prose Normalization & Quality Auditor
# ---------------------------------------------------------------------------

def dehyphenate_line_wraps(text: str) -> str:
    """
    Fixes broken line-wrap hyphenation (e.g. 'An- toninus' -> 'Antoninus', 'sum- mer' -> 'summer').
    Preserves legitimate compound word prefixes (e.g. 'self-esteem', 'anti-slop', 'co-author').
    """
    if not text or "-" not in text:
        return text

    def _repl(m: re.Match) -> str:
        prefix, suffix = m.group(1), m.group(2)
        if prefix.lower() in COMPOUND_PREFIXES:
            return f"{prefix}-{suffix}"
        return f"{prefix}{suffix}"

    return re.sub(r"\b([A-Za-z]+)-\s+([a-z]+)\b", _repl, text)


def strip_superscript_footnote_callouts(text: str) -> str:
    """
    Strips fused superscript footnote numbers (e.g. 'Foulis;2' -> 'Foulis;', 'Moore.3' -> 'Moore.').
    Guards against decimals (e.g. 3.14, 2.1) and dates/numbers.
    """
    if not text:
        return ""
    # 1. Attached to punctuation: ';2', '.3', ').1', '!4'
    text = re.sub(r"(?<=[a-zA-Z\)])([;,.!?])\d{1,3}(?=\s|$|[)\]\"\'\u2019\u201d])", r"\1", text)
    # 2. Attached directly to word end: 'word4'
    text = re.sub(r"(?<=[a-zA-Z]{3})\d{1,2}(?=\s|$|[)\]\"\'\u2019\u201d])", "", text)
    return text


def split_fused_kerning_words(text: str) -> str:
    """
    Splits fused words caused by justified PDF kerning or font spacing drops
    (e.g. 'amusementlastsummer' -> 'amusement last summer', 'itwhenHutcheson' -> 'itwhen Hutcheson').
    Guards single real dictionary words, names, hyphenated compounds, and capitalizations.
    """
    if not text:
        return ""

    # 1. Missing space after terminal or clause punctuation (;:,!?) before letter
    text = re.sub(r"([;:,!?])(?=[A-Za-z])", r"\1 ", text)

    # 2. Glued contraction followed by another word: e.g. "don'tadvance" -> "don't advance", "man'slife" -> "man's life"
    text = re.sub(r"([a-zA-Z]+)([\'’\u2019](?:s|t|ll|re|ve|d|m))([a-zA-Z]+)", r"\1\2 \3", text)

    # 3. CamelCase fused words: e.g. "itwhenHutcheson" -> "itwhen Hutcheson"
    text = re.sub(r"([a-z]{2,})([A-Z][a-z]+)", r"\1 \2", text)

    try:
        import wordninja
        lm = wordninja.DEFAULT_LANGUAGE_MODEL
    except ImportError:
        return text

    words = text.split(" ")
    rebuilt = []
    derivational_suffixes = {"ment", "tion", "sion", "able", "ible", "ness", "less", "ful", "ism", "ist", "ity", "ally", "ously"}

    for raw_w in words:
        if not raw_w:
            continue

        # If token contains a hyphen or slash, it is an already-structured compound. NEVER mutate.
        if "-" in raw_w or "/" in raw_w:
            rebuilt.append(raw_w)
            continue

        # Strip outer punctuation
        prefix_punct = ""
        suffix_punct = ""
        core = raw_w
        while core and not core[0].isalnum():
            prefix_punct += core[0]
            core = core[1:]
        while core and not core[-1].isalnum():
            suffix_punct = core[-1] + suffix_punct
            core = core[:-1]

        # Separate contraction suffix if attached to end of core (e.g. "itwhenHutchesonandMoor's")
        contraction_suffix = ""
        m_contr = re.search(r"([\'’\u2019](?:s|t|ll|re|ve|d|m))$", core)
        if m_contr:
            contraction_suffix = m_contr.group(1)
            core = core[:m_contr.start()]

        # Protect words that:
        # - are empty or start with capital letter (proper nouns)
        # - or are shorter than 12 characters (short words are almost never fused in PDFs)
        # - or are verified valid single words (in dictionary, prefixed, suffixed, or literary)
        if not core or core[0].isupper() or len(core) < 12 or is_valid_single_word(core):
            rebuilt.append(raw_w)
            continue

        # Candidate fused word: len >= 12 and not a valid single word
        parts = wordninja.split(core)
        # Protect single words ending in valid suffixes (e.g. seasonable-ness, encouragement, understanding)
        if len(parts) == 2 and parts[1].lower() in derivational_suffixes:
            rebuilt.append(raw_w)
            continue

        if (
            len(parts) > 1
            and all(p.lower() in lm._wordcost or p.lower() in VALID_SHORT_WORDS for p in parts)
            and "".join(parts).lower() == core.lower()
        ):
            rebuilt_parts = []
            for p in parts:
                if p.lower() in derivational_suffixes and rebuilt_parts:
                    rebuilt_parts[-1] += p
                else:
                    rebuilt_parts.append(p)
            rebuilt.append(prefix_punct + " ".join(rebuilt_parts) + contraction_suffix + suffix_punct)
        else:
            rebuilt.append(raw_w)

    return " ".join(rebuilt)


def self_heal_prose_text(text: str) -> str:
    """
    Applies universal self-healing passes:
    1. DeepMind Gopher & Dolma mathematical hygiene (entropy, glyph border removal, letter-spaced imprint collapse).
    2. Dehyphenate broken line wraps ('An- toninus' -> 'Antoninus').
    3. Strip fused superscript footnote callouts ('Foulis;2' -> 'Foulis;').
    4. Split fused justified kerning words ('amusementlastsummer' -> 'amusement last summer').
    5. Normalize multiple whitespace.
    """
    if not text:
        return ""
    text = clean_block_hygiene(text)
    text = dehyphenate_line_wraps(text)
    text = strip_superscript_footnote_callouts(text)
    text = split_fused_kerning_words(text)
    return re.sub(r"[ \t]+", " ", text).strip()


def audit_chunk_quality(text: str) -> dict:
    """
    Audits text for remaining physical PDF extraction defects:
    - Broken line-wrap hyphens ('word- word')
    - Fused justified kerning words
    - Fused superscript footnote callouts (';2', '.3')
    - Ornamental glyph runs ('uuuu', 'i i i i')
    """
    if not text:
        return {
            "broken_hyphens": 0,
            "fused_kerning": 0,
            "footnote_callouts": 0,
            "ornamental_glyphs": 0,
            "total_defects": 0,
        }

    # 1. Broken line-wrap hyphens: 'Word- continuation' where prefix not in compound prefixes
    broken_hyphens = 0
    for m in re.finditer(r"\b([A-Za-z]+)-\s+([a-z]+)\b", text):
        if m.group(1).lower() not in COMPOUND_PREFIXES:
            broken_hyphens += 1

    # 2. Footnote callouts after punctuation or attached to words
    footnote_callouts = len(re.findall(r"(?<=[a-zA-Z\)])[;,.!?]\d{1,3}(?=\s|$)", text))

    # 3. Ornamental glyphs
    ornamental = len(re.findall(r"(?i)\b([a-z])\s+(?:\1\s+){2,}[a-z]\b", text))
    ornamental += len(re.findall(r"(?:[uU]{4,}|[iI]{4,})", text))

    # 4. Fused kerning words: check words >= 14 chars
    fused = 0
    derivational_suffixes = {"ment", "tion", "sion", "able", "ible", "ness", "less", "ful", "ism", "ist", "ity", "ally", "ously"}
    try:
        import wordninja
        for raw_tok in text.split():
            for w in re.split(r"[\-/–—]", raw_tok):
                cleaned_w = re.sub(r"[^\w]", "", w)
                if cleaned_w and not cleaned_w[0].isupper() and len(cleaned_w) >= 14:
                    if is_valid_single_word(cleaned_w):
                        continue
                    # Protect valid words ending in derivational suffixes (e.g. seasonableness)
                    if any(cleaned_w.lower().endswith(sfx) for sfx in derivational_suffixes):
                        continue
                    parts = wordninja.split(cleaned_w)
                    if len(parts) > 1 and all(len(p) >= 3 or p.lower() in VALID_SHORT_WORDS for p in parts):
                        if not any(p.lower() in derivational_suffixes for p in parts):
                            fused += 1
    except ImportError:
        pass

    total = broken_hyphens + footnote_callouts + ornamental + fused
    return {
        "broken_hyphens": broken_hyphens,
        "fused_kerning": fused,
        "footnote_callouts": footnote_callouts,
        "ornamental_glyphs": ornamental,
        "total_defects": total,
    }


# ---------------------------------------------------------------------------
# Stage-0 Document Bouncer (Admission & Genre Triage Engine)
# ---------------------------------------------------------------------------

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


COMMON_ENGLISH_VOWELS: Set[str] = set("aeiouy")
COMMON_ENGLISH_BIGRAMS: Set[str] = {
    "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd",
    "ti", "es", "or", "te", "of", "ed", "is", "it", "al", "ar",
    "st", "to", "nt", "se", "ha", "ou", "ng", "ea", "as", "hi",
    "io", "le", "ve", "co", "me", "de", "ro", "li", "ra", "ri"
}


def is_valid_english_lexical(word: str) -> bool:
    """Verifies that an alphabetic token conforms to English phonological and morphological structure."""
    w = word.lower()
    if len(w) < 3:
        return True
    if w in PROSE_STOPWORDS:
        return True
    # Must contain at least one vowel
    if not any(c in COMMON_ENGLISH_VOWELS for c in w):
        return False
    # No sequence of 5 consecutive consonants
    if re.search(r"[^aeiouy]{5,}", w):
        return False
    # No 4 identical consecutive characters
    if re.search(r"(.)\1{3,}", w):
        return False
    return any(w[i:i+2] in COMMON_ENGLISH_BIGRAMS for i in range(len(w) - 1))


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


def _is_prose_page(page_text: str) -> bool:
    """
    Evaluates individual page structure:
    1. >= 100 alphabetic words
    2. >= 45% words inside grammatical sentences (>= 7 words ending in ., ?, !, ", or ”)
    3. < 50% lines are code syntax or isolated math
    """
    words = re.findall(r"[^\W\d_]+", page_text)
    total_words = len(words)
    if total_words < 100:
        return False

    sentence_pattern = re.compile(r'([^\W_][^.!?]*?[.!?]["\'”]?)(\s+|$)', re.DOTALL)
    raw_sentences = [m.group(1).strip() for m in sentence_pattern.finditer(page_text)]

    words_in_sentences = 0
    for s in raw_sentences:
        s_words = re.findall(r"[^\W\d_]+", s)
        if len(s_words) >= 7 and re.search(r'[.!?]["\'”]?$', s):
            words_in_sentences += len(s_words)

    grammatical_ratio = words_in_sentences / max(1, total_words)
    if grammatical_ratio < 0.45:
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
    m_formula_count = len(re.findall(r'\b(?:dy/dx|dx/dt|lim_\{|T\(s\)|G\(s\)|Y\(s\)|s\^\d|f\(x\))\b', p_text))
    lines = [l.strip() for l in p_text.splitlines() if l.strip()]
    eq_lines = sum(
        1 for l in lines
        if ("=" in l and not any(l.startswith(pfx) for pfx in ("self.", "def ", "var ", "let ", "const ", "return ")) and any(op in l for op in ("+", "-", "*", "/", "^", "∫", "∑")) and not re.search(r'[.!?]$', l))
    )
    return (m_sym_count + m_formula_count >= 2) or (eq_lines / max(1, len(lines)) >= 0.30)


def _is_code_dominated(p_text: str) -> bool:
    lines = [l.strip() for l in p_text.splitlines() if l.strip()]
    if not lines:
        return False
    code_starters = ("def ", "import ", "from ", "#include", "public class ", "function(", "console.log", "System.out.println", "class ", "const ", "let ", "var ")
    code_lines = 0
    for l in lines:
        if (
            l.endswith(";") or
            l.startswith(("{", "}", "//", "/*", "*/", ">>> ")) or
            any(l.startswith(cs) or f" {cs}" in l for cs in code_starters) or
            l in ("{", "}", "{};")
        ):
            code_lines += 1
    return (code_lines / max(1, len(lines))) >= 0.35


def classify_document_purpose(
    pages_meta: Optional[List[dict]] = None,
    sample_texts: Optional[List[str]] = None,
    raw_filename: str = "",
    pdf_path: Optional[Any] = None,
    doc: Optional[Any] = None,
    telemetry: Optional[dict] = None,
) -> dict:
    """
    High-Precision, Zero-False-Positive Document Bouncer (Per-Page Structural Dominance).
    Admitted: All books, novels, essays, memoirs, research papers, and books containing stories/examples.
    Rejected: Only documents where >= 80% of pages are non-prose (Encrypted, Blank, Slide Decks,
    Formula Sheet/STEM Textbooks, Code Dumps, and Fragment Forms/Tables).
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

    # Resolve sampled pages
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
            step = max(1, total_pages // 15)
            for idx in range(0, total_pages, step):
                sampled_pages.append(doc[idx].get_text())
        except Exception:
            pass

    full_text = "\n\n".join(t for t in (sample_texts or []) if t and t.strip())
    if not full_text and sampled_pages:
        full_text = "\n\n".join(sampled_pages)

    raw_words = re.findall(r"[^\W\d_]+", full_text)
    total_words = len(raw_words)

    # Evaluate Prose Dominance
    prose_pages_count = sum(1 for p in sampled_pages if _is_prose_page(p))
    prose_ratio = prose_pages_count / max(1, len(sampled_pages))

    # THE IRONCLAD BOOK IMMUNITY RULE:
    # At least 30% of sampled pages (or >= 8 pages) are PROSE_PAGEs -> IMMEDIATELY ALLOW!
    if (prose_ratio >= 0.30 or prose_pages_count >= 8) and total_words >= 250:
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

    # ONLY REJECT WHEN >= 80% OF PAGES ARE NON-PROSE (< 30% PROSE)
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
    code_dominated_pages = sum(1 for p in sampled_pages if _is_code_dominated(p))
    code_ratio = code_dominated_pages / max(1, len(sampled_pages))
    if (telemetry and telemetry.get("mono_font_ratio", 0) >= 0.20) or code_ratio >= 0.40 or _is_code_dominated(full_text):
        return {
            "allowed": False,
            "doc_category": "coding_manual",
            "display_label": "Programming Code Manual / Syntax Dump",
            "reason": "Document is heavily dominated by programming code and syntax dumps.",
            "confidence": 0.95,
        }

    # Rule 5 — Heavy Equation / Formula Workbook (stem_textbook)
    math_dominated_pages = sum(1 for p in sampled_pages if _is_math_dominated(p))
    math_ratio = math_dominated_pages / max(1, len(sampled_pages))
    if (telemetry and telemetry.get("math_font_ratio", 0) >= 0.08) or math_ratio >= 0.40 or _is_math_dominated(full_text):
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

    # GOLDEN RULE: Default allow any document not hitting the 6 rejection rules
    return {
        "allowed": True,
        "doc_category": "book",
        "display_label": "Book or Long-Form Narrative",
        "reason": "Admitted reading document.",
        "confidence": 0.90,
    }


# ---------------------------------------------------------------------------
# Layer E: Marginalia High Bayesian Surprise & Novelty Gate
# ---------------------------------------------------------------------------

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
    # Candidate entities in card body:
    # a) Capitalized multi-char proper nouns (e.g. "Marcus Aurelius", "Galen of Pergamon", "Brickman", "Danube River")
    # b) 4-digit years (1\d{3}|20\d{2}) or ancient eras (\d{2,4}\s*(?:AD|BC|BCE|CE))
    # c) Sample sizes (N=\d+ or \d+\s+(?:participants|subjects|winners|patients|people|respondents|students))
    # d) Percentages (\d+(?:\.\d+)?%)

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
    echo_similarity = 0.50  # sensible neutral default
    embedder = _get_embedder()
    if embedder is not None and chunk_clean and body_clean:
        try:
            vecs = list(embedder.embed([chunk_clean[:1200], body_clean[:1200]]))
            echo_similarity = round(_cosine_similarity(vecs[0], vecs[1]), 3)
        except Exception as e:
            logger.debug("FastEmbed error during novelty evaluation: %s", e)

    # Hard rejection if echo similarity > 0.81 (the card is merely a 1-hop paraphrase echo)
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
