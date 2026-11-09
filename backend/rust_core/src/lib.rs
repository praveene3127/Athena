use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;
use pyo3::prelude::*;
use rayon::prelude::*;
use regex::Regex;
use aho_corasick::AhoCorasick;

const ROMAN_NUMERALS: &[&str] = &[
    "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
    "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx",
    "xxi", "xxii", "xxiii", "xxiv", "xxv", "xxvi", "xxvii", "xxviii", "xxix", "xxx",
];

const COMPOUND_PREFIXES: &[&str] = &[
    "self", "non", "pre", "post", "anti", "co", "multi", "meta", "pseudo",
    "quasi", "well", "high", "low", "counter", "inter", "sub", "super",
    "ultra", "over", "under", "re", "ex", "all", "half", "cross",
];

const KNOWN_TECHNICAL_WORDS: &[&str] = &[
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
    "spectroradiometry", "neurodegenerative",
];

const PROTECTED_ALPHANUMERIC: &[&str] = &[
    "h2o", "co2", "3d", "4d", "5d", "mp3", "mp4", "b12", "o2", "n2",
    "f1", "f2", "a4", "b5", "v8", "v12", "k9", "g7", "g8", "g20",
];

const BANNED_GENERIC_SLOP_PHRASES: &[&str] = &[
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
];

// Globally compiled LazyLock Regexes & Automatons (zero runtime re-compilation)
static LETTER_SPACED_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b[A-Za-z](?:\s+[A-Za-z]){3,}\b").unwrap()
});
static NON_ALNUM_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[^\w]").unwrap()
});
static DEHYPHEN_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b([A-Za-z]+)-\s+([a-z]+)\b").unwrap()
});
static FN_PUNCT_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"([a-zA-Z\)])([;,.!?])\d{1,3}(\s|$|[)\]\'\u{2019}\u{201d}])").unwrap()
});
static FN_WORD_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b([a-zA-Z]{3,})(\d{1,2})(\s|$|[)\]\"\'\u{2019}\u{201d}.,;:!?])").unwrap()
});
static PUNCT_SPACE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"([;:,!?])([A-Za-z])").unwrap()
});
static CAMEL_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"([a-z]{2,})([A-Z][a-z]+)").unwrap()
});
static WS_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[ \t]+").unwrap()
});
static TOKEN_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b[a-z0-9_-]+\b").unwrap()
});
static SLOP_MATCHER: LazyLock<AhoCorasick> = LazyLock::new(|| {
    AhoCorasick::builder()
        .ascii_case_insensitive(true)
        .build(BANNED_GENERIC_SLOP_PHRASES)
        .unwrap()
});

fn calculate_shannon_entropy(s: &str) -> f64 {
    if s.is_empty() {
        return 0.0;
    }
    let mut freq = HashMap::new();
    for c in s.chars() {
        *freq.entry(c).or_insert(0usize) += 1;
    }
    let len = s.chars().count() as f64;
    let mut entropy = 0.0;
    for &count in freq.values() {
        let p = (count as f64) / len;
        entropy -= p * p.log2();
    }
    entropy
}

fn remove_spaced_repeated_chars(text: &str) -> String {
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.len() < 4 {
        return text.to_string();
    }
    let mut kept = Vec::with_capacity(words.len());
    let mut i = 0;
    while i < words.len() {
        let w = words[i];
        if w.chars().count() == 1 && w.chars().next().unwrap().is_ascii_alphabetic() {
            let target_char = w.chars().next().unwrap().to_ascii_lowercase();
            let mut j = i + 1;
            while j < words.len() {
                let next_w = words[j];
                if next_w.chars().count() == 1 && next_w.chars().next().unwrap().to_ascii_lowercase() == target_char {
                    j += 1;
                } else {
                    break;
                }
            }
            if j - i >= 4 {
                i = j;
                continue;
            }
        }
        kept.push(words[i]);
        i += 1;
    }
    kept.join(" ")
}

/// Core prose self-healing implementation in pure Rust.
pub fn self_heal_prose_text_core(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }

    let roman_set: HashSet<&str> = ROMAN_NUMERALS.iter().copied().collect();
    let compound_set: HashSet<&str> = COMPOUND_PREFIXES.iter().copied().collect();
    let technical_set: HashSet<&str> = KNOWN_TECHNICAL_WORDS.iter().copied().collect();
    let protected_set: HashSet<&str> = PROTECTED_ALPHANUMERIC.iter().copied().collect();

    // 1. Spaced char runs removal: e.g. "i i i i i" or "u u u u"
    let cleaned = remove_spaced_repeated_chars(text);

    // 2. Letter-spaced imprint collapse: e.g. "L I B E R T Y" -> "LIBERTY"
    let cleaned = LETTER_SPACED_RE.replace_all(&cleaned, |caps: &regex::Captures| {
        let matched = &caps[0];
        let collapsed: String = matched.split_whitespace().collect();
        if collapsed.chars().all(|c| c.is_ascii_alphabetic()) && !roman_set.contains(collapsed.to_lowercase().as_str()) {
            collapsed
        } else {
            matched.to_string()
        }
    });

    // 3. Shannon entropy and character repetition filtering on tokens
    let tokens: Vec<&str> = cleaned.split_whitespace().collect();
    let mut kept_tokens = Vec::with_capacity(tokens.len());

    for tok in tokens {
        let stripped = NON_ALNUM_RE.replace_all(tok, "").to_lowercase();
        if roman_set.contains(stripped.as_str()) {
            kept_tokens.push(tok);
            continue;
        }

        let char_count = stripped.chars().count();
        if char_count >= 4 {
            let mut char_map = HashMap::new();
            for c in stripped.chars() {
                *char_map.entry(c).or_insert(0usize) += 1;
            }
            let max_char_count = char_map.values().copied().max().unwrap_or(0);
            if (max_char_count as f64) / (char_count as f64) >= 0.75 {
                continue;
            }
            if calculate_shannon_entropy(&stripped) < 0.65 {
                continue;
            }
        }

        if tok.len() >= 4 && tok.chars().all(|c| ".-_*~=+#".contains(c)) {
            continue;
        }

        kept_tokens.push(tok);
    }
    let mut intermediate = kept_tokens.join(" ");

    // 4. Line-wrap dehyphenation: "word- word" -> "wordword"
    intermediate = DEHYPHEN_RE
        .replace_all(&intermediate, |caps: &regex::Captures| {
            let pfx = &caps[1];
            let sfx = &caps[2];
            let pfx_lower = pfx.to_lowercase();
            if compound_set.contains(pfx_lower.as_str()) {
                let combined = format!("{}{}", pfx, sfx);
                if technical_set.contains(combined.to_lowercase().as_str()) {
                    combined
                } else {
                    format!("{}-{}", pfx, sfx)
                }
            } else {
                format!("{}{}", pfx, sfx)
            }
        })
        .into_owned();

    // 5. Superscript footnote callout stripping: "Foulis;2" -> "Foulis;", "Moore.3" -> "Moore.", "word2 " -> "word "
    intermediate = FN_PUNCT_RE.replace_all(&intermediate, "$1$2$3").into_owned();
    intermediate = FN_WORD_RE
        .replace_all(&intermediate, |caps: &regex::Captures| {
            let word = &caps[1];
            let num = &caps[2];
            let trailing = &caps[3];
            let combined = format!("{}{}", word, num).to_lowercase();
            if protected_set.contains(combined.as_str()) {
                caps[0].to_string()
            } else {
                format!("{}{}", word, trailing)
            }
        })
        .into_owned();

    // 6. Spacing after punctuation: "candle.Headmaster" -> "candle. Headmaster"
    intermediate = PUNCT_SPACE_RE.replace_all(&intermediate, "$1 $2").into_owned();

    // 7. Collapse duplicate whitespace
    WS_RE.replace_all(&intermediate, " ").trim().to_string()
}

/// Zero Mid-Word Cuts invariant (FP-1).
pub fn is_legal_cut(text: &str, b: usize) -> bool {
    if b == 0 || b >= text.len() {
        return true;
    }
    if !text.is_char_boundary(b) {
        return false;
    }
    let prev_char = text[..b].chars().next_back().unwrap();
    let next_char = text[b..].chars().next().unwrap();
    prev_char.is_whitespace() || next_char.is_whitespace()
}

/// Dynamic programming optimal chunk boundary planner.
pub fn plan_feed_chunks_core(
    canonical_text: &str,
    atom_starts: &[usize],
    atom_ends: &[usize],
    atom_words: &[usize],
    atom_para_ids: &[usize],
    atom_is_sentence: &[bool],
    atom_starts_section: &[bool],
    target_words: usize,
) -> Result<Vec<(usize, usize)>, String> {
    let n = atom_starts.len();
    if n == 0 {
        return Ok(Vec::new());
    }
    if atom_ends.len() != n || atom_words.len() != n || atom_para_ids.len() != n {
        return Err("Mismatched atom slice lengths".to_string());
    }

    let min_words = 35.max((target_words as f64 * 0.55) as usize);
    let max_words = 65usize;
    let max_chars = 380usize;

    // Fast char-to-byte offset lookup vector so character offsets from Python
    // never cause byte boundary panics on multi-byte UTF-8 Unicode text!
    let char_to_byte: Vec<usize> = canonical_text
        .char_indices()
        .map(|(b, _)| b)
        .chain(std::iter::once(canonical_text.len()))
        .collect();

    let mut costs = vec![f64::INFINITY; n + 1];
    let mut next_index = vec![n; n];
    costs[n] = 0.0;

    for start in (0..n).rev() {
        let mut words = 0usize;
        for end in start..n {
            if end > start && atom_starts_section[end] {
                break;
            }
            words += atom_words[end];
            let chars = atom_ends[end].saturating_sub(atom_starts[start]);
            if (words > max_words || chars > max_chars) && end > start {
                break;
            }

            let deviation = (words as f64 - target_words as f64) / (target_words as f64);
            let mut chunk_cost = deviation * deviation;

            if words < min_words && end + 1 < n {
                let shortfall = (min_words as f64 - words as f64) / (min_words as f64);
                chunk_cost += 2.0 * shortfall * shortfall;
            }
            if words > max_words {
                let overflow = (words as f64 - max_words as f64) / (max_words as f64);
                chunk_cost += 8.0 * overflow * overflow;
            }

            if end + 1 < n {
                let left_end = atom_ends[end];
                let right_start = atom_starts[end + 1];
                let same_para = atom_para_ids[end] == atom_para_ids[end + 1];

                let boundary_cost = if same_para {
                    let left_byte = char_to_byte.get(left_end).copied().unwrap_or(canonical_text.len());
                    let right_byte = char_to_byte.get(right_start).copied().unwrap_or(canonical_text.len());
                    if left_byte <= right_byte && right_byte <= canonical_text.len() {
                        let sep = canonical_text.get(left_byte..right_byte).unwrap_or("");
                        if sep.contains('\n') {
                            0.20
                        } else {
                            0.35
                        }
                    } else {
                        0.30
                    }
                } else {
                    0.05
                };
                chunk_cost += boundary_cost;

                if atom_is_sentence[end] {
                    chunk_cost += 0.08;
                }
            }

            let total_cost = chunk_cost + costs[end + 1];
            if total_cost < costs[start] {
                costs[start] = total_cost;
                next_index[start] = end + 1;
            }

            if words > max_words {
                break;
            }
        }
    }

    let mut ranges = Vec::new();
    let mut start = 0usize;
    while start < n {
        let end = next_index[start];
        if end <= start {
            return Err(format!("No valid feed boundary after atom {}", start));
        }
        ranges.push((start, end));
        start = end;
    }

    Ok(ranges)
}

/// Tokenizer for BM25 search.
fn tokenize_text(text: &str) -> Vec<String> {
    TOKEN_RE
        .find_iter(text)
        .map(|m| m.as_str().to_lowercase())
        .collect()
}

/// Fast Robertson-Spärck Jones BM25 search.
pub fn hybrid_bm25_search_core(
    chunk_texts: &[String],
    query: &str,
    top_k: usize,
) -> Vec<(usize, f64)> {
    let num_docs = chunk_texts.len();
    if num_docs == 0 {
        return Vec::new();
    }

    let query_tokens = tokenize_text(query);
    if query_tokens.is_empty() {
        return (0..num_docs.min(top_k)).map(|i| (i, 0.0)).collect();
    }

    let mut doc_tokens_list: Vec<Vec<String>> = Vec::with_capacity(num_docs);
    let mut doc_freqs: HashMap<String, usize> = HashMap::new();
    let mut doc_lengths: Vec<usize> = Vec::with_capacity(num_docs);
    let mut total_len = 0usize;

    for text in chunk_texts {
        let tokens = tokenize_text(text);
        let len = tokens.len();
        total_len += len;
        doc_lengths.push(len);

        let mut seen = HashSet::new();
        for t in &tokens {
            if seen.insert(t.clone()) {
                *doc_freqs.entry(t.clone()).or_insert(0) += 1;
            }
        }
        doc_tokens_list.push(tokens);
    }

    let avg_doc_len = if num_docs > 0 {
        (total_len as f64) / (num_docs as f64)
    } else {
        1.0
    };

    let k1 = 1.5f64;
    let b = 0.75f64;
    let mut scores = vec![0.0f64; num_docs];

    for term in query_tokens {
        let df = match doc_freqs.get(&term) {
            Some(&c) if c > 0 => c,
            _ => continue,
        };

        let idf = (((num_docs as f64) - (df as f64) + 0.5) / ((df as f64) + 0.5) + 1.0).ln();

        for i in 0..num_docs {
            let mut tf = 0usize;
            for t in &doc_tokens_list[i] {
                if *t == term {
                    tf += 1;
                }
            }
            if tf == 0 {
                continue;
            }

            let doc_len = doc_lengths[i] as f64;
            let numerator = (tf as f64) * (k1 + 1.0);
            let denominator = (tf as f64) + k1 * (1.0 - b + b * (doc_len / avg_doc_len.max(1.0)));
            scores[i] += idf * (numerator / denominator);
        }
    }

    let mut ranked: Vec<(usize, f64)> = scores.into_iter().enumerate().collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    ranked.truncate(top_k);
    ranked
}

/// 8-lane unrolled SIMD-accelerated Cosine Similarity.
#[inline(always)]
pub fn cosine_similarity_simd(v1: &[f32], v2: &[f32]) -> f64 {
    let len = v1.len().min(v2.len());
    if len == 0 {
        return 0.0;
    }
    let mut dot = 0.0f32;
    let mut norm1 = 0.0f32;
    let mut norm2 = 0.0f32;

    let chunks_exact = len / 8;
    for i in 0..chunks_exact {
        let base = i * 8;
        let x0 = v1[base];     let y0 = v2[base];
        let x1 = v1[base + 1]; let y1 = v2[base + 1];
        let x2 = v1[base + 2]; let y2 = v2[base + 2];
        let x3 = v1[base + 3]; let y3 = v2[base + 3];
        let x4 = v1[base + 4]; let y4 = v2[base + 4];
        let x5 = v1[base + 5]; let y5 = v2[base + 5];
        let x6 = v1[base + 6]; let y6 = v2[base + 6];
        let x7 = v1[base + 7]; let y7 = v2[base + 7];

        dot += x0 * y0 + x1 * y1 + x2 * y2 + x3 * y3 + x4 * y4 + x5 * y5 + x6 * y6 + x7 * y7;
        norm1 += x0 * x0 + x1 * x1 + x2 * x2 + x3 * x3 + x4 * x4 + x5 * x5 + x6 * x6 + x7 * x7;
        norm2 += y0 * y0 + y1 * y1 + y2 * y2 + y3 * y3 + y4 * y4 + y5 * y5 + y6 * y6 + y7 * y7;
    }

    for i in (chunks_exact * 8)..len {
        let x = v1[i];
        let y = v2[i];
        dot += x * y;
        norm1 += x * x;
        norm2 += y * y;
    }

    if norm1 <= 0.0 || norm2 <= 0.0 {
        return 0.0;
    }

    (dot as f64) / ((norm1 as f64).sqrt() * (norm2 as f64).sqrt())
}

/// Single-pass Aho-Corasick novelty check for generic slop phrases.
pub fn scan_banned_slop_phrase(text: &str) -> Option<&'static str> {
    if let Some(m) = SLOP_MATCHER.find(text) {
        let idx = m.pattern().as_usize();
        if idx < BANNED_GENERIC_SLOP_PHRASES.len() {
            return Some(BANNED_GENERIC_SLOP_PHRASES[idx]);
        }
    }
    None
}

// ==============================================================================
// Ultra-Fast 64-Bit SimHash & Popcount Similarity
// ==============================================================================

/// Computes a 64-bit SimHash locality-sensitive fingerprint for text.
pub fn compute_simhash64(text: &str) -> u64 {
    let mut v = [0i32; 64];
    for word in text.split_whitespace() {
        let clean: String = word.chars().filter(|c| c.is_alphanumeric()).collect();
        if clean.len() < 3 {
            continue;
        }
        // 64-bit FNV-1a hash
        let mut h: u64 = 0xcbf29ce484222325;
        for b in clean.to_lowercase().bytes() {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
        for i in 0..64 {
            if (h & (1u64 << i)) != 0 {
                v[i] += 1;
            } else {
                v[i] -= 1;
            }
        }
    }
    let mut fingerprint: u64 = 0;
    for i in 0..64 {
        if v[i] > 0 {
            fingerprint |= 1u64 << i;
        }
    }
    fingerprint
}

/// Computes Hamming distance between two 64-bit SimHash fingerprints (0 to 64 diff bits).
pub fn simhash_hamming_distance(hash_a: u64, hash_b: u64) -> u32 {
    (hash_a ^ hash_b).count_ones()
}

/// Computes 0.0 to 1.0 similarity from Hamming distance.
pub fn simhash_similarity(hash_a: u64, hash_b: u64) -> f64 {
    let diff = (hash_a ^ hash_b).count_ones();
    1.0 - (diff as f64 / 64.0)
}

/// Fast search across candidate chunk hashes returning (index, hamming_dist, similarity).
pub fn find_similar_chunks_simhash_core(
    target_hash: u64,
    candidate_hashes: &[u64],
    top_k: usize,
) -> Vec<(usize, u32, f64)> {
    let mut scored: Vec<(usize, u32, f64)> = candidate_hashes
        .iter()
        .enumerate()
        .map(|(idx, &cand)| {
            let dist = simhash_hamming_distance(target_hash, cand);
            let sim = 1.0 - (dist as f64 / 64.0);
            (idx, dist, sim)
        })
        .collect();

    scored.sort_by(|a, b| a.1.cmp(&b.1));
    if scored.len() > top_k {
        scored.truncate(top_k);
    }
    scored
}

// ==============================================================================
// PyO3 Extension Module Bindings
// ==============================================================================

#[pyfunction]
fn rust_self_heal_prose_text(py: Python<'_>, text: &str) -> PyResult<String> {
    py.allow_threads(|| Ok(self_heal_prose_text_core(text)))
}

#[pyfunction]
fn rust_heal_pages_parallel(py: Python<'_>, pages: Vec<String>) -> PyResult<Vec<String>> {
    py.allow_threads(|| {
        Ok(pages.par_iter().map(|p| self_heal_prose_text_core(p)).collect())
    })
}

#[pyfunction]
#[allow(clippy::too_many_arguments)]
fn rust_plan_feed_chunks(
    py: Python<'_>,
    canonical_text: &str,
    atom_starts: Vec<usize>,
    atom_ends: Vec<usize>,
    atom_words: Vec<usize>,
    atom_para_ids: Vec<usize>,
    atom_is_sentence: Vec<bool>,
    atom_starts_section: Vec<bool>,
    target_words: usize,
) -> PyResult<Vec<(usize, usize)>> {
    py.allow_threads(|| {
        plan_feed_chunks_core(
            canonical_text,
            &atom_starts,
            &atom_ends,
            &atom_words,
            &atom_para_ids,
            &atom_is_sentence,
            &atom_starts_section,
            target_words,
        )
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e))
    })
}

#[pyfunction]
fn rust_hybrid_bm25_search(
    py: Python<'_>,
    chunk_texts: Vec<String>,
    query: &str,
    top_k: usize,
) -> PyResult<Vec<(usize, f64)>> {
    py.allow_threads(|| Ok(hybrid_bm25_search_core(&chunk_texts, query, top_k)))
}

#[pyfunction]
fn rust_cosine_similarity(
    py: Python<'_>,
    v1: Vec<f32>,
    v2: Vec<f32>,
) -> PyResult<f64> {
    py.allow_threads(|| Ok(cosine_similarity_simd(&v1, &v2)))
}

#[pyfunction]
fn rust_check_slop_phrase(
    py: Python<'_>,
    text: &str,
) -> PyResult<Option<String>> {
    py.allow_threads(|| Ok(scan_banned_slop_phrase(text).map(|s| s.to_string())))
}

#[pyfunction]
fn rust_simhash64(
    py: Python<'_>,
    text: &str,
) -> PyResult<u64> {
    py.allow_threads(|| Ok(compute_simhash64(text)))
}

#[pyfunction]
fn rust_simhash_hamming_distance(
    py: Python<'_>,
    hash_a: u64,
    hash_b: u64,
) -> PyResult<u32> {
    py.allow_threads(|| Ok(simhash_hamming_distance(hash_a, hash_b)))
}

#[pyfunction]
fn rust_simhash_similarity(
    py: Python<'_>,
    hash_a: u64,
    hash_b: u64,
) -> PyResult<f64> {
    py.allow_threads(|| Ok(simhash_similarity(hash_a, hash_b)))
}

#[pyfunction]
fn rust_find_similar_chunks_simhash(
    py: Python<'_>,
    target_hash: u64,
    candidate_hashes: Vec<u64>,
    top_k: usize,
) -> PyResult<Vec<(usize, u32, f64)>> {
    py.allow_threads(|| Ok(find_similar_chunks_simhash_core(target_hash, &candidate_hashes, top_k)))
}

// ==============================================================================
// Flat Contiguous Binary Tape (ATHN) Architecture
// ==============================================================================

pub const BINARY_TAPE_MAGIC: u32 = 0x4154484E; // 'ATHN'
pub const BINARY_TAPE_VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 16;
pub const INDEX_RECORD_SIZE: usize = 16;

/// Encodes chunks into contiguous binary tape matching Dart BinaryBookTape.
pub fn encode_binary_book_tape(chunks: &[(&str, u32, u32)]) -> Vec<u8> {
    let count = chunks.len() as u32;
    let mut total_utf8_bytes = 0usize;
    for (text, _, _) in chunks {
        total_utf8_bytes += text.len();
    }

    let total_size = HEADER_SIZE + (chunks.len() * INDEX_RECORD_SIZE) + total_utf8_bytes;
    let mut buffer = vec![0u8; total_size];

    buffer[0..4].copy_from_slice(&BINARY_TAPE_MAGIC.to_be_bytes());
    buffer[4..8].copy_from_slice(&BINARY_TAPE_VERSION.to_be_bytes());
    buffer[8..12].copy_from_slice(&count.to_be_bytes());
    buffer[12..16].copy_from_slice(&(total_utf8_bytes as u32).to_be_bytes());

    let payload_start = HEADER_SIZE + (chunks.len() * INDEX_RECORD_SIZE);
    let mut current_offset = 0usize;
    let mut index_cursor = HEADER_SIZE;

    for (text, page, simhash_low) in chunks {
        let text_bytes = text.as_bytes();
        let len = text_bytes.len() as u32;

        buffer[index_cursor..index_cursor + 4].copy_from_slice(&(current_offset as u32).to_be_bytes());
        buffer[index_cursor + 4..index_cursor + 8].copy_from_slice(&len.to_be_bytes());
        buffer[index_cursor + 8..index_cursor + 12].copy_from_slice(&page.to_be_bytes());
        buffer[index_cursor + 12..index_cursor + 16].copy_from_slice(&simhash_low.to_be_bytes());

        let target_pos = payload_start + current_offset;
        buffer[target_pos..target_pos + text_bytes.len()].copy_from_slice(text_bytes);

        current_offset += text_bytes.len();
        index_cursor += INDEX_RECORD_SIZE;
    }

    buffer
}

/// Decodes a single chunk from binary tape in O(1) time without decoding the entire book.
pub fn decode_binary_book_tape_chunk(tape: &[u8], index: usize) -> Option<String> {
    if tape.len() < HEADER_SIZE {
        return None;
    }
    let magic = u32::from_be_bytes(tape[0..4].try_into().ok()?);
    if magic != BINARY_TAPE_MAGIC {
        return None;
    }
    let count = u32::from_be_bytes(tape[8..12].try_into().ok()?) as usize;
    if index >= count {
        return None;
    }

    let payload_start = HEADER_SIZE + (count * INDEX_RECORD_SIZE);
    let index_pos = HEADER_SIZE + (index * INDEX_RECORD_SIZE);
    if index_pos + INDEX_RECORD_SIZE > payload_start || payload_start > tape.len() {
        return None;
    }

    let start = u32::from_be_bytes(tape[index_pos..index_pos + 4].try_into().ok()?) as usize;
    let len = u32::from_be_bytes(tape[index_pos + 4..index_pos + 8].try_into().ok()?) as usize;

    let chunk_start = payload_start + start;
    let chunk_end = chunk_start + len;
    if chunk_end > tape.len() {
        return None;
    }

    std::str::from_utf8(&tape[chunk_start..chunk_end]).ok().map(|s| s.to_string())
}

#[pyfunction]
fn rust_encode_binary_tape(
    py: Python<'_>,
    texts: Vec<String>,
    pages: Vec<u32>,
    simhash_lows: Vec<u32>,
) -> PyResult<Vec<u8>> {
    py.allow_threads(|| {
        let mut chunks = Vec::with_capacity(texts.len());
        for i in 0..texts.len() {
            let page = pages.get(i).copied().unwrap_or(1);
            let sh = simhash_lows.get(i).copied().unwrap_or(0);
            chunks.push((texts[i].as_str(), page, sh));
        }
        Ok(encode_binary_book_tape(&chunks))
    })
}

#[pyfunction]
fn rust_read_binary_tape_chunk(
    py: Python<'_>,
    tape: Vec<u8>,
    index: usize,
) -> PyResult<Option<String>> {
    py.allow_threads(|| Ok(decode_binary_book_tape_chunk(&tape, index)))
}

#[pymodule]
fn athena_rust_core(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(rust_self_heal_prose_text, m)?)?;
    m.add_function(wrap_pyfunction!(rust_heal_pages_parallel, m)?)?;
    m.add_function(wrap_pyfunction!(rust_plan_feed_chunks, m)?)?;
    m.add_function(wrap_pyfunction!(rust_hybrid_bm25_search, m)?)?;
    m.add_function(wrap_pyfunction!(rust_cosine_similarity, m)?)?;
    m.add_function(wrap_pyfunction!(rust_check_slop_phrase, m)?)?;
    m.add_function(wrap_pyfunction!(rust_simhash64, m)?)?;
    m.add_function(wrap_pyfunction!(rust_simhash_hamming_distance, m)?)?;
    m.add_function(wrap_pyfunction!(rust_simhash_similarity, m)?)?;
    m.add_function(wrap_pyfunction!(rust_find_similar_chunks_simhash, m)?)?;
    m.add_function(wrap_pyfunction!(rust_encode_binary_tape, m)?)?;
    m.add_function(wrap_pyfunction!(rust_read_binary_tape_chunk, m)?)?;
    Ok(())
}

// ==============================================================================
// Dual Export: Flutter dart:ffi C-ABI
// ==============================================================================

#[no_mangle]
pub extern "C" fn athena_heal_and_chunk_json(
    raw_text: *const std::os::raw::c_char,
    target_words: usize,
) -> *mut std::os::raw::c_char {
    if raw_text.is_null() {
        return std::ptr::null_mut();
    }
    let c_str = unsafe { std::ffi::CStr::from_ptr(raw_text) };
    let input = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    let healed = self_heal_prose_text_core(input);

    // Simple sentence-based atom splitting to wire plan_feed_chunks_core
    let mut atom_starts = Vec::new();
    let mut atom_ends = Vec::new();
    let mut atom_words = Vec::new();
    let mut atom_para_ids = Vec::new();
    let mut atom_is_sentence = Vec::new();
    let mut atom_starts_section = Vec::new();

    let mut current_idx = 0;
    let mut para_id = 0;
    for para in healed.split("\n\n") {
        let para_trimmed = para.trim();
        if para_trimmed.is_empty() {
            current_idx += para.len() + 2;
            para_id += 1;
            continue;
        }
        let start_pos = healed[current_idx..].find(para_trimmed).unwrap_or(0) + current_idx;
        let mut sent_start = start_pos;
        for part in para_trimmed.split_inclusive(&['.', '!', '?'][..]) {
            let p_trimmed = part.trim();
            if p_trimmed.is_empty() {
                continue;
            }
            let s_start = healed[sent_start..].find(p_trimmed).unwrap_or(0) + sent_start;
            let s_end = s_start + p_trimmed.len();
            let words = p_trimmed.split_whitespace().count().max(1);
            atom_starts.push(s_start);
            atom_ends.push(s_end);
            atom_words.push(words);
            atom_para_ids.push(para_id);
            atom_is_sentence.push(true);
            atom_starts_section.push(atom_starts.len() == 1);
            sent_start = s_end;
        }
        current_idx = start_pos + para_trimmed.len();
        para_id += 1;
    }

    let chunks: Vec<serde_json::Value> = if !atom_starts.is_empty() {
        match plan_feed_chunks_core(
            &healed,
            &atom_starts,
            &atom_ends,
            &atom_words,
            &atom_para_ids,
            &atom_is_sentence,
            &atom_starts_section,
            target_words.max(35),
        ) {
            Ok(cuts) => cuts
                .into_iter()
                .map(|(s, e)| {
                    serde_json::json!({
                        "start_char": s,
                        "end_char": e,
                        "raw_text": &healed[s..e],
                    })
                })
                .collect(),
            Err(_) => vec![serde_json::json!({
                "start_char": 0,
                "end_char": healed.len(),
                "raw_text": &healed,
            })],
        }
    } else {
        Vec::new()
    };

    let json_res = serde_json::json!({
        "healed": healed,
        "target_words": target_words,
        "chunks": chunks,
    });
    let s = json_res.to_string();
    let c_res = std::ffi::CString::new(s).unwrap_or_default();
    c_res.into_raw()
}

#[no_mangle]
pub extern "C" fn athena_free_string(s: *mut std::os::raw::c_char) {
    if !s.is_null() {
        unsafe {
            let _ = std::ffi::CString::from_raw(s);
        }
    }
}

#[no_mangle]
pub extern "C" fn athena_cosine_similarity(
    v1: *const f32,
    len1: usize,
    v2: *const f32,
    len2: usize,
) -> f64 {
    if v1.is_null() || v2.is_null() {
        return 0.0;
    }
    let s1 = unsafe { std::slice::from_raw_parts(v1, len1) };
    let s2 = unsafe { std::slice::from_raw_parts(v2, len2) };
    cosine_similarity_simd(s1, s2)
}

#[no_mangle]
pub extern "C" fn athena_simhash64(raw_text: *const std::os::raw::c_char) -> u64 {
    if raw_text.is_null() {
        return 0;
    }
    let c_str = unsafe { std::ffi::CStr::from_ptr(raw_text) };
    let input = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };
    compute_simhash64(input)
}

#[no_mangle]
pub extern "C" fn athena_simhash_similarity(hash_a: u64, hash_b: u64) -> f64 {
    simhash_similarity(hash_a, hash_b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simhash64_similarity() {
        let text1 = "Marcus Aurelius was an emperor of Rome who practiced Stoic philosophy";
        let text2 = "Marcus Aurelius was a Roman emperor practicing Stoic philosophy daily";
        let text3 = "Quantum electrodynamics describes relativistic interaction of charged particles";

        let hash1 = compute_simhash64(text1);
        let hash2 = compute_simhash64(text2);
        let hash3 = compute_simhash64(text3);

        let dist_similar = simhash_hamming_distance(hash1, hash2);
        let dist_diff = simhash_hamming_distance(hash1, hash3);

        // Near-duplicate stoic passages have significantly lower Hamming distance
        assert!(dist_similar < dist_diff);
        let sim = simhash_similarity(hash1, hash2);
        assert!(sim > 0.70);

        let candidates = vec![hash2, hash3];
        let ranked = find_similar_chunks_simhash_core(hash1, &candidates, 2);
        assert_eq!(ranked[0].0, 0); // text2 should rank first
    }

    #[test]
    fn test_self_heal_hygiene() {
        let raw = "The emperor Antoninus was wise. Foulis;2 noted that sum- mer was warm. uuuuuu";
        let healed = self_heal_prose_text_core(raw);
        assert!(healed.contains("summer"));
        assert!(healed.contains("Foulis;"));
        assert!(!healed.contains("uuuuuu"));
    }

    #[test]
    fn test_cosine_similarity() {
        let v1 = vec![1.0, 0.0, 0.0];
        let v2 = vec![1.0, 0.0, 0.0];
        let sim = cosine_similarity_simd(&v1, &v2);
        assert!((sim - 1.0).abs() < 1e-6);

        let v3 = vec![0.0, 1.0, 0.0];
        let sim_ortho = cosine_similarity_simd(&v1, &v3);
        assert!(sim_ortho.abs() < 1e-6);
    }

    #[test]
    fn test_slop_phrase_scanner() {
        let text = "In this passage, Marcus highlights virtue.";
        let found = scan_banned_slop_phrase(text);
        assert_eq!(found, Some("in this passage"));
    }

    #[test]
    fn test_bm25_search() {
        let docs = vec![
            "Marcus Aurelius was an emperor of Rome".to_string(),
            "Epictetus was a stoic philosopher who taught in Greece".to_string(),
            "Seneca wrote letters to Lucilius about virtue".to_string(),
        ];
        let res = hybrid_bm25_search_core(&docs, "Marcus emperor", 2);
        assert!(!res.is_empty());
        assert_eq!(res[0].0, 0);
    }
}
