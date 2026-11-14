# Athena State Machines Specification

This document formalizes the 10 core state machines governing Athena's cross-platform client (Flutter/Dart) and server (FastAPI/Python/SQLite) systems, backed by machine-readable contracts in [`contracts/state-machines.json`](../contracts/state-machines.json).

---

## 1. DocumentLifecycle (ISM-02 / SM-01)
Controls the status of an ingested book in the library and database.

### States
- `queued`: Stored in DB, waiting for background extraction worker.
- `processing`: Active text extraction, cleaning, and chunking in progress.
- `partially_readable`: First milestone reached (>= 16 pages chunked). User may begin reading.
- `paused`: Worker cleanly paused at checkpoint. Resumes at `last_checkpoint_page + 1`.
- `interrupted`: Worker interrupted abnormally (app killed/power loss). Resumes at checkpoint.
- `ready`: Document extraction, chunking, and SHA-256 integrity verified. Immediately readable.
- `failed`: Terminal extraction failure. Contains `error_code` and `error_message`.
- `unsupported`: Rejected by initial Bouncer gate (e.g. non-narrative book, slide deck).
- `deleted`: Document marked deleted or purged.

### Invariant & Anti-Regression Law (SM-01)
- **Forbidden Transition**: `ready -> processing`.
- Once a document is `ready`, background concept extraction and Context Card synthesis update `context_status`, `stage`, and `percent`. **`doc.status` MUST NEVER regress back to `processing`**.

---

## 2. ContextEnrichment (SM-07)
Controls asynchronous background marginalia generation.

### States
- `idle`: Awaiting concept extraction trigger.
- `finding_concepts`: Discovering salient concepts and entities from canonical chunks.
- `preparing_context`: Retrieving multi-source academic/Wikipedia evidence and synthesizing 4-archetype cards.
- `ready`: All context cards generated and persisted to database.
- `partial`: Subsets of concepts identified with partial evidence.
- `unavailable`: External LLM unconfigured or rate-limited; fallback to local extractive notes.

---

## 3. IngestionWorkerFgs (SM-02)
Controls Android Foreground Service (FGS) and notification channel lifecycle.

### States
- `idle`: No active background jobs running. FGS stopped.
- `starting`: Acquiring wakelock, ref-counting `_activeDocIds.add(docId)`, requesting notification permission.
- `running`: Actively extracting and committing chunk batches every 16 pages.
- `pausing`: User requested pause; committing current batch checkpoint.
- `paused`: Checkpoint safely saved in SQLite.
- `timed_out`: Received Android OS timeout (`onForegroundTimeout`). Cleanly halts and checkpoints.
- `stopping`: Ref-count reaches 0 (`_activeDocIds.isEmpty`). Calls `stopForegroundService`.

### Invariant
- Finishing Job A must never stop foreground notifications while Job B is still active.

---

## 4. AppearanceSettings (ISM-01 / SM-04)
Controls the unified editorial appearance across all screens.

### States
- `paper`: Light Editorial (`#FBF9F5` canvas, `#161615` ink).
- `sepia`: Warm Classic (`#F4ECD8` canvas, `#2C221E` ink).
- `charcoal`: Night Muted (`#121316` canvas, `#ECEAE4` ink).
- `oled`: Pure Midnight (`#000000` canvas, `#F5F5F0` ink).

---

## 5. ConnectionMode (ISM-03 / S-02)
Controls network topology and API routing.

### States
- `standalone_local`: Native mobile running 100% on-device (SQLite + local pipeline).
- `companion_lan`: Connected to laptop companion server via private Wi-Fi (RFC1918 `192.168.x.x`).
- `companion_tunnel`: Connected to companion server via Cloudflare Tunnel (`https://*.trycloudflare.com`).
- `disconnected`: Network link lost; automatically falls back to local cache.

---

## 6. ReaderViewport (ISM-05)
Controls the active reader screen layout and modal states.

### States
- `unloaded`: Reader initialized without active feed.
- `loading`: Loading chunks from SQLite or API.
- `paginating`: Keyset pagination fetching next chunk window.
- `active_reading`: Standard 60fps vertical page snapping (Feed Mode) or Flow Mode.
- `drawer_open`: Chapter outline drawer open.
- `sheet_open`: Typography sheet, Ask sheet, or BYOK settings modal open.
- `backgrounded`: Reader minimized or sent to background; preserves chunk sequence.

---

## 7. CardSlotSynthesis (ISM-08 / SM-08)
Controls speculative generation for Context Cards per chunk sequence.

### States
- `absent`: No card present for this chunk sequence.
- `in_flight`: Background generation active for this chunk sequence.
- `ready`: Card generated, verified against grounding gates, and persisted to SQLite.
- `failed_cooldown`: Generation failed (429/timeout). Locked in cooldown to prevent LLM retry storms.

---

## 8. CardUserState (ISM-08 / SM-09)
Tracks user engagement with a Context Card.

### States
- `unseen`: Card generated but not yet scrolled into viewport.
- `viewed`: Card displayed in reader feed.
- `saved`: Card saved to user's Brain Deck / Saved Vault (`saved = 1, dismissed = 0`).
- `dismissed`: Card dismissed by reader (`dismissed = 1, saved = 0`).

### Invariant
- `saved` and `dismissed` are strictly mutually exclusive.

---

## 9. AIProviderSlot (ISM-07 / SM-12)
Tracks BYOK AI provider status and failover routing.

### States
- `unconfigured`: No API key or model provided.
- `verifying`: Testing connection and model availability (`/v1beta/models` or `/v1/models`).
- `active_primary`: Primary provider active and healthy.
- `active_fallback`: Primary failed (429/5xx/timeout); routing requests to configured fallback provider.
- `cooldown_429`: Provider hit rate limit; temporarily paused.
- `failed_auth`: API key rejected (401/403).

---

## 10. SavedVault (ISM-08)
Controls the persisted notes and quotes library.

### States
- `empty`: Zero saved cards or quotes in SQLite.
- `populated`: Cards and quotes present and grouped by document title.
- `syncing`: Ingestion or unsave update in flight.
- `cleared`: All saved notes and quotes cleared.
