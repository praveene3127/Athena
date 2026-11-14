# ATHENA — Architecture Decisions Log (DECISIONS.md)

1. **Target Platform Architecture [SUPERSEDED]:**
   - *Superseded by Dual-Mode Architecture*: Athena operates in **Dual-Mode**:
     1. **Standalone On-Device Mobile Mode**: Runs 100% on Android via native Rust FFI (`athena_rust_core`) and SQLite, extracting text, streaming chunks, and generating edge marginalia with zero companion server required.
     2. **Optional LAN Companion Server Mode**: Communicates with the FastAPI backend over dynamic Wi-Fi LAN pairing (`/api/pair-info`), mDNS, or Cloudflare Tunnels (with single-origin Flutter Web hosting), completely superseding USB-only `adb reverse`.
2. **Screenshot-led UI Direction [SUPERSEDED]:**
   - *Superseded by Four-Theme System*: The early exploratory single-screenshot palette has been superseded by Athena's unified 4-appearance design system (`Paper`, `Sepia`, `Charcoal`, `OLED`) engineered for high-comfort long-form reading across mobile OLED and paper-like environments.
3. **Design System Tokens [SUPERSEDED]:**
   - *Superseded by AthenaTokens*: Replaced ad-hoc color references with 4 concrete `AthenaTokens` presets sharing identical interfaces across mobile reader and application shells:
     - `Paper`: `#FBF9F5` warm linen canvas, `#161615` ink, `#2D6A4F` forest accent.
     - `Sepia`: `#F4ECD8` parchment canvas, `#2C221E` deep bistre ink, `#8C4A27` burnt sienna accent.
     - `Charcoal`: `#121316` low-contrast dark canvas, `#ECEAE4` soft ink, `#34D399` emerald accent.
     - `OLED`: `#000000` true-black canvas, `#F5F5F0` high-contrast ink, `#34D399` accent.
4. **Agent Skills Engine:** Integrated `.agents/skills/` as the continuous on-demand engineering skills engine, guiding clean architecture, invariant verification, and performance benchmarks.
5. **Lossless Chunker Invariant:** Reading chunks are created strictly by slicing canonical text character offsets `canonical_text[start:end]` to preserve 100% fidelity; string splitting and rejoining is strictly prohibited. `"".join(chunks) == canonical_text` with matching SHA-256 digests.
6. **4-Way Integrity Guarantee:** A document is only marked `ready` if: joined chunks == canonical text, offsets are contiguous from 0 to len, slice identity holds for all chunks, and SHA-256 checksums match.
7. **Database Concurrency:** SQLite in WAL mode (`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;`) with distinct database sessions per request, indexed keyset queries, and FTS5 synchronization triggers.
8. **Deterministic Offline Replay:** All Wikipedia REST responses (including negative hits) are cached on local disk (`data/cache/wiki/{sha1}.json`) with a custom `User-Agent`.
9. **Zero-Key Degradation:** Extractive mode (verbatim Wikipedia excerpts) is the default; LLM features (rewrite & Ask) require user-configured BYOK API keys (Gemini, OpenAI, Groq, Ollama) and degrade gracefully with clear user messaging when unconfigured. Static model lists are strictly forbidden in favor of live endpoint discovery.
10. **Lossless Reader & Paper Aesthetic:** Source reading chunks are rendered in responsive cards with serif typography and optical font sizing. Context Cards use distinct, styled surfaces across all four appearances.
11. **Card Spacing & Scheduling [SUPERSEDED]:**
    - *Superseded by Dynamic Word-Distance Scheduling*: The early arbitrary 8-card hard cap has been superseded by a dynamic coverage model: 24 initial warm-start cards at ingestion, followed by `ReadAheadPipeline` lazy card generation (~4 cards per 1,000 eligible words, $\ge 3$ chunk gap, $\le 8$ per section) covering entire multi-hundred-page books without arbitrary whole-book cutoffs.
12. **3-Chunk Sliding Ask Window:** The `/api/ask` endpoint constructs a localized sliding context window containing `<passage>` and previous/next `<neighbors>` with a 12 req/min rate limit and standardized error envelopes. Delimiters are case-insensitively sanitized against prompt injection.
13. **Resilient Background Execution:** Background jobs run with streaming checkpoints, Android Foreground Service persistence (`IngestionForegroundService`), and atomic crash-recovery (`recoverStaleProcessingDocuments` marks interrupted jobs without losing committed chunks).
14. **11-Stage Structural Extraction & Verification Pipeline:** To overcome PDF heuristic extraction limits and font map corruption, extraction implements an 11-stage pipeline: (0) Page Triage; (1) Structured span capture; (2) Character repair in `RepairLedger`; (3) Multi-column reading order; (4) Relative block typing; (5) Paragraph reconstruction with compound-prefix preservation; (6) Canonical text assembly; (7) Quality grading; (8) Scored-boundary chunking; (9) 8-point cryptographic integrity; (10) Fallback ladder; (11) 6-digit deterministic chunk IDs.
15. **Adaptive Reading Feed Boundaries:** A deterministic profile of paragraph lengths and local continuation cues targets a steady short reading interval. Headings stay with their opening passage; oversized paragraphs split at guarded sentence boundaries. The planner chooses canonical offsets only and fails if coverage is not contiguous.
16. **Confidence-aware PDF Reading Order:** With a supported gutter, blocks are read top-to-bottom within each column, and full-width blocks separate vertical bands. Ambiguous geometric overlap is surfaced as `reading_order_uncertain`; readers can inspect the source page.
17. **Book Upload Bounds [SUPERSEDED]:**
    - *Superseded by Explicit Guardrails*: Uncapped uploads have been replaced by explicit, safe limits: 100MB max file size and 2,000 max page count to prevent unbounded server disk/RAM exhaustion while accommodating 99.9% of full-length literature. Both browser picker and backend upload stream in chunks with per-page progress.
