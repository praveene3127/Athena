# AGENTS.md — Constitutional Laws & ECC Skills Orchestration Engine

This repository is governed by strict, non-negotiable architectural and testing laws, backed by an autonomous library of **312 specialized engineering skills** located in [`.agents/skills/`](file:///c:/Users/prave/Downloads/Athena/.agents/skills) and domain rules in [`.agents/rules/`](file:///c:/Users/prave/Downloads/Athena/.agents/rules).

Any autonomous agent operating in Athena MUST strictly comply with every constitutional law and consult the relevant skills before modifying production code.

---

## 1. Constitutional Laws

### Law 1: Zero Test Weakening (Anti-Reward-Hacking Law)
- **Strict Prohibition**: You are strictly forbidden from modifying test assertions, lowering sample sizes, reducing word-count multipliers, or weakening validation thresholds in any existing test file to force failing tests to pass.
- **Root-Cause Fixing Only**: If a test fails, you MUST fix the underlying implementation in production code ([`backend/app/services/edge/bouncer.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/edge/bouncer.py), [`hygiene.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/edge/hygiene.py), [`novelty.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/edge/novelty.py), [`chunker.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/chunker.py), etc.).
- **No Test-String Hardcoding**: You may never hardcode synthetic test strings, specific filenames, or artificial regex overrides in production modules to overfit static assertions.
- **Real PDF Verification**: Always verify edge parsing against real multi-page PyMuPDF documents (> 600 words) with authentic geometry, fonts, and structural elements.

### Law 2: Strict Monorepo Directory Law
- **Root Directory Cleanliness**:
  The root directory `Athena/` must remain completely clean. It may ONLY contain:
  - [`README.md`](file:///c:/Users/prave/Downloads/Athena/README.md)
  - [`AGENTS.md`](file:///c:/Users/prave/Downloads/Athena/AGENTS.md)
  - [`.gitignore`](file:///c:/Users/prave/Downloads/Athena/.gitignore)
  - `.mcp.json` (if present)
  - Standard dot-folders: `.git`, `.github`, `.venv`, `.agents`
  Zero loose `.py`, `.bat`, `.log`, or `.md` files (other than `README.md` and `AGENTS.md`) may exist in the root folder.
- **Scripts Location**: All operational, forwarder, launch, and verification scripts MUST reside in [`scripts/`](file:///c:/Users/prave/Downloads/Athena/scripts).
- **Documentation Location**: All architectural decision records, specifications, and deep-dive documentation MUST reside in [`docs/`](file:///c:/Users/prave/Downloads/Athena/docs).
- **Backend Architecture**:
  `backend/app/services/` MUST be partitioned into domain sub-packages:
  - `edge/`: [`bouncer.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/edge/bouncer.py), [`hygiene.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/edge/hygiene.py), [`novelty.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/edge/novelty.py)
  - `ingestion/`: [`extraction.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/extraction.py), [`blocks.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/blocks.py), [`normalize.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/normalize.py), [`canonical.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/canonical.py), [`jobs.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/jobs.py), [`chunker.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/chunker.py), [`arrangement.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/arrangement.py), [`integrity.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/integrity.py), [`repairs.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/repairs.py), [`triage.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/ingestion/triage.py)
  - `marginalia/`: [`pipeline.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/marginalia/pipeline.py), [`cards.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/marginalia/cards.py), [`concepts.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/marginalia/concepts.py), [`llm.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/marginalia/llm.py), [`wikipedia.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/marginalia/wikipedia.py), [`providers.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/marginalia/providers.py), [`search.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/services/marginalia/search.py)
- **Frontend Architecture**:
  `app/lib/` MUST follow feature-first clean architecture:
  - `core/`: `api/`, `config/`, `theme/`, `widgets/`
  - `features/`: `library/`, `processing/`, `reader/`, `settings/` — with clean separation between `screens/` and `widgets/`.

### Law 3: Mobile-First Networking & Viewport Law
- **Dynamic Mobile Host Resolution**:
  Never hardcode `127.0.0.1:8000` as the only API host. Mobile phones over Wi-Fi (`192.168.x.x`), Cloudflare Tunnels (`https://*.trycloudflare.com`), or native APK/IPA builds cannot reach laptop loopback.
- **Single-Origin FastAPI Hosting**:
  FastAPI ([`backend/app/main.py`](file:///c:/Users/prave/Downloads/Athena/backend/app/main.py)) MUST mount `app/build/web` static assets directly at `/` (after registering `/api/*` routes) so a single port (`:8000` or `:8080`) serves both the Flutter Web client and REST API without CORS friction.
- **Dynamic Origin in Flutter**:
  `AppConfig.apiBaseUrl` must resolve to `Uri.base.origin` on web, and native Android/iOS builds must allow configuring and persisting a custom Server URL via `BYOKSettingsSheet`.
- **Responsive Viewports**:
  All reading layouts and cards must render with zero horizontal overflow and comfortable margins (`16px`) on mobile viewports (`360px–430px`, including iPhone 15 Pro `390×844` and Android `412×915`).

### Law 4: Lossless Data Integrity Law
- **Canonical Text Immutability**:
  Athena guarantees 100% byte-exact preservation of author text. Chunking MUST satisfy `"".join(chunk["raw_text"] for chunk in chunks) == canonical_text` with matching SHA-256 digests.
- **Exact-Quote Anchoring**:
  Every Context Card must anchor to an authentic, un-paraphrased substring of the passage (`card.exact_quote in chunk.raw_text`).
- **High-Surprisal Marginalia**:
  Cards must introduce orthogonal information gain (>= 2 novel named entities/metrics not in the chunk, echo cosine similarity <= 0.81, and rotation across the 4 archetypes: `empirical_study`, `philosophy_paradox`, `historical_case`, `counterpoint`).

---

## 2. ECC Skills Autonomous Orchestration Directive

Athena integrates **312 specialized engineering skills** from the Extended Capability Catalog (ECC) located in [`.agents/skills/`](file:///c:/Users/prave/Downloads/Athena/.agents/skills) and language-specific rules in [`.agents/rules/`](file:///c:/Users/prave/Downloads/Athena/.agents/rules).

### Mandatory Skill Invocation Protocol
Before initiating ANY modification to codebase architecture, features, database schemas, or tests, the agent **MUST**:
1. Check the **Domain Skill Routing Matrix** below.
2. View the corresponding skill's `SKILL.md` file using `view_file`.
3. Apply the skill's design patterns, constraints, and checklist to the implementation.

### Domain Skill Routing Matrix

| Domain & Task Area | Primary ECC Skills | Supporting Skills | Relevant Rules |
| :--- | :--- | :--- | :--- |
| **Flutter UI & Mobile UX** | `flutter-expert`, `mobile-app-design`, `responsive-design` | `dart-analyzer`, `ui-ux-design`, `cross-platform-build` | `.agents/rules/dart/`, `web/` |
| **Mobile Native Builds (APK/IPA)** | `android-clean-architecture`, `ios-development` | `build-automation`, `mobile-developer` | `.agents/rules/common/` |
| **FastAPI Backend & Routers** | `fastapi-patterns`, `api-design`, `backend-patterns` | `pydantic-expert`, `rest-api`, `python-clean-code` | `.agents/rules/python/python-fastapi.md` |
| **SQLite & Data Modeling** | `sqlite-expert`, `database-design`, `sql-optimization` | `data-modeling`, `database-migrations` | `.agents/rules/common/common-patterns.md` |
| **Edge AI, Embeddings & NLP** | `rag-patterns`, `prompt-engineering`, `llm-orchestration` | `vector-search`, `semantic-cache`, `deep-research` | `.agents/rules/python/python-patterns.md` |
| **Adversarial Testing & Gates** | `verification-loop`, `eval-harness`, `test-driven-development` | `benchmark-methodology`, `security-audit`, `anti-hallucination` | `.agents/rules/common/common-testing.md` |
| **Refactoring & Code Hygiene** | `clean-architecture`, `refactoring`, `ponytail` | `code-review`, `performance-optimization` | `.agents/rules/common/common-coding-style.md` |

### Key Skills Reference Guide

- **`flutter-expert`** ([`.agents/skills/flutter-expert/SKILL.md`](file:///c:/Users/prave/Downloads/Athena/.agents/skills/flutter-expert/SKILL.md)):
  State management via Riverpod/ValueNotifier, responsive layout constraints (`LayoutBuilder`, `MediaQuery`), 60fps scrolling, zero-jank theme switching, and platform channel handling.
- **`fastapi-patterns`** ([`.agents/skills/fastapi-patterns/SKILL.md`](file:///c:/Users/prave/Downloads/Athena/.agents/skills/fastapi-patterns/SKILL.md)):
  Async lifespan handlers, structured dependency injection, strict Pydantic v2 schemas, streaming responses, and single-origin static mount configurations.
- **`verification-loop`** ([`.agents/skills/verification-loop/SKILL.md`](file:///c:/Users/prave/Downloads/Athena/.agents/skills/verification-loop/SKILL.md)):
  Automated multi-stage feedback loops: static linting -> unit testing -> integration smoke checks -> adversarial invariant audits before reporting task completion.
- **`eval-harness`** ([`.agents/skills/eval-harness/SKILL.md`](file:///c:/Users/prave/Downloads/Athena/.agents/skills/eval-harness/SKILL.md)):
  Rigorous benchmark generation for NLP classifiers, Cosine similarity novelty scoring, and precision/recall evaluation on holdout document sets.
- **`sqlite-expert`** ([`.agents/skills/sqlite-expert/SKILL.md`](file:///c:/Users/prave/Downloads/Athena/.agents/skills/sqlite-expert/SKILL.md)):
  WAL-mode concurrency, indexed range queries on chunk offsets, schema migration integrity, and foreign key enforcement.
- **`ponytail`** ([`.agents/skills/ponytail/SKILL.md`](file:///c:/Users/prave/Downloads/Athena/.agents/skills/ponytail/SKILL.md)):
  The smallest change that fully solves the task. Zero over-engineering, zero bloat, surgical fixes directly at the root cause.

---

## 3. The Un-Gameable 8-Gate Definition of Done

No task or pull request is complete until all 8 adversarial gates pass without exception:

```bash
python scripts/strict_goal_judge.py
```

### The 8 Verification Gates
1. **Gate 1: Monorepo Structure & Root Cleanliness Audit**
   - 0 loose `.py`, `.bat`, `.log` files in root.
   - All domain packages (`edge`, `ingestion`, `marginalia`, `core`, `features`, `scripts`, `docs`) intact.
   - `README.md` >= 250 lines, `AGENTS.md` >= 50 lines.
2. **Gate 2: Adversarial Real-PDF Holdout Bouncer Test**
   - Evaluates 6 real 8-page PDFs (> 600 words each) generated dynamically with PyMuPDF.
   - Admitted: Narrative Book, Anecdotal Book quoting invoice/legal snippet.
   - Rejected: STEM Formula Textbook, Coding Manual, Landscape Slide Deck, Tabular Ledger.
3. **Gate 3: Self-Healing Hygiene & Technical Vocabulary Preservation**
   - DeepMind Gopher/Dolma mathematical hygiene.
   - Line-wrap de-hyphenation while preserving compound prefixes (`self-esteem`) and valid words (`understanding`).
   - Split fused kerning, strip superscript footnote markers, preserve scientific terms (`neuroplasticity`, `electromagnetism`).
4. **Gate 4: Lossless SHA-256 Invariant on Corpus Chunking**
   - Exact contiguous reconstruction: `"".join(chunks) == original_text` with matching SHA-256 digests.
5. **Gate 5: Marginalia 4-Archetype Rotation & Anti-Echo Novelty Audit**
   - Rejects echo paraphrases (> 0.81 cosine similarity).
   - Requires >= 2 novel external named entities/metrics.
   - Disallows Wikipedia disambiguation stubs.
   - Verifies all 4 archetypes (`empirical_study`, `philosophy_paradox`, `historical_case`, `counterpoint`).
6. **Gate 6: Backend Pytest Suite**
   - 100% green on all 49 backend unit and integration tests.
7. **Gate 7: Flutter Static Analysis & Unit Tests**
   - `flutter analyze` reports 0 issues.
   - `flutter test` passes 100%.
   - Web PWA standalone configuration & meta tags verified in `web/index.html`.
8. **Gate 8: Real Mobile Viewport & LAN IP Single-Origin E2E Test**
   - `/api/health` returns status ok and database reachable.
   - `/api/pair-info` dynamic LAN IP resolution.
   - Single-origin root mount (`GET /`) serves web UI.
   - Mobile LAN origin CORS acceptance and responsive phone viewport meta (`390×844`).

**Exit Requirement**: `scripts/strict_goal_judge.py` MUST exit with return code `0` outputting:
```
>>> ALL 8 GATES PASSED! ATHENA IS 100% PRODUCTION READY <<<
```
