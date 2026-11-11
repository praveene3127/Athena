use std::sync::LazyLock;
use regex::Regex;

static SENTENCE_BOUNDARY_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"([.!?]+["'\u{2019}\u{201d}]?)\s+([A-Z0-9\u{201c}\u{2018}\(\[])"#).unwrap()
});

static ABBREVIATIONS: &[&str] = &[
    "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "vs.", "etc.",
    "e.g.", "i.e.", "u.s.", "u.k.", "inc.", "ltd.", "co.", "approx.",
    "dept.", "est.", "vol.", "no.", "fig.", "al.", "cf.", "st.", "col.",
];

/// Finds sentence boundaries as byte offsets `(start_byte, end_byte)` in text,
/// strictly aware of English honorifics, abbreviations, and trailing quotes.
pub fn find_sentence_boundaries(text: &str) -> Vec<(usize, usize)> {
    if text.trim().is_empty() {
        return Vec::new();
    }

    let mut boundaries = Vec::new();
    let mut current_start = 0;

    for caps in SENTENCE_BOUNDARY_RE.captures_iter(text) {
        let full_match = caps.get(0).unwrap();
        let punct_group = caps.get(1).unwrap();
        let cut_idx = punct_group.end();

        // Check if preceding token is an abbreviation
        let prefix = &text[current_start..cut_idx].trim_end();
        let last_word = prefix.split_whitespace().last().unwrap_or("").to_lowercase();

        if ABBREVIATIONS.contains(&last_word.as_str()) {
            // Not a real sentence boundary, skip
            continue;
        }

        if cut_idx > current_start {
            boundaries.push((current_start, cut_idx));
            current_start = full_match.end() - caps.get(2).unwrap().len();
        }
    }

    if current_start < text.len() {
        boundaries.push((current_start, text.len()));
    }

    boundaries
}

