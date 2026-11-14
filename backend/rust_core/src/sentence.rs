use std::sync::LazyLock;
use regex::Regex;

static SENTENCE_BOUNDARY_RE: LazyLock<Regex> = LazyLock::new(|| {
    // Captures (punct + quotes)(optional or required whitespace)(following token)
    // Supports Latin (.!?…), CJK (。\uff01\uff1f), Indic (।॥), Arabic (؟)
    Regex::new(r#"([.!?…\u{3002}\u{ff01}\u{ff1f}\u{0964}\u{0965}\u{061f}]+["'\u{2019}\u{201d}\u{00bb}\)\]]*)([\s\u{3000}]*)((?:[\p{Lu}\p{Lt}\p{N}"'\u{201c}\u{2018}\(\[«¿¡]|[\u{0900}-\u{097F}\u{0B80}-\u{0BFF}\u{0600}-\u{06FF}\u{0590}-\u{05FF}\u{3040}-\u{9FFF}\u{AC00}-\u{D7AF}]))"#).unwrap()
});

static ABBREVIATIONS: &[&str] = &[
    "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "vs.", "etc.",
    "e.g.", "i.e.", "u.s.", "u.k.", "inc.", "ltd.", "co.", "approx.",
    "dept.", "est.", "vol.", "no.", "fig.", "al.", "cf.", "st.", "col.",
];

/// Finds sentence boundaries as contiguous byte offsets `(start_byte, end_byte)` in text,
/// strictly aware of English honorifics, abbreviations, decimals, and multilingual terminators.
pub fn find_sentence_boundaries(text: &str) -> Vec<(usize, usize)> {
    if text.trim().is_empty() {
        return Vec::new();
    }

    let mut boundaries = Vec::new();
    let mut current_start = 0;

    for caps in SENTENCE_BOUNDARY_RE.captures_iter(text) {
        let full_match = caps.get(0).unwrap();
        let punct_group = caps.get(1).unwrap();
        let ws_group = caps.get(2).unwrap();
        let next_group = caps.get(3).unwrap();
        let punct_end = punct_group.end();
        let cut_idx = ws_group.end();

        // Guard 1: Decimal numbers like 3.14 or 2.0
        if punct_end > 0 && punct_end < text.len() {
            let prev_byte = text.as_bytes()[punct_end - 1];
            let next_byte = text.as_bytes()[punct_end];
            if prev_byte.is_ascii_digit() && next_byte.is_ascii_digit() {
                continue;
            }
        }

        // Guard 2: Preceding token is an abbreviation
        let prefix = text[current_start..punct_end].trim_end();
        let last_word = prefix.split_whitespace().last().unwrap_or("").to_lowercase();

        if ABBREVIATIONS.contains(&last_word.as_str()) {
            continue;
        }

        // Guard 3: Single letter initial like 'J.'
        if last_word.len() == 2 && last_word.ends_with('.') {
            let first = last_word.as_bytes()[0];
            if first.is_ascii_alphabetic() {
                continue;
            }
        }

        // For ASCII text without trailing whitespace after punct, require whitespace before next word
        let is_cjk_punct = punct_group.as_str().chars().any(|c| {
            matches!(c, '\u{3002}' | '\u{ff01}' | '\u{ff1f}' | '\u{0964}' | '\u{0965}' | '\u{061f}')
        });
        if ws_group.as_str().is_empty() && !is_cjk_punct {
            // E.g. within a compound or URL
            continue;
        }

        if cut_idx > current_start && cut_idx < text.len() {
            boundaries.push((current_start, cut_idx));
            current_start = cut_idx;
        }
    }

    if current_start < text.len() {
        boundaries.push((current_start, text.len()));
    }

    boundaries
}

