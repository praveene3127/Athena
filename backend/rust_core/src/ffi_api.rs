use crate::chunker::plan_chunks_utf8;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::catch_unwind;

#[repr(C)]
pub struct FfiChunkResult {
    pub chunk_count: u32,
    pub json_payload: *mut c_char,
    pub status_code: i32,
}

/// Computes 64-bit SimHash of text.
#[no_mangle]
pub extern "C" fn athena_rust_simhash64(text: *const c_char) -> u64 {
    let result = catch_unwind(|| {
        if text.is_null() {
            return 0u64;
        }
        let c_str = unsafe { CStr::from_ptr(text) };
        let str_slice = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return 0u64,
        };
        crate::rust_simhash64(str_slice)
    });

    result.unwrap_or(0u64)
}

/// Dynamic programming UTF-8 chunk planning exposed over C-ABI.
#[no_mangle]
pub extern "C" fn athena_rust_plan_chunks_utf8(
    text: *const c_char,
    start_page: usize,
    end_page: usize,
    start_sequence: usize,
    start_offset: usize,
    is_last_window: bool,
    target_len: usize,
    max_len: usize,
) -> FfiChunkResult {
    let outcome = catch_unwind(|| {
        if text.is_null() {
            return FfiChunkResult {
                chunk_count: 0,
                json_payload: std::ptr::null_mut(),
                status_code: -1,
            };
        }
        let c_str = unsafe { CStr::from_ptr(text) };
        let str_slice = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => {
                return FfiChunkResult {
                    chunk_count: 0,
                    json_payload: std::ptr::null_mut(),
                    status_code: -2,
                }
            }
        };

        let plan = plan_chunks_utf8(
            str_slice,
            start_page,
            end_page,
            start_sequence,
            start_offset,
            is_last_window,
            target_len,
            max_len,
        );

        let json = serde_json::to_string(&plan).unwrap_or_default();
        let c_json = CString::new(json).unwrap();

        FfiChunkResult {
            chunk_count: plan.chunks.len() as u32,
            json_payload: c_json.into_raw(),
            status_code: 0,
        }
    });

    outcome.unwrap_or(FfiChunkResult {
        chunk_count: 0,
        json_payload: std::ptr::null_mut(),
        status_code: -99,
    })
}

/// Frees CString allocated by FFI.
#[no_mangle]
pub extern "C" fn athena_rust_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// Ingests EPUB windowed streaming spine items and plans chunks.
#[no_mangle]
pub extern "C" fn athena_rust_ingest_epub_windowed(
    path: *const c_char,
    start_spine: usize,
    count: usize,
) -> *mut c_char {
    let outcome = catch_unwind(|| {
        if path.is_null() {
            return std::ptr::null_mut();
        }
        let c_str = unsafe { CStr::from_ptr(path) };
        let path_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        };

        let extractor = match crate::epub_stream::EpubStreamExtractor::open(path_str) {
            Ok(e) => e,
            Err(_) => return std::ptr::null_mut(),
        };

        let spine_entries = extractor.list_spine_entries().unwrap_or_default();
        let mut all_blocks = Vec::new();
        let max_idx = (start_spine + count).min(spine_entries.len());
        for spine_idx in start_spine..max_idx {
            if let Some(entry_name) = spine_entries.get(spine_idx) {
                if let Ok(blocks) = extractor.stream_spine_entry(entry_name, spine_idx) {
                    all_blocks.extend(blocks);
                }
            }
        }

        let combined_text = all_blocks
            .iter()
            .map(|b| b.text.as_str())
            .collect::<Vec<_>>()
            .join("\n\n");

        let plan = crate::chunker::plan_chunks_utf8(
            &combined_text,
            start_spine,
            start_spine + count,
            1,
            0,
            true,
            240,
            500,
        );

        let json = serde_json::to_string(&plan).unwrap_or_default();
        CString::new(json).map(|cs| cs.into_raw()).unwrap_or(std::ptr::null_mut())
    });

    outcome.unwrap_or(std::ptr::null_mut())
}

/// Atomically commits planned window batch into reading_chunks table via Rust SqliteStore.
#[no_mangle]
pub extern "C" fn athena_rust_commit_window_batch(
    db_path: *const c_char,
    doc_id: *const c_char,
    window_page_start: usize,
    window_page_end: usize,
    chunks_json: *const c_char,
    carry_over: *const c_char,
    prev_chain_hash: *const c_char,
    status: *const c_char,
) -> *mut c_char {
    let outcome = catch_unwind(|| {
        if db_path.is_null() || doc_id.is_null() || chunks_json.is_null() {
            return std::ptr::null_mut();
        }
        let p = match unsafe { CStr::from_ptr(db_path) }.to_str() {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        };
        let d = match unsafe { CStr::from_ptr(doc_id) }.to_str() {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        };
        let c_json = match unsafe { CStr::from_ptr(chunks_json) }.to_str() {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        };
        let co = if carry_over.is_null() {
            ""
        } else {
            unsafe { CStr::from_ptr(carry_over) }.to_str().unwrap_or("")
        };
        let pch = if prev_chain_hash.is_null() {
            ""
        } else {
            unsafe { CStr::from_ptr(prev_chain_hash) }.to_str().unwrap_or("")
        };
        let st = if status.is_null() {
            "processing"
        } else {
            unsafe { CStr::from_ptr(status) }.to_str().unwrap_or("processing")
        };

        let chunks: Vec<crate::chunker::PlannedChunk> = match serde_json::from_str(c_json) {
            Ok(c) => c,
            Err(_) => return std::ptr::null_mut(),
        };

        let mut store = match crate::sqlite_store::SqliteStore::open(p) {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        };

        match store.commit_window_batch(d, window_page_start, window_page_end, &chunks, co, pch, st) {
            Ok(new_hash) => CString::new(new_hash).map(|cs| cs.into_raw()).unwrap_or(std::ptr::null_mut()),
            Err(_) => std::ptr::null_mut(),
        }
    });

    outcome.unwrap_or(std::ptr::null_mut())
}

