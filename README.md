# Athena: Mobile-First AI Deep-Reading Companion

<p align="center">
  <strong>Read complete, unabridged non-fiction books without losing focus. 100% lossless canonical text with high-surprisal grounded marginalia.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white" alt="Flutter 3.x" />
  <img src="https://img.shields.io/badge/FastAPI-0.115+-009688?logo=fastapi&logoColor=white" alt="FastAPI" />
  <img src="https://img.shields.io/badge/ONNX-Edge%20AI-005CED?logo=onnx&logoColor=white" alt="ONNX Edge AI" />
  <img src="https://img.shields.io/badge/SHA--256-Lossless%20Canonical-10B981" alt="Lossless Canonical" />
  <img src="https://img.shields.io/badge/Tests-53%2F53%20Passing-brightgreen" alt="Tests" />
  <a href="docs/LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="License" /></a>
</p>

---

## 1. Client Downloads & Quick Start

Athena operates as a native mobile client paired over local Wi-Fi or Cloudflare Tunnel to your local companion engine, ensuring complete data privacy with zero cloud lock-in.

<p align="center">
  <a href="https://github.com/praveene3127/Athena/raw/main/releases/athena-release.apk">
    <img src="https://img.shields.io/badge/Download_for_Android-.APK_Installer-2D6A4F?style=for-the-badge&logo=android&logoColor=white" alt="Download Android APK" />
  </a>
  &nbsp;&nbsp;
  <a href="https://github.com/praveene3127/Athena/raw/main/releases/athena-ios-release.ipa">
    <img src="https://img.shields.io/badge/Download_for_iOS-.IPA_Package-161615?style=for-the-badge&logo=apple&logoColor=white" alt="Download iOS IPA" />
  </a>
</p>

| Target Platform | Package / Distribution | Installation & Pairing Method |
| :--- | :--- | :--- |
| **Android** | [Athena-Android.apk](https://github.com/praveene3127/Athena/raw/main/releases/athena-release.apk) | Direct APK download. Background updates supported via [Obtainium](https://obtainium.imranr.dev) or in-app updater. |
| **iOS (Native IPA)** | [Athena-iOS.ipa](https://github.com/praveene3127/Athena/raw/main/releases/athena-ios-release.ipa) | Sideload via [Sideloadly](https://sideloadly.io/) or AltStore with any free Apple ID (no paid developer account required). |
| **iOS (PWA / WebApp)** | Standalone Fullscreen WebApp | Open `http://<LAN_IP>:8000` in Safari &rarr; Tap **Share** &rarr; **Add to Home Screen**. |
| **Companion Engine** | Windows, macOS, Linux | Python 3.12+ backend hosting FastAPI REST API, static Web Reader, and ONNX embedder. |

### Companion Engine Launch
```bash
# 1. Clone & activate virtual environment
git clone https://github.com/praveene3127/Athena.git && cd Athena
python -m venv .venv
.venv\Scripts\activate   # Windows (or source .venv/bin/activate on macOS/Linux)

# 2. Install dependencies & start unified supervisor
pip install -r backend/requirements.txt
python scripts/run_athena.py
# (On Windows, you can also double-click scripts/start_athena.bat)
```

---

## 2. Core Philosophy: Feed-Driven Deep Reading

Long-form non-fiction presents a structural cognitive dilemma: traditional e-readers display static, unassisted walls of text that make sustaining focus on dense arguments difficult, while automated summarization tools compress nuanced prose into lossy, hallucination-prone bullet points.

Athena resolves this through **Feed-Driven Deep Reading**:
1. **100% Verbatim Canonical Prose**: Not a single word, clause, or sentence is summarized, condensed, or rewritten.
2. **High-Surprisal Grounded Marginalia**: As the reader scrolls through digestible chunks (80–140 words), an Edge AI scanner and dual-engine LLM generate grounded pedagogical context cards anchored to exact quotes.

```
+---------------------------------------------------------------------------------------+
|  Author's Verbatim Chunk (80–140 words)                                               |
|  "The first rule of the Roman Stoics was not emotional repression, but the cognitive   |
|   separation of perception from value judgment..."                                    |
+---------------------------------------------------------------------------------------+
        |
        v [Exact Substring Anchor: "cognitive separation of perception"]
+---------------------------------------------------------------------------------------+
|  Athena Marginalia Card (EMPIRICAL STUDY • #2D6A4F)                                    |
|  Quote: "cognitive separation of perception from value judgment"                      |
|  Context: Albert Ellis modeled Rational Emotive Behavior Therapy (REBT) directly on   |
|  Epictetus' Enchiridion. In a 2018 randomized trial (N=142), cognitive reappraisal    |
|  reduced amygdala activation by 38% compared to passive suppression.                  |
|  [ ||REVEAL||: Tap to inspect neuroimaging replication and sample limitations ]       |
+---------------------------------------------------------------------------------------+
```

### Comparative Capabilities

| Capability | Kindle / PDF Readers | AI Summarizers (Blinkist / LLM) | Athena |
| :--- | :--- | :--- | :--- |
| **Verbatim Text Integrity** | 100% (Static page layout) | 0% (Lossy, rewritten prose) | **100% Lossless (SHA-256 Verified)** |
| **Reading Ergonomics** | Rigid multi-paragraph pages | Bullet summaries | **Mobile Feed or Flow with Dynamic Chunks** |
| **External Fact Grounding** | None (Manual lookup) | Pre-baked, unanchored | **2-Hop Orthogonal Search to Academic Sources** |
| **Edge AI Anti-Echo Gate** | N/A | High repetition of passage | **$\text{CosineSim} \le 0.81$ (Zero Paraphrase Echoes)** |
| **Active Recall Integration**| Passive reading | Generic multiple-choice | **Interactive Study Findings Spoilers** |

### Mathematical Invariants
Athena enforces two strict invariants verified on every build:
- **Lossless Reconstruction**:
  $$\sum_{i=1}^{N} \text{chunk}_i.\text{raw\_text} \equiv \text{document}.\text{canonical\_text}$$
  Verified via SHA-256 cryptographic digest before any document is served.
- **Exact-Quote Anchoring**:
  Every marginalia card must satisfy:
  $$\text{card}.\text{anchor\_quote} \in \text{chunk}.\text{raw\_text}$$
  Cards failing exact substring containment are discarded prior to storage.

---

## 3. System Architecture & Edge AI Pipeline

Athena combines an on-device ONNX embedding engine (`BAAI/bge-small-en-v1.5`) with pluggable cloud LLM orchestration (Google Gemini default, OpenRouter, Groq, Anthropic Claude, OpenAI, or local Ollama with instant failover).

```
                             ATHENA SYSTEM ARCHITECTURE

  [ Native Mobile App ]               [ Web Reader ]
  (iOS .ipa / Android .apk)         (Mobile Safari PWA)
             |                               |
             +---------------+---------------+
                             |
                   HTTP / WebSocket (CORS-free)
                             |
                             v
  +-----------------------------------------------------+
  |      FastAPI Unified Host (:8000 / :8080)           |
  |  - Single-Origin Static Mount (HTML5 SPA)           |
  |  - Dynamic Wi-Fi & LAN Pair Info (/api/pair-info)   |
  |  - BYOK Dual Failover Router                        |
  +-----------------------------------------------------+
                             |
         +-------------------+-------------------+
         |                                       |
         v                                       v
  [ INGESTION PIPELINE ]                 [ READ-AHEAD PIPELINE ]
  Stage 0: Document Bouncer              Stage 2A: 2-Hop Search
  - Core Body Window (15%-85%)           - Academic & Historical Indices
  - Per-Page Structural Dominance        - PubMed, Stanford, PNAS
  - Book Immunity Rule (<100ms)                          |
         |                                               v
         v                               Stage 2B: ONNX Anti-Echo Gate
  Stage 1: Mathematical Hygiene          - BAAI/bge-small-en-v1.5 (CPU)
  - Shannon Entropy Filter (H < 0.65)    - CosineSim(chunk, card) <= 0.81
  - Universal Dehyphenation              - >= 2 Novel External Entities
  - Viterbi De-Compounding (wordninja)   - Disambiguation Filter
  - Modal Font Footnote Isolation                        |
         |                                               v
         v                               [ SQLModel SQLite DB ]
  Lossless Chunker (80-140 words)        - Chunks & Grounded Cards
  - SHA-256 Invariant Verification       - Reading Progress & Vibe Cache
```

### Stage 0: Structural Document Bouncer (`backend/app/services/edge/bouncer.py`)
PDFs uploaded to Athena are evaluated through a sub-100ms structural triage gate prior to compute-heavy OCR or embedding:
- **Per-Page Structural Dominance**: Measures font distribution, column counts, and paragraph continuity across the core body (pages `15%–85%`). Never relies on brittle keyword bans.
- **Book Immunity Rule**: Documents demonstrating book-length page continuity (>25 pages of narrative text flow) receive unconditional ingestion immunity.
- **Triage Classification**: Slide decks, invoices, forms, and raw code listings are bounced with a diagnostic reason and an optional manual override.

### Stage 1: Information-Theoretic PDF Hygiene (`backend/app/services/edge/hygiene.py`)
Raw PDF extraction often produces typographical artifacts that destroy readability. Athena cleans text using information theory principles:
- **Shannon Entropy Filter (DeepMind *Gopher* / AllenAI *Dolma*)**: Strips printer border noise and decorative dividers where word entropy falls below:
  $$H(w) = -\sum_{i=1}^{k} p(c_i) \log_2 p(c_i) < 0.65\text{ bits}$$
- **Universal Dehyphenation**: Repairs line-break splits (`An- toninus` &rarr; `Antoninus`) while preserving valid compound words (`self-esteem`, `eighteenth-century`).
- **Viterbi Unigram De-Compounding (`wordninja`)**: Corrects kerning collisions (`amusementlastsummer` &rarr; `amusement last summer`) while protecting technical vocabulary (`neuroplasticity`, `electromagnetism`).
- **Modal Font Footnote Isolation**: Isolates smaller text blocks at page boundaries so sentences never break across page turns. Fused superscript callouts are cleanly sanitized.

### Stage 2: Read-Ahead Scanner & Novelty Gate (`backend/app/services/edge/novelty.py`)
While reading chunk $K$, Athena asynchronously prepares grounded marginalia for chunks $K+1 \dots K+5$:
- **2-Hop Orthogonal Grounding**: Retrieves external context from academic databases (PubMed, APA PsycNet, Stanford Encyclopedia of Philosophy).
- **ONNX Anti-Echo Gate (`BAAI/bge-small-en-v1.5`)**:
  1. **$\text{CosineSim}(\text{chunk}, \text{card}) \le 0.81$**: Discards cards that merely summarize or restate the passage.
  2. **Entity Expansion**: Enforces $\ge 2$ novel named entities (dates, sample sizes, researcher names, historical events) not present in the source chunk.
  3. **Disambiguation Filter**: Strips pop-culture Wikipedia disambiguation stubs.

---

## 4. Interactive Marginalia Archetypes & Cognitive Tools

Cards cycle deterministically through four distinct cognitive lenses (`slot = card_index % 4`):

```
+---------------------------------------------------------------------------------------+
| 1. EMPIRICAL STUDY     (Forest Emerald • #2D6A4F)                                     |
|    Peer-reviewed studies, randomized trials, statistical cohorts, and sample sizes.   |
|    Interactive: Tap [ Reveal Study Findings ] to inspect experimental results.        |
+---------------------------------------------------------------------------------------+
| 2. CRITICAL DEBATE     (Terracotta • #C84B31)                                         |
|    Major counterarguments, theoretical dissent, and empirical contradictions.         |
|    Dual-panel: Structured [ Counterpoint ] vs. [ Empirical Evidence ].                |
+---------------------------------------------------------------------------------------+
| 3. HISTORICAL CONTEXT  (Prussian Navy • #1D3557)                                      |
|    Primary source letters, archival records, and geopolitical background.             |
|    Anchors author arguments in the tangible world of their era.                       |
+---------------------------------------------------------------------------------------+
| 4. CORE PARADOX        (Warm Ochre • #B45309)                                         |
|    Counter-intuitive laws, cognitive blindspots, and systemic contradictions.        |
|    Named laws (e.g., Goodhart's Law, Jevons Paradox, Selection Bias).                 |
+---------------------------------------------------------------------------------------+
```

### Cognitive Reading Tools
- **Feed Mode vs. Flow Mode**: Toggle between vertical snap-scrolling (one chunk + card per viewport) and continuous reading flow.
- **Passage Simplifier**: Pausing on a complex passage for over 45 seconds surfaces a subtle icon offering a 1-tap plain-English conceptual breakdown.
- **Bionic Focus Mode (`Aa`)**: Bolds initial fixation letters to accelerate visual parsing and reduce cognitive fatigue.
- **Ask Athena Modal**: Context-grounded Q&A anchored to the active passage with keyboard-aware scrolling.
- **Markdown Vault Export**: 1-click export of book marginalia formatted for Obsidian, Logseq, and Notion.

### Bring Your Own Key (BYOK) & Dual Failover Engine
- **Default Engine**: Google Gemini (`gemini-2.5-flash`), pre-configured for high-speed, cost-effective inference.
- **Supported Providers**: Google Gemini, OpenRouter, Groq, Anthropic Claude, OpenAI, and local Ollama.
- **Automatic Fallback Circuit**: Rate limits (HTTP 429), quota exhaustion, or server errors (HTTP 500/503) automatically trigger fallback to your secondary provider in under 200ms without reading interruption.
- **Local Key Encryption**: API keys are encrypted at rest with local machine keys and never logged.

---

## 5. Editorial Design System

Athena adopts a typography-first aesthetic inspired by high-end book design (Stripe Press & Edward Tufte):

| Element | Dark Mode Palette | Light Mode Palette | Design Purpose |
| :--- | :--- | :--- | :--- |
| **Canvas Background** | `#121212` (Deep Charcoal) | `#FAF9F6` (Alabaster Cream) | Minimizes fatigue during extended reading sessions |
| **Prose Ink** | `#E5E5E5` (Warm Bone) | `#1A1A1A` (Carbon Ink) | High legibility without harsh pure-white glare |
| **Card Surface** | `#181818` (Obsidian) | `#FFFFFF` (Crisp Paper) | Tactile elevated card surfaces |
| **Border / Hairline** | `#262626` | `#E5E5E0` | Subtle structural division |
| **Card Accent Spines** | Emerald / Terracotta / Navy / Ochre | High-contrast pedagogical color coding |

### Typography Hierarchy
- **Literary Prose**: *Newsreader* (Variable serif, 18.5px mobile optical size, line-height 1.65, tracking 0.2px). Fits 60–70 characters per line comfortably on 390px mobile screens.
- **Editorial Display**: *DM Serif Display* (Transitional display serif for titles, mastheads, and dropcaps).
- **Marginalia & UI**: *Geist* (Geometric sans-serif, optimized for 11–13px mobile legibility).
- **Metadata & Coordinates**: *JetBrains Mono* / Monospace (Tabular figures, SHA-256 digests, and archival anchors).

---

## 6. Monorepo Directory Layout

```text
Athena/
├── app/                                 # Flutter Cross-Platform Client (iOS, Android, Web)
│   ├── lib/
│   │   ├── core/                        # Infrastructure, API client & theme engine
│   │   │   ├── api/                     # ApiClient with automatic origin host resolution
│   │   │   ├── config/                  # AppConfig (pure host resolver & preferences)
│   │   │   ├── theme/                   # AppTheme palette & typography tokens
│   │   │   └── widgets/                 # Shared widgets & editorial components
│   │   ├── features/                    # Feature-first clean architecture
│   │   │   ├── ask/                     # Context-grounded Q&A bottom sheet
│   │   │   ├── library/                 # Bookshelf, upload progress, and document list
│   │   │   ├── processing/              # Multi-stage extraction & ingestion pipeline viewer
│   │   │   ├── reader/                  # Feed/Flow reader, ChunkWidget & ContextCardWidget
│   │   │   ├── saved/                   # Saved marginalia, insights, and starred quotes
│   │   │   └── settings/                # BYOKSettingsSheet (Primary, Failover, Server Host)
│   │   └── main.dart                    # Application entrypoint & route management
│   ├── web/index.html                   # Fullscreen iOS PWA configuration & meta tags
│   └── pubspec.yaml                     # Flutter dependencies
│
├── backend/                             # Python 3.12+ FastAPI & ONNX Engine
│   ├── app/
│   │   ├── routers/                     # REST endpoints (documents, cards, ask, settings, updates)
│   │   ├── services/
│   │   │   ├── edge/                    # Document Bouncer, Shannon Hygiene & Novelty Gate
│   │   │   ├── ingestion/               # Lossless chunker & PDF block parsing
│   │   │   ├── marginalia/              # Card synthesis, prompt templates & Wikipedia
│   │   │   └── edge_ai.py               # ONNX runtime embedder & cosine similarity
│   │   ├── db.py                        # SQLModel SQLite database engine
│   │   └── main.py                      # FastAPI application & static Flutter SPA mount
│   ├── tests/                           # 53 automated pytest suites
│   └── requirements.txt                 # Backend dependencies
│
├── scripts/                             # Operator tooling & verification
│   ├── run_athena.py                    # Unified supervisor (FastAPI + Forwarder + Wi-Fi discovery)
│   ├── start_athena.bat                 # 1-Click Windows desktop launcher
│   ├── strict_goal_judge.py             # 8-Gate adversarial verification suite
│   ├── verify_release.py                # Release integrity verifier
│   └── package_ios_ipa.py               # iOS IPA packaging tool
│
├── docs/                                # Architecture Decision Records (ADRs)
└── .github/workflows/
    └── mobile_release.yml               # Automated Android APK & iOS IPA Cloud Release
```

---

## 7. REST API Reference & Verification Suite

### REST Endpoints

| Endpoint | Method | Request Payload | Response | Description |
| :--- | :--- | :--- | :--- | :--- |
| `/api/health` | `GET` | None | `{"status": "ok", "database": "reachable", ...}` | Verifies database connectivity, ONNX runtime, and AI provider status |
| `/api/pair-info` | `GET` | None | `{"lan_ip": "...", "api_port": 8000, ...}` | Returns dynamic local IP and pairing coordinates |
| `/api/documents` | `GET` | None | `[{"id": "doc_...", "title": "...", "chunks": 120}]` | Lists processed books with reading progress and metadata |
| `/api/documents/upload` | `POST` | Multipart PDF/EPUB | `{"id": "doc_...", "status": "processing"}` | Uploads book for structural triage and ingestion |
| `/api/documents/upload-url` | `POST` | `{"url": "https://..."}` | `{"id": "doc_...", "status": "processing"}` | Imports document directly from a public URL |
| `/api/documents/sample` | `POST` | None | `{"id": "doc_sample_...", "status": "ready"}` | Generates starter sample book for instant reading |
| `/api/documents/{id}/reader` | `GET` | None | `{"document": {...}, "chunks": [...], "cards": [...]}` | Retrieves lossless chunks and grounded marginalia cards |
| `/api/documents/{id}/search` | `GET` | `?q=...&top_k=8` | `{"document_id": "...", "results": [...]}` | In-book hybrid search (BM25 + Dense + RRF) |
| `/api/documents/{id}/progress` | `POST` | `{"chunk_index": 42}` | `{"status": "ok"}` | Persists active reading position and bookmark across devices |
| `/api/documents/{id}/force-ingest` | `POST` | None | `{"status": "queued"}` | Ingestion override bypassing document bouncer triage |
| `/api/documents/{id}/vibe-check` | `POST` | `{"chunk_index": 5}` | `{"simplified": "..."}` | Real-time passage simplification breakdown |
| `/api/ask` | `POST` | `{"document_id": "...", "chunk_id": "...", "question": "..."}` | `{"answer": "...", "status": "ok"}` | Grounded Q&A against current passage via configured AI key |
| `/api/settings/ai-config` | `GET` | None | `{"primary_provider": "gemini", ...}` | Returns active BYOK provider configuration |
| `/api/settings/ai-config` | `POST` | `{"primary_provider": "...", "primary_api_key": "..."}` | `{"status": "saved"}` | Updates primary and fallback AI provider credentials |
| `/api/cards/quote` | `POST` | `{"document_id": "...", "chunk_id": "...", "quote_text": "..."}` | `{"status": "ok", "card_id": "..."}` | Saves user-highlighted quote as a marginalia card |
| `/api/saved` | `GET` | None | `{"cards": [...]}` | Retrieves saved marginalia cards and highlights |
| `/api/app-update` | `GET` | `?current_version=1.1.0&platform=android` | `{"update_available": false, ...}` | Checks for client application updates |
| `/api/download/android` | `GET` | None | Streams APK | Downloads latest Athena-Android.apk binary |
| `/api/download/ios` | `GET` | None | Streams IPA | Downloads latest Athena-iOS.ipa binary |

### Wireless Mobile Pairing
1. Start the companion engine via `python scripts/run_athena.py` (or `scripts/start_athena.bat`).
2. The terminal displays your local LAN IP (e.g., `http://192.168.1.61:8000`).
3. In the mobile client, tap **Settings** &rarr; **Server Host**, enter the LAN URL, and tap **Save & Apply**.

### 8-Gate Adversarial Verification Suite
Athena enforces an un-gameable 8-gate verification engine ensuring code hygiene, mathematical integrity, and production readiness:

```bash
# Run full 8-gate adversarial goal judge
python scripts/strict_goal_judge.py

# Run backend unit tests (53 tests)
pytest backend/tests -q

# Run Flutter static analysis & test suite
cd app && flutter analyze lib && flutter test
```

```text
==============================================================================
 GATE 1: MONOREPO STRUCTURE & ROOT CLEANLINESS AUDIT          -> [PASS]
 GATE 2: ADVERSARIAL REAL-PDF HOLDOUT BOUNCER TEST            -> [PASS]
 GATE 3: SELF-HEALING HYGIENE & VOCABULARY PRESERVATION       -> [PASS]
 GATE 4: LOSSLESS SHA-256 INVARIANT ON CORPUS CHUNKING        -> [PASS]
 GATE 5: MARGINALIA 4-ARCHETYPE ROTATION & ANTI-ECHO NOVELTY  -> [PASS]
 GATE 6: BACKEND PYTEST SUITE (53/53 PASSED)                  -> [PASS]
 GATE 7: FLUTTER ANALYSIS & NATIVE MOBILE READINESS (0 ISSUES) -> [PASS]
 GATE 8: REAL MOBILE VIEWPORT & LAN IP SINGLE-ORIGIN E2E TEST -> [PASS]
==============================================================================
  >>> ALL 8 GATES PASSED! ATHENA IS 100% PRODUCTION READY <<<
==============================================================================
```

---

## 8. Development & Contribution

Pull requests must comply with all 8 adversarial gates and maintain 100% lossless canonical text integrity.

```bash
# Frontend development
cd app
flutter pub get
flutter run -d chrome

# Backend development
cd backend
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
```

---

<p align="center">
  <sub>Built with intellectual rigor for deep reading. Distributed under the [MIT License](docs/LICENSE).</sub>
</p>
