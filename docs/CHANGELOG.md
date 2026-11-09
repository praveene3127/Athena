# Changelog

All notable changes to the Athena project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.0] - 2026-11-09

### Master Audit & Production Hardening Release

This major milestone resolves all P0, P1, and P2 defects discovered across the Rust core, FastAPI backend, Flutter mobile client, and cross-platform orchestration layer. It guarantees cryptographic lossless document reconstruction, responsive mobile reading ergonomics, secure LAN pairing, and verified academic evidence grounding.

---

### Batch 1: Rust Core Regex Panic Fix, Backend P0 Crashes, Evidence Pipeline, BYOK & LAN Security
- **Rust Core Look-Around Regex Panic Fix (`backend/rust_core/src/lib.rs`, `Cargo.toml`) [P0-01]**:
  - Replaced look-behind `(?<=...)` and look-ahead `(?=...)` in `FN_PUNCT_RE`, `FN_WORD_RE`, and `PUNCT_SPACE_RE` with capture-group regexes supported by Rust's `regex` crate, eliminating runtime panics on document processing.
  - Set `panic = "unwind"` in `[profile.release]` so PyO3 translates unexpected Rust panics into catchable Python exceptions rather than killing the server process via `SIGABRT`.
  - Wired native `rust_plan_feed_chunks` into `backend/app/services/ingestion/chunker.py` with seamless pure-Python fallback.
- **Backend Endpoint Crash Hardening (`backend/app/routers/cards.py`, `documents.py`) [P0-02]**:
  - Aligned `extract_concepts` function signature to accept `(raw_text, title, author, max_concepts=...)` without parameter mismatch errors.
  - Resolved `ContextCard` model compatibility issues in card persistence.
  - Fixed `/api/documents/{id}/tape` endpoint handling for zero-copy binary book tape retrieval.
  - Guarded EPUB documents against scanned PDF OCR triage checks.
- **Multi-Source Evidence Aggregation (`backend/app/services/marginalia/search.py`)**:
  - Unified academic paper querying across Crossref, Europe PMC, and OpenAlex with rate limiting and structured fallback.
- **LAN Security & BYOK Encryption (`backend/app/security.py`, `backend/app/routers/settings.py`)**:
  - Implemented AES-GCM credential encryption (`enc:v1:...`) for stored BYOK API keys.
  - Hardened SSRF defense: blocked cloud metadata IPs (`169.254.169.254`, `metadata.google.internal`) and prevented unauthenticated public access to local loopback endpoints.
  - Added single-origin health and database contract verification.

---

### Batch 2: Mobile Ingestion Lossless Invariant, EPUB Tag Fidelity, Tape & SQLite Migrations
- **Lossless Ingestion Reconstruction (`app/lib/services/ingestion_pipeline.dart`) [P0-06]**:
  - Fixed multi-batch PDF ingestion offset calculation to eliminate byte drift between sliding windows.
  - Hardened integrity check to compare reconstructed chunk concatenation SHA-256 directly against canonical text hash (`reconstructedSha256 == canonicalSha256`).
- **EPUB Inline Tag Fidelity & Structural Preservation**:
  - Preserved whitespace and sentence continuity when stripping HTML tags (`<b>`, `<i>`, `<em>`, `<a>`, `<span>`) during EPUB ingestion.
  - Guarded Table of Contents (TOC) detector with strict Roman numeral (`\b(?:i|ii|iii|...|l)\b`) and multi-dot separator patterns, eliminating false positive TOC drops on standard prose.
- **Zero-JSON Flat Binary Tape (`app/lib/services/binary_book_tape.dart`, `local_database.dart`)**:
  - Implemented flat binary tape format (`ATHN` magic bytes, fixed 16-byte index records, back-to-back UTF-8 blob) with $O(1)$ random-access slicing.
  - Added SQLite schema migrations with backward-compatible column checks and transactional safety.
- **Network & Isolate Timeouts**:
  - Added bounded execution timers across isolate worker tasks to prevent hung extraction jobs.

---

### Batch 3: Verified Card Integrity, Novelty Gate & Reader UI Wiring
- **Stopword-Filtered IDF Evidence Relevance Scorer (`app/lib/services/local_context_service.dart`)**:
  - Replaced naive keyword overlap with an IDF-weighted relevance scorer filtering out academic boilerplate terms (`study`, `paper`, `journal`, `volume`, `analysis`).
  - Required target concept presence in candidate title/abstract plus at least 2 distinct passage keywords and a valid DOI/URL.
- **Citation Overwrite & Hallucination Defense**:
  - Guaranteed external citation attributes (`title`, `authors`, `year`, `venue`, `doi`, `url`) overwrite any LLM-synthesized placeholder text.
  - Enforced exact quote anchoring invariant: every card must anchor to a verified verbatim substring of the source passage.
- **On-Device Lexical Novelty Gate**:
  - Integrated local lexical novelty verification and anti-echo cosine similarity ceiling ($\le 0.81$) to eliminate repetitive paraphrases.
- **Reader UI Wiring & Styling (`app/lib/features/reader/`)**:
  - Hardened `ReaderTopBar`, `ReaderFeedView`, `ReaderFlowView`, `ChunkWidget`, and `ReaderBottomBar` with responsive mobile layout constraints.
  - Enforced theme tokens via `ReaderThemeConfig` (Paper, Sepia, Night, Obsidian) with comfortable 16px margins on mobile screens (`360px–430px`).

---

### Batch 4: Android LAN Pairing, Cross-Platform Launcher, Release Verification & Version Unification
- **Android Wi-Fi LAN Cleartext & Pairing (`network_security_config.xml`, `AndroidManifest.xml`, `api_client.dart`) [Audit 2 P0-4]**:
  - Enabled base cleartext network traffic in Android configuration specifically to unblock private RFC1918 Wi-Fi IPs (`192.168.x.x`, `10.x.x.x`, `172.16–31.x.x`).
  - Enforced strict Dart-side validation in `AppConfig.isPermittedHttpUrl` and `ApiClient`: plain `http://` is strictly permitted for local loopback and RFC1918 private subnets; public internet domains require `https://`.
  - Structured pairing error reporting with actionable user codes (`CLEARTEXT_NOT_PERMITTED`, `INVALID_PAIRING_TOKEN`, `CONNECTION_TIMED_OUT`).
- **Cross-Platform Launcher & Supervisor (`scripts/run_athena.py`, `scripts/run_athena.sh`)**:
  - Enhanced `scripts/run_athena.py` with Python 3.10+ enforcement, CLI argument parsing (`--lan`, `--host`, `--port`, `--web-port`), and crash backoff supervisor.
  - Added secure 16-byte pairing token generation on `--lan` with terminal ASCII QR code and copy-paste connection box.
  - Created executable bash runner `scripts/run_athena.sh` for macOS and Linux environments.
- **Strict Verification Gates (`scripts/verify_release.py`, `scripts/strict_goal_judge.py`)**:
  - Expanded `scripts/verify_release.py` into an 8-gate automated test suite verifying version consistency, static grep anti-slop rules, cargo tests, technical word preservation, API matrix contracts, pytest suite, flutter analyze/test, and core mathematical invariants.
  - Replaced hollow tests in `app/test/artcraft_reader_harness_test.dart` with concrete widget rendering, button hit-target, and chunk cadence assertions.
- **Version Unification (`1.1.0`)**:
  - Synchronized version `1.1.0` across `app/pubspec.yaml`, `app/lib/core/config/config.dart`, `scripts/version.json`, `backend/pyproject.toml`, and `backend/app/main.py`.

