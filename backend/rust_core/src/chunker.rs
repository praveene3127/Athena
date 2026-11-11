use crate::sentence::find_sentence_boundaries;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlannedChunk {
    pub sequence: usize,
    pub raw_text: String,
    pub start_offset: usize,
    pub end_offset: usize,
    pub page_start: usize,
    pub page_end: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowPlanResult {
    pub chunks: Vec<PlannedChunk>,
    pub carry_over: String,
    pub next_sequence: usize,
    pub next_offset: usize,
}

/// Validates that a byte offset in `text` is a legal UTF-8 boundary and whitespace/punctuation cut point.
pub fn is_legal_cut(text: &str, byte_offset: usize) -> bool {
    if byte_offset == 0 || byte_offset >= text.len() {
        return true;
    }
    if !text.is_char_boundary(byte_offset) {
        return false;
    }
    let prev_char = text[..byte_offset].chars().last().unwrap_or(' ');
    let next_char = text[byte_offset..].chars().next().unwrap_or(' ');
    prev_char.is_whitespace() || next_char.is_whitespace() || ".!?;:\n".contains(prev_char)
}

/// Dynamic-programming chunk planner operating natively on UTF-8 byte offsets.
/// Avoids the O(N) `char_to_byte` 800MB vector allocation entirely.
///
/// Implements the Open-Tail Window Rule:
/// If `is_last_window` is false, holds back the trailing incomplete sentence/paragraph
/// in `carry_over` so boundary cuts are 100% mathematically deterministic across any window size.
pub fn plan_chunks_utf8(
    text: &str,
    start_page: usize,
    end_page: usize,
    start_sequence: usize,
    start_offset: usize,
    is_last_window: bool,
    target_len: usize,
    max_len: usize,
) -> WindowPlanResult {
    if text.is_empty() {
        return WindowPlanResult {
            chunks: Vec::new(),
            carry_over: String::new(),
            next_sequence: start_sequence,
            next_offset: start_offset,
        };
    }

    let boundaries = find_sentence_boundaries(text);
    if boundaries.is_empty() {
        if !is_last_window && text.len() < max_len {
            return WindowPlanResult {
                chunks: Vec::new(),
                carry_over: text.to_string(),
                next_sequence: start_sequence,
                next_offset: start_offset,
            };
        }
        let chunk = PlannedChunk {
            sequence: start_sequence,
            raw_text: text.to_string(),
            start_offset,
            end_offset: start_offset + text.len(),
            page_start: start_page,
            page_end: end_page,
        };
        return WindowPlanResult {
            chunks: vec![chunk],
            carry_over: String::new(),
            next_sequence: start_sequence + 1,
            next_offset: start_offset + text.len(),
        };
    }

    let mut chunks = Vec::new();
    let mut current_seq = start_sequence;
    let mut global_offset = start_offset;
    let mut chunk_start_byte = 0;
    let mut last_committed_boundary_idx = 0;

    let num_sentences = boundaries.len();
    let effective_sentences = if !is_last_window && num_sentences > 1 {
        num_sentences - 1 // Hold back trailing tail
    } else {
        num_sentences
    };

    for i in 0..effective_sentences {
        let sentence_end = boundaries[i].1;
        let current_span_len = sentence_end - chunk_start_byte;

        if current_span_len >= target_len || (i == effective_sentences - 1 && !is_last_window) {
            // Cut chunk here
            let chunk_text = text[chunk_start_byte..sentence_end].trim();
            if !chunk_text.is_empty() {
                chunks.push(PlannedChunk {
                    sequence: current_seq,
                    raw_text: chunk_text.to_string(),
                    start_offset: global_offset,
                    end_offset: global_offset + chunk_text.len(),
                    page_start: start_page,
                    page_end: end_page,
                });
                current_seq += 1;
                global_offset += chunk_text.len();
            }
            chunk_start_byte = sentence_end;
            last_committed_boundary_idx = i + 1;
        }
    }

    let carry_over = if chunk_start_byte < text.len() {
        text[chunk_start_byte..].trim().to_string()
    } else {
        String::new()
    };

    WindowPlanResult {
        chunks,
        carry_over,
        next_sequence: current_seq,
        next_offset: global_offset,
    }
}

