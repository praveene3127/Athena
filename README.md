# Athena: Mobile-First AI Deep-Reading Companion

<p align="center">
  <strong>Read complete, unabridged non-fiction books without losing focus. 100% lossless canonical text with high-surprisal grounded marginalia.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white" alt="Flutter 3.x" />
  <img src="https://img.shields.io/badge/FastAPI-0.115+-009688?logo=fastapi&logoColor=white" alt="FastAPI" />
  <img src="https://img.shields.io/badge/ONNX-Edge%20AI-005CED?logo=onnx&logoColor=white" alt="ONNX Edge AI" />
  <img src="https://img.shields.io/badge/SHA--256-Lossless%20Canonical-10B981" alt="Lossless Canonical" />
  <img src="https://img.shields.io/badge/Tests-49%2F49%20Passing-brightgreen" alt="Tests" />
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="License" />
</p>

---

## 1. The 3-Platform One-Click Install Hub

Athena runs as a native application on **iOS** and **Android**, pairing wirelessly over Wi-Fi or Cloudflare Tunnel to your local Windows, Mac, or Linux companion backend with zero telemetry or cloud lock-in.

| 📱 Android (`.apk`) | 🍏 iOS (`.ipa` & PWA — No Mac Required) | 💻 Companion Engine (`Windows / Mac / Linux`) |
| :--- | :--- | :--- |
| [![Download Android APK](https://img.shields.io/badge/Direct%20Download-Athena--Android.apk-3DDC84?style=for-the-badge&logo=android&logoColor=white)](../../releases/latest/download/Athena-Android.apk) | [![Download iOS IPA](https://img.shields.io/badge/Direct%20Download-Athena--iOS.ipa-000000?style=for-the-badge&logo=apple&logoColor=white)](../../releases/latest/download/Athena-iOS.ipa) | **1-Click Windows Launch**<br>Double-click [`scripts/start_athena.bat`](scripts/start_athena.bat)<br>*(or run `python scripts/run_athena.py`)* |
| [![Add to Obtainium](https://img.shields.io/badge/Obtainium-1--Click%20Auto--Update-10B981?style=flat-square&logo=git&logoColor=white)](https://obtainium.imranr.dev) | **Instant Fullscreen iOS WebApp**<br>*(Zero sideloading, never expires)*<br>1. Open Phone Wi-Fi URL in Safari<br>2. Tap **Share** &rarr; **Add to Home Screen** | Starts unified FastAPI + ONNX server (`:8000`), Web Reader (`:8080`), and auto-discovers your phone’s Wi-Fi IP |
| **Local USB 1-Click**:<br>`flutter install -d android` | **Windows Sideload (Free Apple ID)**:<br>Open [Sideloadly](https://sideloadly.io/) or AltStore &rarr; drag `Athena-iOS.ipa` &rarr; tap Install | **Wi-Fi Pairing URL**:<br>`http://<LAN_IP>:8000`<br>*(Inspect via `http://127.0.0.1:8000/api/pair-info`)* |

### 1-Click Installation & Setup Instructions

#### Android (Native APK & Auto-Updates)
1. **Direct Download**: Download [`Athena-Android.apk`](../../releases/latest/download/Athena-Android.apk) on your phone, open your Downloads folder, and tap to install.
2. **Automated Background Updates via Obtainium**:
   - Install [Obtainium](https://obtainium.imranr.dev) on your Android device.
   - Tap **Add App** &rarr; Paste `https://github.com/praveene3127/Athena` &rarr; Tap **Add**. Obtainium will automatically track every release and update Athena with 1 tap.
3. **Local USB Developer Install** (from your Windows PC):
   ```bash
   adb reverse tcp:8000 tcp:8000
   cd app && flutter run --release -d android
   ```

#### iOS (Native IPA & Fullscreen WebApp — Zero Mac Required)
1. **Option A: Instant Fullscreen iOS Home Screen WebApp (Zero Sideloading, Never Expires)**:
   - Make sure your iPhone is on the same Wi-Fi network as your laptop.
   - Open mobile Safari and navigate to `http://<YOUR_LAPTOP_IP>:8000` (e.g., `http://192.168.1.15:8000`).
   - Tap the Safari **Share** icon at the bottom &rarr; Scroll down and tap **Add to Home Screen**.
   - Athena launches in standalone fullscreen mode without Safari URL bars or browser chrome, powered by native `apple-mobile-web-app-capable` meta configuration.
2. **Option B: Native IPA Sideloading via Sideloadly on Windows**:
   - Download [`Athena-iOS.ipa`](../../releases/latest/download/Athena-iOS.ipa) from GitHub Releases.
   - Connect your iPhone to your Windows PC with a USB cable and launch [Sideloadly](https://sideloadly.io/).
   - Drag `Athena-iOS.ipa` into Sideloadly, enter your regular Apple ID, and click **Start**.
   - On your iPhone, open **Settings** &rarr; **General** &rarr; **VPN & Device Management** &rarr; Tap your Apple ID &rarr; Tap **Trust**. Athena is now running as a native iOS app.

#### Windows / macOS / Linux (Companion Engine)
Athena’s backend engine is self-contained and requires only Python 3.12+:
```bash
# Clone the repository
git clone https://github.com/praveene3127/Athena.git
cd Athena

# Create and activate virtual environment
python -m venv .venv
.venv\Scripts\activate   # On Windows
# source .venv/bin/activate  # On macOS/Linux

# Install dependencies
pip install -r backend/requirements.txt

# Launch unified server
python scripts/run_athena.py
```

---

## 2. What is Athena? (Core Product Philosophy)

Modern reading is broken. Minds conditioned by high-velocity algorithmic feeds (TikTok, X, Reddit) struggle with 400-page non-fiction books—not because the ideas lack depth, but because traditional reading layouts provide zero real-time dopamine or context validation. Conversely, AI book summary tools ("Blinkist", LLM summaries) strip out nuance, prose texture, and intellectual rigor.

Athena introduces **Feed-Driven Deep Reading**:
1. **100% Verbatim Canonical Prose**: Not a single word, clause, or sentence from the author is summarized, condensed, or rewritten.
2. **High-Surprisal Grounded Marginalia**: As you scroll through digestible chunks (80–140 words), an Edge AI scanner and dual-engine LLM generate grounded pedagogical context cards anchored to exact quotes.

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

### Traditional Readers vs. Summarizers vs. Athena

| Capability | Kindle / PDF Readers | AI Summarizers (Blinkist / LLM) | Athena |
| :--- | :--- | :--- | :--- |
| **Verbatim Text Integrity** | 100% (Static, boring layout) | 0% (Lossy, hallucination-prone) | **100% Cryptographically Verified** |
| **Reading Ergonomics** | Rigid multi-paragraph pages | Bullet summaries | **Mobile Feed or Flow with Dynamic Chunks** |
| **External Fact Grounding** | None (Manual Google lookup) | Pre-baked, unanchored | **2-Hop Orthogonal Search to Archival Papers** |
| **Edge AI Anti-Echo Gate** | N/A | High repetition of passage | **$\text{CosineSim} \le 0.81$ (Zero Paraphrase Echoes)** |
| **Prediction & Active Recall**| Passive reading | Generic multiple-choice | **Interactive Study Findings Spoilers** |

### The Unbreakable Mathematical Invariants
Athena enforces two strict invariants verified on every build:
- **100% Lossless Reconstruction**:
  $$\sum_{i=1}^{N} \text{chunk}_i.\text{raw\_text} \equiv \text{document}.\text{canonical\_text}$$
  Verified via SHA-256 cryptographic digest before any document is served.
- **Exact-Quote Anchoring**:
  Every marginalia card must satisfy:
  $$\text{card}.\text{anchor\_quote} \in \text{chunk}.\text{raw\_text}$$
  Cards failing exact substring containment are discarded prior to storage.

---

## 3. Deep-Dive Architecture: Hybrid Edge AI + Cloud Grounding

Athena combines an on-device ONNX embedding engine (`BAAI/bge-small-en-v1.5`) with dual cloud LLM orchestration (OpenRouter / Gemini / Groq with automatic instant failover).

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
  - Core Body Window (15%-85%)           - PubMed, Stanford, PNAS
  - Per-Page Structural Dominance        - Archival & Historical Facts
  - Book Immunity Rule (<100ms)                          |
         |                                               v
         v                               Stage 2B: ONNX Anti-Echo Gate
  Stage 1: Mathematical Hygiene          - BAAI/bge-small-en-v1.5 (CPU)
  - Shannon Entropy Filter (H < 0.65)    - CosineSim(chunk, card) <= 0.81
  - Universal Dehyphenation              - >= 2 Novel External Entities
  - Viterbi De-Compounding (wordninja)   - Wikipedia disambiguation filter
  - Modal Font Footnote Isolation                        |
         |                                               v
         v                               [ SQLModel SQLite DB ]
  Lossless Chunker (80-140 words)        - Chunks & Grounded Cards
  - SHA-256 Verification                 - Reading Progress & Vibe Cache
```

### Stage 0: The Document Bouncer (`backend/app/services/edge/bouncer.py`)
PDFs uploaded to Athena are evaluated through a sub-100ms structural triage gate before compute-heavy OCR or embedding runs:
- **Per-Page Structural Dominance (Zero Keyword Banning)**: Athena never uses crude keyword blocklists that falsely reject books describing resumes, invoices, exams, or code snippets. Instead, it measures font variety, column count, and paragraph continuity across the core body (pages `15%–85%`).
- **The Book Immunity Rule**: If a document exhibits book-length page continuity (>25 pages of narrative text flow), it receives unconditional ingestion immunity.
- **Triage Rejections**: Slides decks, scanned forms, raw spreadsheets, and programming API dumps are cleanly bounced with an explanation and an optional `"Process Anyway"` user override.

### Stage 1: Mathematical Hygiene & Self-Healing PDF Engine (`backend/app/services/edge/hygiene.py`)
Raw PDF extraction often produces typographical artifacts that destroy readability. Athena cleans text using information theory principles:
- **Shannon Entropy Glyph Filter (DeepMind *Gopher* / AllenAI *Dolma*)**:
  Strips printer border characters, repetitive decorative dividers, and scanned noise where word entropy falls below the threshold:
  $$H(w) = -\sum_{i=1}^{k} p(c_i) \log_2 p(c_i) < 0.65\text{ bits}$$
  Also collapses letter-spaced publisher imprints (e.g., `l i b e r t y  f u n d` &rarr; `liberty fund`).
- **Universal Line-Wrap Dehyphenation**:
  Distinguishes broken line wraps (`An- toninus` &rarr; `Antoninus`, `sum- mer` &rarr; `summer`) from legitimate English compound words (`self-esteem`, `eighteenth-century`, `counter-intuitive`).
- **Viterbi Unigram De-Compounding (`wordninja`)**:
  Repairs kerning collisions caused by justified PDF printers (`amusementlastsummer` &rarr; `amusement last summer`) while protecting proper nouns and technical terms (`neuroplasticity`, `electromagnetism`).
- **Modal Font-Size Footnote Isolation**:
  Calculates the document's body font histogram. Smaller text blocks at the bottom of pages are classified as `BlockType.FOOTNOTE` and extracted separately so sentences never break across page turns. Fused superscript callouts (`Foulis;2` &rarr; `Foulis;`) are cleanly sanitized.

### Stage 2: Read-Ahead Scanner & High-Surprisal Marginalia Engine
While the reader is on chunk $K$, Athena asynchronously prepares grounded cards for chunks $K+1 \dots K+5$:
- **2-Hop Orthogonal Search Grounding**:
  Queries academic indices (PubMed, APA PsycNet, Stanford Encyclopedia of Philosophy, PNAS) for historical counterpoints, empirical replications, or real-world paradoxes.
- **ONNX Anti-Echo & Novelty Gate (`backend/app/services/edge/novelty.py`)**:
  Using local ONNX embeddings (`BAAI/bge-small-en-v1.5`), Athena guarantees cards are never redundant:
  1. **$\text{CosineSim}(\text{chunk}, \text{card}) \le 0.81$**: Blocks cards that merely summarize or paraphrase the passage.
  2. **Entity Expansion**: Rejects cards that fail to introduce at least 2 novel entities (dates, sample sizes, researcher names, historical events) not present in the chunk.
  3. **Disambiguation Shield**: Filters out Wikipedia pop-culture disambiguation noise (e.g., songs or fictional characters sharing a historical figure's name).

---

## 4. The 4 Interactive Marginalia Card Archetypes

Cards cycle deterministically through four distinct cognitive lenses (`slot = card_index % 4`), ensuring readers receive varied mental stimuli:

```
+---------------------------------------------------------------------------------------+
| 1. EMPIRICAL STUDY  (Forest Emerald • #2D6A4F)                                         |
|    Scientific papers, randomized trials, statistical cohorts, and sample sizes.      |
|    Interactive: Tap [ Reveal Study Findings ] to reveal experimental results.        |
+---------------------------------------------------------------------------------------+
| 2. CRITICAL DEBATE  (Terracotta • #C84B31)                                            |
|    Major counterarguments, theoretical dissent, and empirical contradictions.        |
|    Dual-panel: Structured [ Counterpoint ] vs. [ Empirical Evidence ].                |
+---------------------------------------------------------------------------------------+
| 3. HISTORICAL CONTEXT  (Prussian Navy • #1D3557)                                      |
|    Primary source letters, geopolitical backstories, and socio-economic context.       |
|    Anchors author arguments in the tangible world of their era.                       |
+---------------------------------------------------------------------------------------+
| 4. CORE PARADOX  (Warm Ochre • #B45309)                                               |
|    Counter-intuitive laws, cognitive blindspots, and systemic contradictions.        |
|    Named laws (e.g., Goodhart's Law, Jevons Paradox, Selection Bias).                 |
+---------------------------------------------------------------------------------------+
```

### Cognitive Focus & Comprehension Tools
- **Feed Mode vs. Flow Mode**: Toggle between TikTok-style vertical snap-scrolling (one chunk + card per viewport) or continuous Medium-style reading stream.
- **Dwell-Time Passage Simplifier**: If a reader pauses on a complex passage for over 45 seconds, a subtle Athena icon appears offering a 1-tap plain English conceptual breakdown.
- **Bionic Focus Mode (`Aa`)**: Bolds the initial fixation letters of each word to facilitate rapid reading and reduce ADHD cognitive strain.
- **Ask Athena Modal**: Context-grounded Q&A sheet anchored to the current page. Virtual keyboard pushes inputs cleanly using dynamic `MediaQuery.viewInsets`.
- **Markdown Vault Export**: 1-click export of the book’s entire marginalia collection formatted for Obsidian, Logseq, and Notion.

### Bring Your Own Key (BYOK) & Automatic Dual Failover Engine
Athena supports completely private, direct-to-provider AI keys without recurring subscriptions:
- **Primary Providers**: OpenRouter, Google Gemini, Groq, Ollama, Anthropic Claude, OpenAI.
- **Automatic Fallback Circuit**: If the primary engine encounters a rate limit (HTTP 429), quota exhaustion, or server error (HTTP 500/503), Athena automatically reroutes marginalia generation to your configured fallback provider in under 200ms without interrupting your reading flow.
- **Server-Side Masking**: API keys are encrypted at rest with local machine keys and never logged.

---

## 5. The Editorial Design System ("Stripe Press & Edward Tufte")

Athena's interface is crafted for sustained intellectual focus, drawing inspiration from high-end book typography and information design:

| Element | Dark Mode Palette | Light Mode Palette | Design Purpose |
| :--- | :--- | :--- | :--- |
| **Canvas Background** | `#121212` (Deep Charcoal) | `#FAF9F6` (Alabaster Cream) | Eliminates eye fatigue during 3-hour reading sessions |
| **Prose Ink** | `#E5E5E5` (Warm Bone) | `#1A1A1A` (Carbon Ink) | Optimal contrast without harsh pure-white glare |
| **Card Surface** | `#181818` (Obsidian) | `#FFFFFF` (Crisp Paper) | Elevated tactile card surfaces |
| **Border / Hairline** | `#262626` | `#E5E5E0` | Subtle structural division |
| **Card Accent Spines** | Emerald / Terracotta / Navy / Ochre | High-contrast pedagogical color coding |

### Typography Hierarchy
- **Literary Prose**: *Newsreader* (Variable serif, optical size 18.5px on mobile, line-height 1.65, tracking 0.2px). Fits 60–70 characters per line comfortably on 390px phone screens.
- **Marginalia & Body UI**: *Plus Jakarta Sans* (Geometric sans-serif, legible at 12px on high-DPI phone displays).
- **Metadata & Quotes**: *JetBrains Mono* (Tabular numbers, chapter coordinates, and archival dates).

---

## 6. Monorepo Directory Layout

```text
Athena/
├── app/                                 # Flutter Cross-Platform Client (iOS, Android, Web)
│   ├── lib/
│   │   ├── core/                        # Infrastructure, API client & theme engine
│   │   │   ├── api/                     # ApiClient with automatic origin host switching
│   │   │   ├── config/                  # AppConfig (pure host resolver & preferences)
│   │   │   ├── theme/                   # AppTheme palette & typography tokens
│   │   │   └── widgets/                 # Shared widgets & Athena avatar expressions
│   │   ├── features/                    # Feature-driven module architecture
│   │   │   ├── ask/                     # Ask Athena contextual bottom sheet
│   │   │   ├── library/                 # Bookshelf, upload progress, and document list
│   │   │   ├── reader/                  # Feed/Flow reader, ChunkWidget & ContextCardWidget
│   │   │   └── settings/                # BYOKSettingsSheet (Primary, Failover, Server Host)
│   │   └── main.dart                    # Client entrypoint & routing
│   ├── web/index.html                   # Fullscreen iOS PWA meta tags & splash styling
│   └── pubspec.yaml                     # Flutter dependencies
│
├── backend/                             # Python 3.12+ FastAPI & ONNX Engine
│   ├── app/
│   │   ├── api/routes/                  # REST endpoints (documents, cards, ask, settings)
│   │   ├── services/
│   │   │   ├── edge/                    # Document Bouncer, Shannon Hygiene & Novelty Gate
│   │   │   ├── ingestion/               # Lossless chunker & PDF block parsing
│   │   │   ├── marginalia/              # Card synthesis, prompt templates & Wikipedia
│   │   │   └── edge_ai.py               # ONNX runtime embedder & cosine similarity
│   │   ├── db.py                        # SQLModel SQLite database engine
│   │   └── main.py                      # FastAPI application & static Flutter SPA mount
│   ├── tests/                           # 49 automated pytest suites
│   └── requirements.txt                 # Backend dependencies
│
├── scripts/                             # Operator tooling & verification
│   ├── run_athena.py                    # Unified supervisor (FastAPI + Forwarder + Wi-Fi discovery)
│   ├── start_athena.bat                 # 1-Click Windows desktop launcher
│   ├── verify_release.py                # 6-Gate verification suite
│   └── port_8080_forwarder.py           # Port 8080 web reader bridge
│
├── docs/                                # Architecture Decision Records (ADRs)
└── .github/workflows/
    └── mobile_release.yml               # Automated Android APK & iOS IPA Cloud Release
```

---

## 7. API Reference, Mobile Pairing & Verification Suite

### REST API Reference

| Endpoint | Method | Request Payload | Response | Description |
| :--- | :--- | :--- | :--- | :--- |
| `/api/health` | `GET` | None | `{"status": "ok", "database": "reachable", ...}` | Health check verifying SQLite, ONNX embedder, and AI keys |
| `/api/pair-info` | `GET` | None | `{"lan_ip": "192.168.1.15", "api_port": 8000, ...}` | Pairing metadata and local Wi-Fi / Tunnel URLs |
| `/api/documents` | `GET` | None | `[{"id": "doc_...", "title": "...", "chunks": 120}]` | List all processed books with read progress and metadata |
| `/api/documents` | `POST` | Multipart PDF/EPUB | `{"id": "doc_...", "status": "processing"}` | Upload book for structural triage and ingestion |
| `/api/documents/{id}/reader` | `GET` | None | `{"document": {...}, "chunks": [...], "cards": [...]}` | Fetch lossless chunks and grounded marginalia cards |
| `/api/documents/{id}/progress` | `POST` | `{"chunk_index": 42}` | `{"status": "ok"}` | Sync active reading position and bookmark across devices |
| `/api/documents/{id}/force-ingest` | `POST` | None | `{"status": "queued"}` | Ingestion override bypassing document bouncer triage |
| `/api/documents/{id}/vibe-check` | `POST` | `{"chunk_index": 5}` | `{"simplified": "..."}` | Real-time passage simplification breakdown |
| `/api/ask/local` | `POST` | `{"question": "...", "passage_text": "..."}` | `{"answer": "...", "status": "ok"}` | Grounded Q&A against current passage (requires context token) |
| `/api/settings/ai` | `GET` | None | `{"primary_provider": "openrouter", ...}` | Inspect current BYOK provider configurations |
| `/api/settings/ai` | `POST` | `{"primary_provider": "...", "primary_api_key": "..."}` | `{"status": "saved"}` | Persist updated primary and failover AI credentials |

### Wireless Mobile Pairing Guide
1. Launch the backend engine on your laptop:
   ```bash
   python scripts/run_athena.py
   ```
2. Note your laptop’s Wi-Fi IP displayed in the terminal banner:
   ```text
   ====================================================================
              ATHENA UNIFIED PIPELINE SUPERVISOR
     Local API   : http://127.0.0.1:8000/api/health
     Wi-Fi LAN   : http://192.168.1.15:8000  (Connect phone wirelessly)
     Web Reader  : http://127.0.0.1:8080
     Pair Info   : http://127.0.0.1:8000/api/pair-info
   ====================================================================
   ```
3. Open `http://<YOUR_LAN_IP>:8000` in mobile Safari or Chrome, or open your native `.apk` / `.ipa`, tap **Settings** &rarr; **SERVER HOST**, enter `http://<YOUR_LAN_IP>:8000`, and tap **Test Connection**.

### 6-Gate Release Verification Suite
Athena enforces an automated verification suite that audits code hygiene, technical word preservation, security contracts, and core mathematical invariants:

```bash
# 1. Run the Full 6-Gate Release Verifier
python scripts/verify_release.py

# 2. Run Backend Pytest Suite (49 unit tests)
pytest backend/tests -q

# 3. Run Flutter Analyzer & Tests
cd app && flutter analyze lib && flutter test
```

```text
======================================================================
 GATE 1: STATIC GREP & ANTI-SLOP AUDIT             -> [PASS] (0 violations)
 GATE 2: TECHNICAL WORD PRESERVATION               -> [PASS] (Wordninja compounds)
 GATE 3: API MATRIX & SECURITY CONTRACT            -> [PASS] (Headers enforced)
 GATE 4: PYTEST BACKEND TEST SUITE                 -> [PASS] (49/49 passed)
 GATE 5: FLUTTER ANALYSIS & UNIT TESTS             -> [PASS] (0 issues)
 GATE 6: CORE LOSSLESS CHUNKING INVARIANTS         -> [PASS] (SHA-256 verified)
======================================================================
 ALL 6 GATES PASSED! ATHENA IS 100% PRODUCTION READY.
======================================================================
```

---

## 8. Development & Contribution Guide

Athena welcomes community contributions. To ensure quality, all pull requests must comply with the 6 release gates and maintain 100% lossless canonical prose integrity.

### Development Environment Setup
```bash
# Frontend setup
cd app
flutter pub get
flutter run -d chrome

# Backend setup
cd ../backend
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
```

### Submitting Changes
1. Run `python scripts/verify_release.py` locally.
2. Ensure `flutter analyze lib` returns zero warnings or errors.
3. Ensure `pytest backend/tests` passes all 49 tests.
4. Open a pull request against `main`. GitHub Actions will automatically validate the build and compile `Athena-Android.apk` and `Athena-iOS.ipa`.

---

<p align="center">
  <sub>Built with intellectual rigor for deep reading. Distributed under the MIT License.</sub>
</p>
