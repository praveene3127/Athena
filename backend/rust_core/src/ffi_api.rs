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

