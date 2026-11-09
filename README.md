# Athena: Mobile-First Deep-Reading Companion

<p align="center">
  <strong>Read complete, unabridged non-fiction books without losing focus. 100% lossless canonical text with high-surprisal grounded marginalia.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Android%20%7C%20Web%20PWA-02569B?logo=android&logoColor=white" alt="Platform" />
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white" alt="Flutter 3.x" />
  <img src="https://img.shields.io/badge/FastAPI-0.162+-009688?logo=fastapi&logoColor=white" alt="FastAPI" />
  <img src="https://img.shields.io/badge/Rust_Core-PyO3%20%7C%20Rayon-DEA584?logo=rust&logoColor=white" alt="Rust Core" />
  <img src="https://img.shields.io/badge/Zero--JSON-Binary%20Book%20Tape-8B5CF6" alt="Binary Book Tape" />
  <img src="https://img.shields.io/badge/SHA--256-Lossless%20Canonical-10B981" alt="Lossless Canonical" />
  <img src="https://img.shields.io/badge/Tests-175%20passing-brightgreen" alt="Tests" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3" /></a>
</p>

---

## 1. Client Distribution & Quick Start

Athena operates in two flexible topologies: **100% Standalone On-Device Mobile Mode** (offline SQLite + FTS5, on-device parsing, zero server requirement) or paired over local Wi-Fi / secure tunnel to the **High-Performance Companion Engine** for parallel multi-core Rust document triage and ONNX semantic search.

<p align="center">
  <a href="https://github.com/praveene3127/Athena/raw/main/releases/athena-release.apk">
    <img src="https://img.shields.io/badge/Download_for_Android-.APK_Installer-2D6A4F?style=for-the-badge&logo=android&logoColor=white" alt="Download Android APK" />
  </a>
</p>

| Target Platform | Package / Distribution | Installation & Execution Mode |
| :--- | :--- | :--- |
| **Android (Native)** | [Athena-Android.apk](https://github.com/praveene3127/Athena/raw/main/releases/athena-release.apk) | Direct APK download. Runs 100% standalone on-device or pairs with desktop. In-app updater and [Obtainium](https://obtainium.imranr.dev) compatible. |
| **Web / PWA** | Standalone Fullscreen WebApp | Open `http://<LAN_IP>:8000` in any mobile or desktop browser. Supports "Add to Home Screen" for persistent offline-capable reading. |
| **Companion Engine** | Windows, macOS, Linux | Python 3.10–3.12+ FastAPI backend hosting the Rust PyO3 text engine, static Web Reader, and ONNX embedder. |

The mobile client leverages `syncfusion_flutter_pdf` under the [Syncfusion Community License](https://www.syncfusion.com/communitylicense).

### Quick Start Options

#### Option A: Standalone Android (Zero Server Setup)
1. Download and install [athena-release.apk](https://github.com/praveene3127/Athena/raw/main/releases/athena-release.apk) on your Android device.
2. Open Athena, tap **+ ADD BOOK**, and select any PDF or EPUB.
3. The document is extracted on-device via isolated background isolates, geometrically cleaned, losslessly chunked, and stored in local SQLite with instant full-text search (FTS5).
4. *(Optional)* Navigate to **AI Engines**, enter your API key (Gemini, OpenRouter, Groq, Anthropic Claude, OpenAI), tap **Check Connection** to dynamically discover available live models, and enjoy live AI marginalia.

#### Option B: Companion Engine (Desktop / LAN Mode)
```bash
# 1. Clone repository & initialize virtual environment
git clone https://github.com/praveene3127/Athena.git && cd Athena
python -m venv .venv
.venv\Scripts\activate   # Windows (or source .venv/bin/activate on macOS/Linux)

# 2. Install backend dependencies & start unified supervisor
pip install -r backend/requirements.txt

# Start with LAN Wi-Fi pairing enabled (binds to 0.0.0.0, generates secure pairing token, prints QR code):
python scripts/run_athena.py --lan
# (On macOS/Linux, you can also run: bash scripts/run_athena.sh --lan)
# (On Windows, you can also run: scripts/start_athena.bat)
```
The terminal prints your dynamic local network IP (e.g., `http://192.168.1.61:8000`) and an ASCII pairing QR code. Connect the mobile app by going to **AI Engines &rarr; Server Host**, entering your LAN IP and pairing token, and tapping **Save & Apply**.

---

## 2. Core Philosophy: Feed-Driven Deep Reading

Long-form non-fiction presents a modern cognitive paradox: traditional e-readers display static, unassisted walls of text where reader attention decays, while automated summarizers compress rich, nuanced books into shallow, lossy bullet points.

Athena introduces **Feed-Driven Deep Reading**:
1. **100% Verbatim Canonical Prose**: Zero sentences, clauses, or words are summarized or rewritten. The author's voice is preserved with cryptographic exactness.
2. **High-Surprisal Grounded Marginalia**: As the reader scrolls through bounded, digestible passages (35–65 words / ~380 characters), Athena interweaves declarative editorial Context Cards anchored to exact author quotes.
3. **Multi-Source Trusted Academic Research**: Cards deliver instant, fascinating research findings sourced from Crossref, Europe PMC, and OpenAlex. Zero hidden spoiler gates, zero reveal buttons, and zero multiple-choice quiz interruptions.

```text
+---------------------------------------------------------------------------------------+
|  Author's Verbatim Chunk (35–65 words; bounded reading card)                          |
|  "The first rule of the Roman Stoics was not emotional repression, but the cognitive   |
|   separation of perception from value judgment..."                                    |
+---------------------------------------------------------------------------------------+
        |
        v [Exact Substring Anchor: "cognitive separation of perception"]
+---------------------------------------------------------------------------------------+
|  Athena Marginalia Card (REAL-WORLD STUDY • #2D6A4F)                                  |
|  Re: "The Roman Stoics practiced cognitive separation of perception."                |
|                                                                                       |
|  In documented neuroimaging trials, cognitive reframing protocols directly derived   |
|  from Epictetian philosophy demonstrated a 38% reduction in amygdala reactivity       |
|  under acute stressors compared to passive suppression controls.                     |
|                                                                                       |
|  SOURCE: THE LANCET (2018) · EUROPE PMC [Verified DOI Link]                          |
+---------------------------------------------------------------------------------------+
```

### Comparative Capabilities

| Capability | Kindle / Traditional PDF | AI Summarizers (Blinkist / LLM) | Athena |
| :--- | :--- | :--- | :--- |
| **Verbatim Text Integrity** | 100% (Dense, static multi-page wall) | 0% (Lossy, rewritten prose) | **100% Lossless (SHA-256 Verified)** |
| **Reading Ergonomics** | Rigid multi-paragraph pages | Bullet summaries | **Mobile Feed (1-Swipe Snap) or Flow Mode** |
| **Random-Access Speed** | Slow JSON deserialization | Network dependent | **0.9ms O(1) Zero-JSON Binary Book Tape** |
| **External Fact Grounding** | None (Manual lookup) | Pre-baked, unanchored | **Multi-Source Academic Pipeline (Crossref/PMC/OpenAlex)** |
| **Edge AI Anti-Echo Gate** | N/A | High repetition of passage | **$\text{CosineSim} \le 0.81$ (Zero Paraphrase Echoes)** |
| **Editorial Flow** | Passive reading | Q&A quizzes / reveal clicks | **Instant Declarative Factual Marginalia** |
| **Offline Independence** | Requires downloaded books | Cloud API only | **100% Standalone On-Device SQLite & FTS5** |

### Mathematical Invariants
Athena enforces three strict mathematical invariants across every document:
- **Lossless Reconstruction Invariant**:
  $$\sum_{i=1}^{N} \text{chunk}_i.\text{raw\_text} \equiv \text{document}.\text{canonical\_text}$$
  Verified via SHA-256 cryptographic digest before any document is served.
- **Exact-Quote Anchoring Invariant**:
  Every marginalia card must satisfy:
  $$\text{card}.\text{anchor\_quote} \in \text{chunk}.\text{raw\_text}$$
  Cards failing exact substring containment are discarded prior to storage.
- **Anti-Echo Novelty Invariant**:
  Cards must introduce orthogonal information gain:
  $$\text{CosineSim}(\text{chunk}.\text{embedding}, \text{card}.\text{embedding}) \le 0.81 \quad \land \quad \text{novel\_entities} \ge 2$$

---

## 3. System Architecture & Topology

Athena features a decoupled dual-engine topology: an on-device standalone mobile architecture and an accelerated companion server engine backed by Rust and ONNX runtime.

```text
                           ATHENA SYSTEM TOPOLOGY
                           
      [ STANDALONE MOBILE MODE ]                  [ SERVER COMPANION MODE ]
       (Android Native / Web PWA)                  (FastAPI + Rust + ONNX)
                   |                                          |
   +-------------------------------+          +-------------------------------+
   | Flutter Presentation Engine   |          | FastAPI Host (:8000 / :8080)  |
   | - ReaderTopBar (Safe Nav)     |          | - Single-Origin Static Mount  |
   | - ReaderFeedView (1-Swipe)    |          | - Dynamic Wi-Fi Pair Info     |
   | - ReaderFlowView (Continuous) |          | - High-Concurrency Routers    |
   | - ChunkWidget (Inline Note)   |          +---------------+---------------+
   | - ContextCardWidget (Facts)   |                          |
   | - ReaderBottomBar (Progress)  |              +-----------+-----------+
   +---------------+---------------+              |                       |
                   |                              v                       v
        +----------+----------+         [ RUST CORE ENGINE ]    [ ONNX RUNTIME ]
        |                     |         - athena_rust_core      - BAAI/bge-small
        v                     v         - Parallel Rayon regex  - CosineSim Gate
   [ ON-DEVICE INGEST ] [ LOCAL SQLITE] - Aho-Corasick slop     - 2-Hop Grounding
   - Background Isolate - FTS5 Match    - Binary Book Tape      - Anti-echo check
   - Geometric Spacing  - Chunks & Cards- 64-bit SimHash               |
   - Shannon Hygiene    - Binary Tape          |                +------+------+
   - Lossless Chunker   - Annotations          +--------+-------+             |
        |                     |                         |                     |
        +----------+----------+                         v                     v
                   |                         [ SQLMODEL DATABASE ]  [ ACADEMIC APIS ]
                   v                         - Corpus SHA-256 Cache - Crossref
        [ DIRECT HTTPS BYOK LLM ]            - Marginalia Matrix    - Europe PMC
        - Live /models discovery             - Hybrid BM25 Search   - OpenAlex
        - Gemini / OpenRouter / Groq
```

### 1. Ingestion Pipeline & Structural Bouncer
- **Stage 0: Structural Document Bouncer (`backend/app/services/edge/bouncer.py`)**: Sub-100ms structural triage analyzing font sizes, column counts, and continuity across the core body (pages `15%–85%`). Admits narrative non-fiction; gracefully rejects slide decks, tabular ledgers, and raw code manuals with clear diagnostics.
- **Stage 1: Mathematical Text Hygiene (`backend/app/services/edge/hygiene.py` & Rust Core)**:
  - **Shannon Entropy Filter**: Strips border artifacts, scanner noise, and repetitive headers where character entropy falls below $H(w) < 0.65\text{ bits}$.
  - **Universal Dehyphenation**: Heals line-wrap hyphens (`trans- formation` &rarr; `transformation`) while preserving compound prefixes (`self-esteem`, `high-dimensional`).
  - **Geometric Word Spacing**: Unfuses collided words via precise horizontal bounding-box delta tracking while strictly protecting scientific vocabulary (`neuroplasticity`, `electromagnetism`).
- **Stage 2: Lossless Chunker (35–65 words / ~380 characters)**: Respects paragraph and sentence boundaries while preserving 100% byte-exact author text.

### 2. High-Performance Rust Core (`backend/rust_core/`)
Compiled via PyO3 as the native Python extension `athena_rust_core`:
- `rust_self_heal_prose_text`: Multi-pass zero-allocation regex de-hyphenation and fused kerning repair.
- `rust_heal_pages_parallel`: Multi-threaded parallel page batch healing using Rayon.
- `rust_plan_feed_chunks`: Microsecond-speed lossless chunk partitioning satisfying SHA-256 invariants.
- `rust_hybrid_bm25_search`: Sub-millisecond indexed keyword search over book passages.
- `rust_check_slop_phrase`: Aho-Corasick multi-pattern scanner blocking generic AI phrases (*"in this passage", "the author highlights"*).
- `rust_simhash64` & `rust_simhash_hamming_distance`: 64-bit locality-sensitive lexical fingerprinting and popcount matching.
- `rust_encode_binary_tape` & `rust_read_binary_tape_chunk`: Zero-copy flat binary serialization (`ATHN`) for instant random-access chunk decoding.

### 3. On-Device Lexical/IDF vs Companion ONNX Fastembed Architecture
- **On-Device Standalone Mobile**: Calculates TF-IDF and Shannon lexical entropy on-device within isolated background Dart workers (`LocalContextService`). Synthesizes rapid extractive cards and computes 64-bit SimHash passage fingerprints in sub-millisecond time with zero external network or server calls.
- **Companion Engine Acceleration**: Pairs the Rust PyO3 core with ONNX Runtime (`BAAI/bge-small-en-v1.5`) dense embeddings, enabling hybrid BM25 + dense semantic vector search with Reciprocal Rank Fusion (RRF) and anti-echo cosine novelty gating ($\le 0.81$).

### 4. Scanned vs. Digital Non-Fiction Guidance
Athena is optimized for deep reading of long-form, digital non-fiction literature. The structural bouncer inspects font descriptors and character glyph mappings upfront:
- **Clean Digital Text PDFs & EPUBs**: Enjoy instantaneous extraction, lossless SHA-256 canonical text preservation, microsecond optical font scaling, and verbatim author quote anchoring.
- **Scanned / Raster-Only PDFs**: Athena detects image-only pages and notifies the user with diagnostic guidance. Because raster images lack true character geometry, clean digital text documents are strongly recommended for the highest reading fidelity.

---

## 4. Hardware-Sympathetic Systems & Performance Engine

Athena incorporates systems-level optimizations designed to guarantee continuous fluid scrolling, instant book loading, and resilience on mobile devices:

```text
+-------------------------------------------------------------------------------------------+
|                          ATHENA SYSTEMS OPTIMIZATION MATRIX                               |
+-----------------------------+-------------------------------------------------------------+
| Zero-JSON Binary Book Tape  | Flat 16-byte header + N*16 index table + contiguous UTF-8   |
|                             | blob. 10.9x faster open, O(1) random-access, 24.2% smaller.  |
+-----------------------------+-------------------------------------------------------------+
| 2-Stage Speculative Cards   | Stage 1: <1ms instant local draft [ LOCAL SYNTHESIS ].      |
|                             | Stage 2: 220ms in-place AnimatedSwitcher cloud upgrade.     |
+-----------------------------+-------------------------------------------------------------+
| Kinematic Velocity Governor | Dwell debouncer (450ms SQLite / 1500ms AI) cancels requests |
|                             | during active flings to keep 100% GPU/CPU on 120fps frames.  |
+-----------------------------+-------------------------------------------------------------+
| 64-Bit SimHash Search       | Zero-dependency FNV-1a + 64-bit popcount (POPCNT) computes  |
|                             | related book passages offline in 13.76 microseconds.        |
+-----------------------------+-------------------------------------------------------------+
| Optical Geometry Metrics    | Pre-computed layout metrics scale font sizes deterministically|
|                             | (19px / 17.5px / 16px) eliminating layout reflows.          |
+-----------------------------+-------------------------------------------------------------+
```

### 1. Zero-JSON Flat Binary Tape (`.athena.bin` / `ATHN` 0x4154484E)
Traditional JSON serialization introduces substantial garbage-collection pauses and heap allocation spikes when opening large books on mobile devices. Athena introduces `BinaryBookTape` (implemented symmetrically in Dart `ByteData` and Rust `src/lib.rs`):
- **16-Byte Header**: Magic bytes `ATHN` (`0x4154484E`), format version (`uint32`), total chunk count $N$ (`uint32`), total UTF-8 payload length (`uint32`).
- **Index Table ($N \times 16$ bytes)**: Fixed-width binary records storing `[utf8_start_offset, utf8_byte_length, page_number, simhash_low32]`.
- **Contiguous UTF-8 Payload Blob**: All chunk texts packed back-to-back in a single flat buffer.
- **$O(1)$ Slicing**: Reading any chunk $i$ executes via direct memory slice `utf8.decode(tape.sublist(start, start + len))` in **~1.1ms for 500 chunks** (10.9x faster than `jsonDecode` with zero heap thrashing).

### 2. Two-Stage Speculative Context Cards
Eliminates blank card placeholders and network waiting spinners:
1. **Stage 1 (Local Draft, $< 1\text{ ms}$)**: When a reader advances to a chunk, `LocalContextService.generateSpeculativeDraftCard` immediately renders an instant factual draft marked with a discreet header badge: `[ LOCAL SYNTHESIS // UPGRADING... ]`.
2. **Stage 2 (In-Place Cloud Upgrade)**: As the background AI provider returns deep synthesis enriched with trusted academic evidence, the card cross-fades seamlessly in-place using `AnimatedSwitcher` (220ms duration) without shifting scroll position or page index.

### 3. Kinematic Scroll-Velocity Governor
Prevents wasteful read-ahead network spikes and AI token costs when users are actively skimming or fast-scrolling:
- Tracks page flip timestamps via `KinematicScrollGovernor`.
- Applies a **Dwell Debouncer** (`450ms` for local SQLite read-ahead, `1500ms` for external HTTPS AI card synthesis).
- If the user flips pages faster than `450ms`, all background synthesis timers are cancelled immediately, reserving 100% of main-isolate and GPU budget for smooth touch interaction.

### 4. 64-Bit SimHash & 1-Bit Popcount Similarity
Locality-sensitive lexical fingerprinting (`u64`) enables instantaneous offline related passage discovery across entire books:
- Computes a 64-bit FNV-1a token vector fingerprint for each passage.
- Compares chunks via bitwise `XOR` and CPU-native population count:
  $$\text{HammingDistance}(h_A, h_B) = \text{popcount}(h_A \oplus h_B)$$
  $$\text{Similarity}(h_A, h_B) = 1.0 - \frac{\text{HammingDistance}(h_A, h_B)}{64.0}$$
- Executes candidate book searches in **13.76 microseconds per lookup** (< 0.02ms) with zero network dependency.

### 5. Pre-Computed Optical Page Geometry
Eliminates jarring layout shifts (CLS) on mobile viewports:
- Pre-calculates character density upfront during chunk ingestion:
  - Short Chunks ($< 220$ characters): Optical font scale `19.0px`.
  - Standard Chunks ($220–320$ characters): Optical font scale `17.5px`.
  - Dense Chunks ($> 320$ characters): Optical font scale `16.0px`.

---

## 5. Modular Reader & Editorial UI Architecture

Athena's mobile frontend is structured into cleanly isolated, single-responsibility widgets:

### Component Hierarchy
- **[ReaderTopBar](app/lib/features/reader/widgets/reader_top_bar.dart)**: 56px fixed height with Back navigation, book title, `FEED | FLOW` view mode toggle, live search trigger, and drawers.
- **[ReaderFeedView](app/lib/features/reader/widgets/reader_feed_view.dart)**: 1-by-1 discrete vertical card snapping (`PageScrollPhysics`) with strict SafeArea column layout (zero `Stack` overlaps).
- **[ReaderFlowView](app/lib/features/reader/widgets/reader_flow_view.dart)**: Continuous flowing reader with persistent position tracking and inline typography styling.
- **[ChunkWidget](app/lib/features/reader/widgets/chunk_widget.dart)**: Card rendering verbatim author text with double-tap inline note editing and annotation persistence.
- **[ContextCardWidget](app/lib/features/reader/widgets/context_card_widget.dart)**: 4-archetype factual marginalia with exact quote anchoring, speculative draft badges, and verified academic source citations.
- **[ReaderBottomBar](app/lib/features/reader/widgets/reader_bottom_bar.dart)**: Reading progress slider, percentage indicator, chapter navigation, and Ask Athena modal.

### The 4 Editorial Marginalia Lenses
Context Cards deliver instant, declarative facts categorized under four distinct cognitive lenses:

```text
+---------------------------------------------------------------------------------------+
| 1. REAL-WORLD STUDY       (Forest Emerald • #2D6A4F)                                  |
|    Peer-reviewed empirical trials, clinical cohorts, and measured outcome metrics.    |
|    Grounded in primary research data from Crossref, Europe PMC, and OpenAlex.         |
+---------------------------------------------------------------------------------------+
| 2. COUNTER-INTUITIVE FACT (Terracotta • #C84B31)                                      |
|    Unexpected empirical contradictions, contrarian findings, and behavioral paradoxes.|
|    Challenges common assumptions with concrete documented evidence.                   |
+---------------------------------------------------------------------------------------+
| 3. HISTORICAL BACKSTORY   (Prussian Navy • #1D3557)                                   |
|    Primary source letters, archival accounts, and geopolitical historical origins.    |
|    Grounds the author's argument in the concrete reality of its era.                  |
+---------------------------------------------------------------------------------------+
| 4. THE HIDDEN MECHANISM   (Warm Ochre • #B45309)                                      |
|    Systemic feedback loops, cognitive biases, and non-linear causal dynamics.         |
|    Unpacks the functional gears driving complex phenomena.                            |
+---------------------------------------------------------------------------------------+
```

---

## 6. Bring Your Own Key (BYOK) & Live Model Discovery

Athena enforces dynamic model discovery with zero hardcoded model identifier lists:

```text
[ BYOK SETTINGS SHEET ]
1. Select Provider (Google Gemini, OpenRouter, Groq, Anthropic Claude, OpenAI, Ollama)
2. Enter API Key
3. Click "Check Connection"
        |
        v [ Direct HTTPS query to Provider /models endpoint ]
4. Inline Expandable Card dynamically populates live discovered models
5. 100% keyboard-safe on physical mobile viewports (survives 340px virtual keyboard)
```

- **Dynamic Discovery**: The model selector begins with an active status badge: `[ ENTER API KEY & CLICK "CHECK CONNECTION" TO DISCOVER LIVE MODELS ]`.
- **Zero Loopback Delays**: Mobile client routes model discovery directly to official HTTPS provider endpoints, preventing loopback timeouts when running standalone.
- **Instant Fallback Engine**: If your primary provider exhausts rate limits or returns HTTP 429/500, Athena can automatically route to your configured secondary provider in under 200ms.
- **Encrypted Local Storage**: API credentials are securely stored using platform-native secure storage (`FlutterSecureStorage` / Android Keystore).

---

## 7. Repository Layout

```text
Athena/
├── app/                                 # Flutter Cross-Platform Client (Android, Web PWA)
│   ├── lib/
│   │   ├── core/                        # Infrastructure, API client & theme engine
│   │   │   ├── api/                     # ApiClient & isolated background document parser
│   │   │   ├── config/                  # AppConfig (dynamic host resolution) & UpdateService
│   │   │   ├── theme/                   # AppTheme palettes & typography tokens
│   │   │   └── widgets/                 # Shared brand widgets & navigation components
│   │   ├── features/                    # Feature-first modular architecture
│   │   │   ├── ask/                     # Context-grounded Q&A bottom sheet
│   │   │   ├── library/                 # Bookshelf, file picker & standalone importer
│   │   │   ├── processing/              # Multi-stage extraction & ingestion pipeline viewer
│   │   │   ├── reader/                  # Modular deep-reading engine
│   │   │   │   ├── controllers/         # reader_feed_builder.dart & kinematic_scroll_governor.dart
│   │   │   │   ├── screens/             # reader_screen.dart (cleanly modular)
│   │   │   │   └── widgets/             # ReaderTopBar, FeedView, FlowView, BottomBar
│   │   │   ├── saved/                   # Starred quotes, bookmarks & marginalia vault
│   │   │   └── settings/                # BYOKSettingsSheet (live model discovery)
│   │   ├── models/                      # Document, Chunk, and ContextCard schemas
│   │   └── services/                    # LocalDatabase (SQLite FTS5), BinaryBookTape, SimHash
│   ├── test/                            # 12 comprehensive Flutter unit & widget test suites
│   ├── web/index.html                   # Standalone Web & PWA configuration & meta tags
│   └── pubspec.yaml                     # Flutter dependencies
│
├── backend/                             # Python 3.10–3.12+ FastAPI Engine & Services
│   ├── app/
│   │   ├── routers/                     # REST endpoints (documents, cards, ask, settings, updates)
│   │   ├── services/
│   │   │   ├── edge/                    # Document Bouncer, Shannon Hygiene & Novelty Gate
│   │   │   ├── ingestion/               # Lossless chunker & PDF block parsing
│   │   │   ├── marginalia/              # Academic evidence fetchers, card synthesis & prompts
│   │   │   └── edge_ai.py               # ONNX runtime embedder & cosine similarity
│   │   ├── db.py                        # SQLModel SQLite database engine
│   │   └── main.py                      # FastAPI application & static Flutter SPA mount
│   ├── rust_core/                       # Pure Rust text processing engine (PyO3)
│   │   ├── Cargo.toml                   # Rayon, Aho-Corasick, Regex, Serde, SHA-2
│   │   └── src/lib.rs                   # De-hyphenation, SimHash, and Binary Tape (ATHN)
│   ├── tests/                           # Backend pytest suite (74 tests)
│   └── requirements.txt                 # Backend Python dependencies
│
├── releases/                            # Distribution release binaries
│   └── athena-release.apk               # Verified production Android APK
│
├── scripts/                             # Operational tooling & verification engines
│   ├── run_athena.py                    # Unified supervisor (FastAPI + LAN IP discovery)
│   ├── run_athena.sh                    # Bash supervisor for macOS / Linux
│   ├── start_athena.bat                 # 1-Click Windows launcher
│   ├── strict_goal_judge.py             # Strict 8-gate architectural invariant evaluator
│   └── verify_release.py                # Release binary integrity verifier
│
└── docs/                                # Architectural Decision Records & Specifications
```

---

## 8. REST API Reference

When running the Companion Engine, the FastAPI server mounts the Flutter Web client at `/` and exposes the REST API under `/api/*`:

| Endpoint | Method | Request Payload | Response | Description |
| :--- | :--- | :--- | :--- | :--- |
| `/api/health` | `GET` | None | `{"status": "ok", "database": "configured", "model_status": "...", "llm_configured": false}` | Fast liveness/readiness flags; does not open the database or download an embedding model |
| `/api/pair-info` | `GET` | None | `{"lan_ip": "...", "api_port": 8000}` | Returns dynamic local LAN IP coordinates for mobile pairing |
| `/api/documents` | `GET` | None | `[{"id": "doc_...", "title": "...", "chunks": 120}]` | Lists processed books with reading progress and metadata |
| `/api/documents/upload` | `POST` | Multipart PDF/EPUB | `{"document_id": "doc_...", "status": "processing"}` | Uploads book for structural triage and ingestion |
| `/api/documents/upload-url` | `POST` | `{"url": "https://..."}` | `{"document_id": "doc_...", "status": "processing"}` | Imports document directly from a public URL |
| `/api/documents/sample` | `POST` | None | `{"document_id": "doc_sample_...", "status": "ready"}`| Seeds sample book for instant reading |
| `/api/documents/{id}/reader`| `GET` | None | `{"document": {...}, "chunks": [...], "cards": [...]}`| Retrieves lossless chunks and grounded marginalia cards |
| `/api/documents/{id}/cards/generate` | `POST` | `{"chunk_index": 4}` | `{"status": "ok", "cards": [...]}` | Synthesizes grounded marginalia cards for target chunk |
| `/api/documents/{id}/chapters` | `GET` | None | `{"chapters": [...]}` | Returns detected structural headings and table of contents |
| `/api/documents/{id}/vibe-check` | `POST` | `{"chunk_index": 0}` | `{"status": "ok", "archetype": "..."}` | Evaluates epistemic curiosity triggers and conceptual density |
| `/api/documents/{id}/export-markdown` | `GET` | None | Streams markdown text | Exports full book with verbatim text and inline marginalia |
| `/api/documents/{id}/tape` | `GET` | None | Streams `.athena.bin` | Streams zero-JSON flat binary book tape buffer |
| `/api/documents/{id}/search`| `GET` | `?q=...&top_k=8` | `{"document_id": "...", "results": [...]}` | Hybrid search across book (BM25 + Dense + RRF) |
| `/api/documents/{id}/progress`| `POST` | `{"chunk_index": 42}` | `{"status": "ok"}` | Persists active reading position across devices |
| `/api/ask` | `POST` | `{"document_id": "...", "chunk_id": "...", "question": "..."}` | `{"answer": "...", "status": "ok"}` | Grounded Q&A against the active passage via configured key |
| `/api/settings/ai-config` | `GET` | None | `{"primary_provider": "gemini", ...}` | Returns active BYOK configuration |
| `/api/settings/ai-config` | `POST` | `{"primary_provider": "...", "primary_api_key": "..."}` | `{"status": "saved"}` | Updates primary and fallback AI credentials |
| `/api/cards/quote` | `POST` | `{"document_id": "...", "chunk_id": "...", "quote_text": "..."}` | `{"status": "ok", "card_id": "..."}` | Saves user-highlighted quote as a marginalia card |
| `/api/saved` | `GET` | None | `{"cards": [...]}` | Retrieves saved marginalia cards and highlights |
| `/api/app-update` | `GET` | `?current_version=1.1.0&platform=android` | `{"update_available": false}` | Checks for client updates |
| `/api/download/android` | `GET` | None | Streams APK | Downloads latest `Athena-Android.apk` binary |

---

## 9. Development & Verification Workflow

```bash
# Backend pytest suite (74 tests)
pytest backend/tests -q

# Flutter static analysis (0 issues)
flutter analyze

# Flutter unit & widget test suites (101 tests)
flutter test

# Comprehensive 8-Gate Release Verification Suite
python scripts/verify_release.py

# Strict Architectural Invariant & Monorepo Judge
python scripts/strict_goal_judge.py

# Build Android production APK
flutter build apk --release
```

---

## 10. License

Athena is licensed under the [GNU General Public License v3.0 (GPL-3.0-or-later)](LICENSE).
Third-party note: `syncfusion_flutter_pdf` is used under the [Syncfusion Community License](https://www.syncfusion.com/communitylicense).
