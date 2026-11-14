# ATHENA — Architecture & Engineering Specification

Athena is a high-performance, mobile-first reading system engineered around lossless text preservation, deep reader comfort, and intelligent marginalia.

---

## 1. Dual-Mode Deployment Architecture

Athena is built to run anywhere without requiring cloud lock-in or fragile network cables:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        MODE 1: STANDALONE ON-DEVICE                   │
│                                                                        │
│   Flutter Mobile App (Android / iOS)                                  │
│   ├── Pure Dart / Native Engine: IngestionJobCoordinator & Sync       │
│   ├── Rust Core FFI (`athena_rust_core`): O(1) Tape, Fast Chunker      │
│   ├── Local Storage: SQLite (`sqflite`), FTS5 Full-Text Search         │
│   └── Edge AI Marginalia: Extractive Wikipedia + User BYOK Keys       │
└────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────┐
│                        MODE 2: COMPANION SERVER                       │
│                                                                        │
│   FastAPI Server (`backend/app/main.py`)                              │
│   ├── Single-Origin Web Hosting: Mounts `app/build/web` at `/`         │
│   ├── Engine: PyMuPDF Extraction, RapidOCR, Hybrid FastEmbed Search    │
│   ├── Dynamic LAN Pairing: `/api/pair-info` dynamic IP discovery       │
│   └── Streaming & Tape APIs: `/api/documents/{id}/reader?from_seq=...` │
└────────────────────────────────────────────────────────────────────────┘
```

### Mode Capabilities Matrix
| Capability | Standalone On-Device Mobile | Companion Server Mode |
| :--- | :--- | :--- |
| **PDF Extraction** | Syncfusion PDF + Native Isolate Engine | PyMuPDF with Font Map & Gutter Recovery |
| **Scanned Document OCR** | Digital prose fallback | RapidOCR with ONNX Runtime |
| **Lossless Chunking** | Exact slice-based `LosslessChunker` | Dynamic programming `chunker.py` + Rust core |
| **Full-Text Search** | SQLite FTS5 Full-Text Virtual Table | Hybrid BM25 + FastEmbed Dense Vectors |
| **Context Cards** | Extractive Wikipedia + BYOK Live LLM | 4-Archetype Dynamic Marginalia Pipeline |
| **Offline Functionality**| 100% Offline Capable | Requires Local Wi-Fi Connection |

---

## 2. Layer Isolation Architecture (L1–L7)

Athena enforces strict separation of concerns across engineering layers:

- **L1–L3 (Extraction & Invariants)**: Text normalization, Gopher mathematical hygiene, character repair (`RepairLedger`), zero-kerning splits, and compound word preservation.
- **L4 (Lossless Chunking)**: Guarantees `"".join(chunk["raw_text"] for chunk in chunks) == canonical_text` with matching cryptographic SHA-256 digests.
- **L5 (Marginalia Engine)**: 4-Archetype card rotation (`empirical_study`, `philosophy_paradox`, `historical_case`, `counterpoint`) with anti-echo novelty filtering (cosine similarity $\le 0.81$).
- **L6 (State Management)**: Deterministic, windowed repositories (`BookRepository`) and reactive notifiers (`ReaderController`) supporting infinite-scale paging over 30,000+ chunks.
- **L7 (UI Presentation)**: Isolated, dumb widgets (`< 400` lines each) styled with `AthenaTokens` across 4 appearances (`Paper`, `Sepia`, `Charcoal`, `OLED`) with 0 layout overflows on mobile viewports (`390×844`).

---

## 3. Storage & Schema Alignment

Rust (`sqlite_store.rs`), Dart (`local_database.dart`), and Python (`db.py` / `models.py`) adhere to an identical SQLite schema:
- **`documents`**: Metadata, status, checkpoint coordinates, stats.
- **`reading_chunks`**: Contiguous chunk sequence, byte offsets, source pages, and SHA-256 checksums.
- **`reading_chunks_fts`**: FTS5 full-text index kept in lockstep via automated database triggers.
- **`context_cards`**: Anchored exact quotes, archetype flavor, source citations, and dismissal state.
- **`reading_positions`**: Persistent canonical reading progress (`chunk_seq`, `intra_byte`, `updated_at`).
