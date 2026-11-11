use std::collections::HashSet;
use std::sync::LazyLock;
use regex::Regex;

pub const COMPOUND_PREFIXES: &[&str] = &[
    "self", "non", "pre", "post", "anti", "co", "multi", "meta", "pseudo",
    "quasi", "well", "high", "low", "counter", "inter", "sub", "super",
    "ultra", "over", "under", "re", "ex", "all", "half", "cross",
];

pub const KNOWN_TECHNICAL_WORDS: &[&str] = &[
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

pub const PROTECTED_ALPHANUMERIC: &[&str] = &[
    "h2o", "co2", "3d", "4d", "5d", "mp3", "mp4", "b12", "o2", "n2",
    "f1", "f2", "a4", "b5", "v8", "v12", "k9", "g7", "g8", "g20",
];

static DEHYPHEN_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b([A-Za-z]+)-\s+([a-z]+)\b").unwrap()
});
static WS_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[ \t]+").unwrap()
});
static PUNCT_SPACE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"([;:,!?])([A-Za-z])").unwrap()
});

#[derive(Debug, Default, Clone)]
pub struct RepairLedger {
    pub ligatures_replaced: usize,
    pub soft_hyphens_removed: usize,
    pub broken_dehyphenated: usize,
    pub fused_kerning_repaired: usize,
    pub footnote_markers_stripped: usize,
}

/// Normalizes unicode ligatures into their canonical ASCII letter sequences.
pub fn normalize_ligatures(text: &str) -> (String, usize) {
    let mut count = 0;
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\u{fb00}' => { out.push_str("ff"); count += 1; }
            '\u{fb01}' => { out.push_str("fi"); count += 1; }
            '\u{fb02}' => { out.push_str("fl"); count += 1; }
            '\u{fb03}' => { out.push_str("ffi"); count += 1; }
            '\u{fb04}' => { out.push_str("ffl"); count += 1; }
            '\u{fb05}' => { out.push_str("ft"); count += 1; }
            '\u{fb06}' => { out.push_str("st"); count += 1; }
            other => out.push(other),
        }
    }
    (out, count)
}

/// Dehyphenates broken line-wraps while preserving legitimate compound words and prefixes.
pub fn dehyphenate_line_ends(text: &str, known_vocab: &HashSet<String>) -> (String, usize) {
    let mut fixes = 0;
    let result = DEHYPHEN_RE.replace_all(text, |caps: &regex::Captures| {
        let left = &caps[1];
        let right = &caps[2];
        let left_lower = left.to_lowercase();
        let right_lower = right.to_lowercase();
        let joined = format!("{}{}", left_lower, right_lower);

        if COMPOUND_PREFIXES.contains(&left_lower.as_str()) {
            return format!("{}-{}", left, right);
        }

        if known_vocab.contains(&joined) || KNOWN_TECHNICAL_WORDS.contains(&joined.as_str()) {
            fixes += 1;
            return format!("{}{}", left, right);
        }

        // If unknown, join if short syllable wrap
        if left.len() <= 3 || right.len() <= 3 {
            fixes += 1;
            format!("{}{}", left, right)
        } else {
            format!("{}-{}", left, right)
        }
    });

    (result.into_owned(), fixes)
}

/// Comprehensive self-healing text hygiene pipeline with an auditable RepairLedger.
pub fn self_heal_prose_text_core(raw: &str) -> (String, RepairLedger) {
    let mut ledger = RepairLedger::default();

    // 1. Ligature normalization
    let (t1, lig_count) = normalize_ligatures(raw);
    ledger.ligatures_replaced = lig_count;

    // 2. Soft-hyphen stripping
    let mut t2 = String::with_capacity(t1.len());
    for c in t1.chars() {
        if c == '\u{00ad}' {
            ledger.soft_hyphens_removed += 1;
        } else {
            t2.push(c);
        }
    }

    // 3. Dehyphenation of line wraps
    let known_set: HashSet<String> = KNOWN_TECHNICAL_WORDS.iter().map(|s| s.to_string()).collect();
    let (t3, dehyphen_count) = dehyphenate_line_ends(&t2, &known_set);
    ledger.broken_dehyphenated = dehyphen_count;

    // 4. Punctuation spacing (e.g. "word,word" -> "word, word")
    let t4 = PUNCT_SPACE_RE.replace_all(&t3, "$1 $2");

    // 5. Whitespace collapsing
    let t5 = WS_RE.replace_all(&t4, " ");

    (t5.trim().to_string(), ledger)
}

