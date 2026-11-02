# athena_rust_core

High-performance Rust text processing engine for Athena using PyO3 and Maturin.

## Architecture ("The `pydantic-core` Pattern")
`athena_rust_core` provides zero-overhead, compiled SIMD-friendly implementations of CPU-intensive routines:
1. `rust_self_heal_prose_text`: Shannon entropy filtering, line-wrap dehyphenation, footnote callout stripping, and kerning recovery.
2. `rust_plan_feed_chunks`: Optimal dynamic programming boundary search for lossless corpus chunking with SHA-256 verification.
3. `rust_hybrid_bm25_search`: In-memory Robertson-Spärck Jones BM25 search ($k_1=1.5, b=0.75$).
4. `rust_cosine_similarity`: Vector dot-product cosine similarity for anti-echo novelty audits.

## Building & Installing
When `cargo` and `rustup` are installed:
```bash
pip install maturin
cd backend/rust_core
maturin develop --release
```
When compiled, Athena automatically uses `athena_rust_core` for up to ~80x speedup; otherwise, it falls back seamlessly to pure-Python implementations with 100% identical outputs.

