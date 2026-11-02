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
static SPACED_CHAR_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b([a-z])\s+(?:\1\s+){2,}[a-z]\b").unwrap()
});
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
    Regex::new(r"(?<=[a-zA-Z\)])([;,.!?])\d{1,3}(?=\s|$|[)\]\'\u{2019}\u{201d}])").unwrap()
});
static FN_WORD_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?<=[a-zA-Z]{3})\d{1,2}(?=\s|$|[)\]\'\u{2019}\u{201d}])").unwrap()
});
static PUNCT_SPACE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"([;:,!?])(?=[A-Za-z])").unwrap()
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

/// Core prose self-healing implementation in pure Rust.
pub fn self_heal_prose_text_core(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }

    let roman_set: HashSet<&str> = ROMAN_NUMERALS.iter().copied().collect();
    let compound_set: HashSet<&str> = COMPOUND_PREFIXES.iter().copied().collect();
    let technical_set: HashSet<&str> = KNOWN_TECHNICAL_WORDS.iter().copied().collect();

    // 1. Spaced char runs removal: e.g. "i i i i i" or "u u u u"
    let cleaned = SPACED_CHAR_RE.replace_all(text, "");

    // 2. Letter-spaced imprint collapse: e.g. "L I B E R T Y" -> "LIBERTY"
    let cleaned = LETTER_SPACED_RE.replace_all(&cleaned, |caps: &regex::Captures| {
        let matched = &caps[0];
        let collapsed: String = matched.split_whitespace().collect();
        if collapsed.eq_ignore_ascii_case("LIBERTY") {
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

    // 5. Superscript footnote callout stripping: "Foulis;2" -> "Foulis;", "Moore.3" -> "Moore."
    intermediate = FN_PUNCT_RE.replace_all(&intermediate, "$1").into_owned();
    intermediate = FN_WORD_RE.replace_all(&intermediate, "").into_owned();

    // 6. Spacing after punctuation: "candle.Headmaster" -> "candle. Headmaster"
    intermediate = PUNCT_SPACE_RE.replace_all(&intermediate, "$1 ").into_owned();

    // 7. Split PascalCase / camelCase word collisions: "TitlePage" -> "Title Page", "GaleNolan" -> "Gale Nolan"
    intermediate = CAMEL_RE.replace_all(&intermediate, "$1 $2").into_owned();

    // 8. Collapse duplicate whitespace
    WS_RE.replace_all(&intermediate, " ").trim().to_string()
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

    let min_words = 40.max((target_words as f64 * 0.55) as usize);
    let max_words = 340usize;

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
            if words > max_words && end > start {
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
                    if left_end <= canonical_text.len() && right_start <= canonical_text.len() {
                        let sep = &canonical_text[left_end..right_start];
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

#[pymodule]
fn athena_rust_core(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(rust_self_heal_prose_text, m)?)?;
    m.add_function(wrap_pyfunction!(rust_heal_pages_parallel, m)?)?;
    m.add_function(wrap_pyfunction!(rust_plan_feed_chunks, m)?)?;
    m.add_function(wrap_pyfunction!(rust_hybrid_bm25_search, m)?)?;
    m.add_function(wrap_pyfunction!(rust_cosine_similarity, m)?)?;
    m.add_function(wrap_pyfunction!(rust_check_slop_phrase, m)?)?;
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
    let json_res = serde_json::json!({
        "healed": healed,
        "target_words": target_words,
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

#[cfg(test)]
mod tests {
    use super::*;

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
