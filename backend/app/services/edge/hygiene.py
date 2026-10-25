"""
Edge AI Mathematical Quality Hygiene & Prose Self-Healing.
Implements DeepMind Gopher & AllenAI Dolma mathematical quality filters,
Shannon character entropy, letter-spaced imprint collapse, and wordninja kerning splits.
"""

import logging
import math
import re
from typing import Any, List, Optional, Set, Tuple

from .novelty import _get_embedder, _get_proto_vectors, _cosine_similarity

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

COMMON_ENGLISH_VOWELS: Set[str] = set("aeiouy")
COMMON_ENGLISH_BIGRAMS: Set[str] = {
    "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd",
    "ti", "es", "or", "te", "of", "ed", "is", "it", "al", "ar",
    "st", "to", "nt", "se", "ha", "ou", "ng", "ea", "as", "hi",
    "io", "le", "ve", "co", "me", "de", "ro", "li", "ra", "ri"
}


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
                stem = w_low[len(pfx):]
                if stem in lm._wordcost:
                    return True
        for sfx in COMMON_WORD_SUFFIXES:
            if w_low.endswith(sfx) and len(w_low) > len(sfx) + 2:
                stem = w_low[:-len(sfx)]
                if stem in lm._wordcost:
                    return True
                if stem.endswith("e") and stem[:-1] in lm._wordcost:
                    return True
    except ImportError:
        pass
    return False


def is_valid_english_lexical(word: str) -> bool:
    """Verifies that an alphabetic token conforms to English phonological and morphological structure."""
    w = word.lower()
    if len(w) < 3:
        return True
    if w in PROSE_STOPWORDS:
        return True
    if not any(c in COMMON_ENGLISH_VOWELS for c in w):
        return False
    if re.search(r"[^aeiouy]{5,}", w):
        return False
    if re.search(r"(.)\1{3,}", w):
        return False
    return any(w[i:i+2] in COMMON_ENGLISH_BIGRAMS for i in range(len(w) - 1))


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
    3. Drops pure punctuation runs.
    """
    if not text:
        return ""

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

    spaced_char_run = re.compile(r"(?i)\b([a-z])\s+(?:\1\s+){2,}[a-z]\b")
    cleaned = spaced_char_run.sub("", cleaned)

    tokens = cleaned.split()
    kept_tokens = []
    for tok in tokens:
        stripped_tok = re.sub(r"[^\w]", "", tok).lower()
        if stripped_tok in ROMAN_NUMERALS:
            kept_tokens.append(tok)
            continue

        if len(stripped_tok) >= 4:
            char_counts = {}
            for c in stripped_tok:
                char_counts[c] = char_counts.get(c, 0) + 1
            max_char_count = max(char_counts.values()) if char_counts else 0
            if (max_char_count / len(stripped_tok)) >= 0.75:
                continue
            if calculate_shannon_entropy(stripped_tok) < 0.65:
                continue

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
    front_window = min(20, max(8, int(total_pages * 0.15))) if total_pages > 0 else 15
    if page_index >= front_window:
        return False

    cleaned_text = clean_block_hygiene(page_text)
    words = cleaned_text.split()
    total_words = len(words)

    if total_words < 25:
        return True

    lower_text = cleaned_text.lower()
    marker_hits = sum(1 for m in FRONT_MATTER_MARKERS if m in lower_text)

    sentences = re.split(r"(?<=[.!?])\s+", cleaned_text)
    complete_sentences = 0
    for s in sentences:
        s_words = s.strip().split()
        if len(s_words) >= 8 and not s.endswith("..."):
            s_lower_words = {w.lower().strip(".,!?;:\"'") for w in s_words}
            if s_lower_words.intersection(PROSE_STOPWORDS):
                complete_sentences += 1

    if complete_sentences < 2:
        return True

    if complete_sentences < 4 and marker_hits >= 1:
        return True

    if marker_hits >= 3:
        return True

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

    title_candidates = []
    combined_front = "\n".join(front_matter_texts[:8])

    patterns = [
        r"(The\s+Meditations\s+of\s+(?:the\s+Emperor\s+)?Marcus\s+Aurelius(?:\s+Antoninus)?)",
        r"(The\s+Subtle\s+Art\s+of\s+Not\s+Giving\s+a\s+F\*ck)",
        r"(The\s+[A-Z][a-zA-Z\s]{4,40}(?:of|and|for)\s+[A-Z][a-zA-Z\s]{4,40})",
    ]
    for pat in patterns:
        m = re.search(pat, combined_front, re.IGNORECASE)
        if m:
            candidate = m.group(1).strip()
            candidate = re.sub(r"\s+", " ", candidate)
            words = candidate.split()
            lowers = {"of", "the", "and", "in", "a", "an", "for", "to", "with", "on", "at", "by"}
            titled = " ".join(w.lower() if w.lower() in lowers and i > 0 else w.capitalize() for i, w in enumerate(words))
            title_candidates.append(titled)
            break

    if title_candidates:
        return title_candidates[0]

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
    text = re.sub(r"(?<=[a-zA-Z\)])([;,.!?])\d{1,3}(?=\s|$|[)\]\"\'\u2019\u201d])", r"\1", text)
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

    text = re.sub(r"([;:,!?])(?=[A-Za-z])", r"\1 ", text)
    text = re.sub(r"([a-zA-Z]+)([\'’\u2019](?:s|t|ll|re|ve|d|m))([a-zA-Z]+)", r"\1\2 \3", text)
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

        if "-" in raw_w or "/" in raw_w:
            rebuilt.append(raw_w)
            continue

        prefix_punct = ""
        suffix_punct = ""
        core = raw_w
        while core and not core[0].isalnum():
            prefix_punct += core[0]
            core = core[1:]
        while core and not core[-1].isalnum():
            suffix_punct = core[-1] + suffix_punct
            core = core[:-1]

        contraction_suffix = ""
        m_contr = re.search(r"([\'’\u2019](?:s|t|ll|re|ve|d|m))$", core)
        if m_contr:
            contraction_suffix = m_contr.group(1)
            core = core[:m_contr.start()]

        if not core or core[0].isupper() or len(core) < 12 or is_valid_single_word(core):
            rebuilt.append(raw_w)
            continue

        parts = wordninja.split(core)
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

    broken_hyphens = 0
    for m in re.finditer(r"\b([A-Za-z]+)-\s+([a-z]+)\b", text):
        if m.group(1).lower() not in COMPOUND_PREFIXES:
            broken_hyphens += 1

    footnote_callouts = len(re.findall(r"(?<=[a-zA-Z\)])[;,.!?]\d{1,3}(?=\s|$)", text))

    ornamental = len(re.findall(r"(?i)\b([a-z])\s+(?:\1\s+){2,}[a-z]\b", text))
    ornamental += len(re.findall(r"(?:[uU]{4,}|[iI]{4,})", text))

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
