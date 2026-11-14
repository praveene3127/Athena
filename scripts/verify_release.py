#!/usr/bin/env python3
"""
Athena Phase 5 Release Gate: verify_release.py
Comprehensive automated release verification suite for Athena.

Exits 0 ONLY when all production hardening gates pass:
  1. Single Version Consistency (1.1.0 across pubspec.yaml, config.dart, version.json, pyproject.toml, main.py)
  2. Static Grep Audit (no raw print, TODO/FIXME, mock, lorem, hardcoded paths, banned legacy phrases)
  3. Rust Core Cargo Test (backend/rust_core, graceful skip if cargo not on PATH)
  4. Technical Word Preservation (Edge AI wordninja does not split scientific compounds)
  5. API Matrix & Security Contract (health, documents, CORS, 404s, context token auth header)
  6. Pytest Backend Suite (100% green on backend/tests)
  7. Flutter Static Analysis & Unit Tests (0 issues, all tests pass)
  8. Invariants: Lossless Chunking ("".join(chunks) == source) & Exact-Quote Anchoring
"""

import os
import re
import sys
import json
import shutil
import subprocess
from typing import List, Tuple

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND_DIR = os.path.join(ROOT_DIR, "backend")
APP_DIR = os.path.join(ROOT_DIR, "app")
RUST_CORE_DIR = os.path.join(BACKEND_DIR, "rust_core")
VENV_PYTHON = os.path.join(ROOT_DIR, ".venv", "Scripts", "python.exe")
if not os.path.isfile(VENV_PYTHON):
    VENV_PYTHON = sys.executable

FLUTTER_BAT = r"C:\src\flutter\bin\flutter.bat"
if not os.path.isfile(FLUTTER_BAT):
    FLUTTER_BAT = "flutter"

sys.path.insert(0, BACKEND_DIR)


PASSED_GATES: List[Tuple[int, str]] = []
SKIPPED_GATES: List[Tuple[int, str, str]] = []


def log_gate(gate_num: int, title: str):
    print("\n" + "=" * 70)
    print(f" GATE {gate_num}: {title.upper()}")
    print("=" * 70)


def pass_gate(gate_num: int, title: str):
    PASSED_GATES.append((gate_num, title))
    print(f" [PASS] Gate {gate_num}: {title}\n")


def skip_gate(gate_num: int, title: str, reason: str):
    SKIPPED_GATES.append((gate_num, title, reason))
    print(f" [SKIPPED] Gate {gate_num}: {title} (SKIPPED: {reason})\n")


def fail_gate(gate_num: int, title: str, reason: str):
    print(f"\n [FAIL] Gate {gate_num}: {title}")
    print(f" Reason: {reason}\n")
    sys.exit(1)


# ==============================================================================
# GATE 1: SINGLE VERSION CONSISTENCY AUDIT
# ==============================================================================
def gate_1_version_consistency():
    log_gate(1, "Single Version Consistency Audit")
    expected_version = "1.1.0"

    # 1. app/pubspec.yaml
    pubspec_path = os.path.join(APP_DIR, "pubspec.yaml")
    with open(pubspec_path, "r", encoding="utf-8") as f:
        pubspec_content = f.read()
    m_pub = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", pubspec_content, re.MULTILINE)
    pub_ver = m_pub.group(1) if m_pub else None
    if pub_ver != expected_version:
        fail_gate(1, "Version Consistency", f"app/pubspec.yaml version '{pub_ver}' != '{expected_version}'")
    print(f"  + app/pubspec.yaml version: {pub_ver}")

    # 2. app/lib/core/config/config.dart
    config_path = os.path.join(APP_DIR, "lib", "core", "config", "config.dart")
    with open(config_path, "r", encoding="utf-8") as f:
        config_content = f.read()
    m_cfg = re.search(r"appVersion\s*=\s*['\"]([^'\"]+)['\"]", config_content)
    cfg_ver = m_cfg.group(1) if m_cfg else None
    if cfg_ver != expected_version:
        fail_gate(1, "Version Consistency", f"config.dart appVersion '{cfg_ver}' != '{expected_version}'")
    print(f"  + app/lib/core/config/config.dart appVersion: {cfg_ver}")

    # 3. scripts/version.json
    version_json_path = os.path.join(ROOT_DIR, "scripts", "version.json")
    with open(version_json_path, "r", encoding="utf-8") as f:
        vj = json.load(f)
    vj_ver = vj.get("version")
    if vj_ver != expected_version:
        fail_gate(1, "Version Consistency", f"scripts/version.json version '{vj_ver}' != '{expected_version}'")
    print(f"  + scripts/version.json version: {vj_ver}")

    # 4. backend/pyproject.toml
    pyproject_path = os.path.join(BACKEND_DIR, "pyproject.toml")
    with open(pyproject_path, "r", encoding="utf-8") as f:
        pyproject_content = f.read()
    m_py = re.search(r"^version\s*=\s*['\"]([^'\"]+)['\"]", pyproject_content, re.MULTILINE)
    py_ver = m_py.group(1) if m_py else None
    if py_ver != expected_version:
        fail_gate(1, "Version Consistency", f"backend/pyproject.toml version '{py_ver}' != '{expected_version}'")
    print(f"  + backend/pyproject.toml version: {py_ver}")

    # 5. backend/app/main.py
    main_path = os.path.join(BACKEND_DIR, "app", "main.py")
    with open(main_path, "r", encoding="utf-8") as f:
        main_content = f.read()
    m_main = re.search(r"version\s*=\s*['\"]([^'\"]+)['\"]", main_content)
    main_ver = m_main.group(1) if m_main else None
    if main_ver != expected_version:
        fail_gate(1, "Version Consistency", f"backend/app/main.py FastAPI version '{main_ver}' != '{expected_version}'")
    print(f"  + backend/app/main.py FastAPI version: {main_ver}")

    pass_gate(1, f"Single Version Consistency ({expected_version})")


# ==============================================================================
# GATE 2: STATIC GREP AUDIT
# ==============================================================================
def gate_2_static_grep():
    log_gate(2, "Static Grep & Anti-Slop Audit")

    checks: List[Tuple[str, str, str, bool]] = [
        # (directory, pattern, description, is_regex)
        (
            os.path.join(BACKEND_DIR, "app"),
            r"print\(",
            "Raw print() calls in backend/app",
            True,
        ),
        (
            os.path.join(BACKEND_DIR, "app"),
            r"\b(TODO|FIXME)\b",
            "TODO/FIXME comments in backend/app",
            True,
        ),
        (
            os.path.join(APP_DIR, "lib"),
            r"\b(TODO|FIXME)\b",
            "TODO/FIXME comments in app/lib",
            True,
        ),
        (
            os.path.join(BACKEND_DIR, "app"),
            r"\bmock\b",
            "Mock identifiers in backend/app",
            True,
        ),
        (
            os.path.join(APP_DIR, "lib"),
            r"\bmock\b",
            "Mock identifiers in app/lib",
            True,
        ),
        (
            os.path.join(BACKEND_DIR, "app"),
            r"\blorem\b",
            "Lorem ipsum placeholder text in backend/app",
            True,
        ),
        (
            os.path.join(APP_DIR, "lib"),
            r"\blorem\b",
            "Lorem ipsum placeholder text in app/lib",
            True,
        ),
        (
            os.path.join(BACKEND_DIR, "app"),
            r"(?:C:\\Users|[/\\]Users[/\\])",
            "Hardcoded user absolute paths in backend/app",
            True,
        ),
        (
            os.path.join(APP_DIR, "lib"),
            r"(?:C:\\Users|[/\\]Users[/\\])",
            "Hardcoded user absolute paths in app/lib",
            True,
        ),
        (
            os.path.join(APP_DIR, "lib"),
            r"ORIGINAL SOURCE",
            "Banned legacy phrase 'ORIGINAL SOURCE' in app/lib",
            False,
        ),
    ]

    for search_dir, pattern, desc, is_regex in checks:
        regex = re.compile(pattern, re.IGNORECASE) if is_regex else None
        violations = []
        for root, _, files in os.walk(search_dir):
            if "__pycache__" in root or ".pytest_cache" in root:
                continue
            for fname in files:
                if not (fname.endswith(".py") or fname.endswith(".dart")):
                    continue
                fpath = os.path.join(root, fname)
                try:
                    with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                        for lno, line in enumerate(f, 1):
                            if is_regex:
                                if regex.search(line):
                                    violations.append(f"{fpath}:{lno}: {line.strip()}")
                            else:
                                if pattern in line:
                                    violations.append(f"{fpath}:{lno}: {line.strip()}")
                except Exception as e:
                    violations.append(f"{fpath}: Read error: {e}")

        if violations:
            fail_gate(
                2,
                "Static Grep Audit",
                f"Found prohibited pattern '{pattern}' ({desc}):\n"
                + "\n".join(violations[:10]),
            )
        print(f"  + Checked {desc}: 0 violations")

    pass_gate(2, "Static Grep & Anti-Slop Audit")


# ==============================================================================
# GATE 3: RUST CORE CARGO TEST
# ==============================================================================
def gate_3_cargo_test():
    log_gate(3, "Rust Core Cargo Test")
    cargo_bin = shutil.which("cargo")
    if not cargo_bin:
        skip_gate(3, "Rust Core Cargo Test", "cargo not installed on host")
        return

    cmd = [cargo_bin, "test"]
    print(f"  Running: {' '.join(cmd)} in {RUST_CORE_DIR}...")
    res = subprocess.run(cmd, cwd=RUST_CORE_DIR, capture_output=True, text=True)
    print(res.stdout)
    if res.returncode != 0:
        print(res.stderr)
        fail_gate(3, "Rust Core Cargo Test", f"cargo test failed with exit code {res.returncode}")
    pass_gate(3, "Rust Core Cargo Test")


# ==============================================================================
# GATE 4: TECHNICAL WORD PRESERVATION
# ==============================================================================
def gate_4_technical_words():
    log_gate(4, "Technical Word Preservation (Edge AI Wordninja)")

    try:
        from app.services.edge.hygiene import split_fused_kerning_words
    except ImportError as e:
        fail_gate(4, "Technical Word Preservation", f"Cannot import edge_ai: {e}")

    technical_words = [
        "neuroplasticity",
        "electromagnetism",
        "thermodynamics",
        "photosynthesis",
        "crystallography",
        "biotechnology",
        "paleontology",
        "socioeconomic",
        "cardiovascular",
        "counterintuitive",
    ]

    for word in technical_words:
        result = split_fused_kerning_words(word)
        if result != word:
            fail_gate(
                4,
                "Technical Word Preservation",
                f"Word '{word}' was incorrectly split into '{result}'",
            )
        print(f"  + Preserved compound: '{word}' -> '{result}'")

    # Also verify that genuinely fused words DO get split
    fused_samples = [
        ("theinterconnectedness", "the interconnectedness"),
        ("amusementlastsummer", "amusement last summer"),
    ]
    for fused, expected in fused_samples:
        result = split_fused_kerning_words(fused)
        if result != expected:
            fail_gate(
                4,
                "Technical Word Preservation",
                f"Fused string '{fused}' expected '{expected}', got '{result}'",
            )
        print(f"  + Correctly split fused text: '{fused}' -> '{result}'")

    pass_gate(4, "Technical Word Preservation")


# ==============================================================================
# GATE 5: API MATRIX & SECURITY CONTRACT
# ==============================================================================
def gate_5_api_matrix():
    log_gate(5, "API Matrix & Security Contract")

    from fastapi.testclient import TestClient
    from app.main import app

    with TestClient(app) as client:
        # 1. Health check
        res = client.get("/api/health")
        if res.status_code != 200:
            fail_gate(5, "API Matrix", f"/api/health returned HTTP {res.status_code}")
        data = res.json()
        if data.get("status") != "ok" or data.get("database") not in ("ok", "reachable"):
            fail_gate(5, "API Matrix", f"/api/health invalid payload: {data}")
        print(f"  + /api/health: OK (DB: {data.get('database')}, Model: {data.get('model_status')})")

        # 2. Documents root
        res = client.get("/api/documents")
        if res.status_code != 200 or not isinstance(res.json(), list):
            fail_gate(5, "API Matrix", f"/api/documents failed: {res.status_code}")
        print(f"  + GET /api/documents: OK (returned list)")

        # 3. 404 contracts for nonexistent documents
        nonexistent_id = "nonexistent_doc_release_gate_test"

        # 3a. Force ingest nonexistent
        res = client.post(f"/api/documents/{nonexistent_id}/force-ingest")
        if res.status_code != 404:
            fail_gate(5, "API Matrix", f"Force ingest nonexistent doc returned {res.status_code}, expected 404")
        print(f"  + POST /api/documents/{nonexistent_id}/force-ingest: 404 (Expected)")

        # 3b. Vibe check nonexistent
        res = client.post(f"/api/documents/{nonexistent_id}/vibe-check", json={"chunk_index": 1})
        if res.status_code != 404:
            fail_gate(5, "API Matrix", f"Vibe check nonexistent doc returned {res.status_code}, expected 404")
        print(f"  + POST /api/documents/{nonexistent_id}/vibe-check: 404 (Expected)")

        # 3c. Delete nonexistent
        res = client.delete(f"/api/documents/{nonexistent_id}")
        if res.status_code != 404:
            fail_gate(5, "API Matrix", f"Delete nonexistent doc returned {res.status_code}, expected 404")
        print(f"  + DELETE /api/documents/{nonexistent_id}: 404 (Expected)")

        # 4. Context token header security on /api/ask/local
        ask_payload = {
            "document_id": "test_doc",
            "chunk_id": "test_chunk",
            "question": "What is the key takeaway?",
            "passage_text": "This is a test passage for release gate validation.",
        }
        res = client.post("/api/ask/local", json=ask_payload)
        if res.status_code not in (401, 403):
            fail_gate(5, "API Matrix", f"/api/ask/local without context token header returned {res.status_code}, expected 401/403")
        print(f"  + POST /api/ask/local without header: {res.status_code} (Unauthorized - Expected)")

        # 5. Query token must NOT be accepted (header only)
        res = client.post("/api/ask/local?token=bogus_query_token", json=ask_payload)
        if res.status_code not in (401, 403):
            fail_gate(5, "API Matrix", f"/api/ask/local with query token bypassed header check: {res.status_code}")
        print(f"  + POST /api/ask/local with query token rejected: {res.status_code} (Header Enforced)")

    pass_gate(5, "API Matrix & Security Contract")


# ==============================================================================
# GATE 6: PYTEST BACKEND SUITE
# ==============================================================================
def gate_6_pytest():
    log_gate(6, "Pytest Backend Test Suite")

    env = os.environ.copy()
    env["PYTHONPATH"] = BACKEND_DIR

    cmd = [VENV_PYTHON, "-m", "pytest", "tests", "-q"]
    print(f"  Running: {' '.join(cmd)} in {BACKEND_DIR}...")
    res = subprocess.run(cmd, cwd=BACKEND_DIR, env=env, capture_output=True, text=True)

    print(res.stdout)
    if res.returncode != 0:
        print(res.stderr)
        fail_gate(6, "Pytest Backend Test Suite", f"pytest exited with code {res.returncode}")

    pass_gate(6, "Pytest Backend Test Suite")


# ==============================================================================
# GATE 7: FLUTTER ANALYSIS & UNIT TESTS
# ==============================================================================
def gate_7_flutter():
    log_gate(7, "Flutter Analysis & Tests")

    # 1. flutter analyze
    cmd_analyze = [FLUTTER_BAT, "analyze"]
    print(f"  Running: {' '.join(cmd_analyze)} in {APP_DIR}...")
    res_analyze = subprocess.run(cmd_analyze, cwd=APP_DIR, capture_output=True, text=True)
    print(res_analyze.stdout)
    if res_analyze.returncode != 0 or "No issues found!" not in res_analyze.stdout:
        print(res_analyze.stderr)
        fail_gate(7, "Flutter Analysis", "flutter analyze found issues")
    print("  + flutter analyze: 0 issues")

    # 2. flutter test
    cmd_test = [FLUTTER_BAT, "test"]
    print(f"  Running: {' '.join(cmd_test)} in {APP_DIR}...")
    res_test = subprocess.run(cmd_test, cwd=APP_DIR, capture_output=True, text=True)
    print(res_test.stdout)
    if res_test.returncode != 0 or "All tests passed!" not in res_test.stdout:
        print(res_test.stderr)
        fail_gate(7, "Flutter Tests", "flutter test failed")
    print("  + flutter test: All tests passed!")

    pass_gate(7, "Flutter Analysis & Tests")


# ==============================================================================
# GATE 8: CORE INVARIANTS: LOSSLESS CHUNKING & EXACT-QUOTE ANCHORING
# ==============================================================================
def gate_8_invariants():
    log_gate(8, "Core Invariants: Lossless Chunking & Card Quote Anchoring")

    from app.services.ingestion.chunker import chunk_document
    from app.db import get_session
    from app.models import Document, ReadingChunk
    from fastapi.testclient import TestClient
    from app.main import app

    sample_corpora = [
        "Single sentence that should constitute a single chunk without any alteration.",
        "First sentence. Second sentence with some detail.\n\nParagraph two begins here with   irregular  spacing.\nAnd a newline.",
        "Code snippet:\n```python\ndef hello():\n    return 'world'\n```\nFollowed by trailing remarks.",
        "Special symbols: © 2026 Athena™ — «En vérité, la liberté d'esprit est primordiale». 100% lossless guaranteed.",
        ("Long prose block. " * 50) + "\n\n" + ("Second block with citations [1]. " * 40),
    ]

    for idx, text in enumerate(sample_corpora, 1):
        spans = [{"start": 0, "end": len(text), "page_start": 1, "page_end": 1}]
        chunks = chunk_document(f"test_doc_{idx}", text, spans)
        reconstructed = "".join(c["raw_text"] for c in chunks)
        if reconstructed != text:
            fail_gate(
                8,
                "Core Invariants",
                f"Sample {idx} violated lossless chunking! Reconstructed len: {len(reconstructed)}, original len: {len(text)}",
            )
        print(f"  + Sample {idx} (len={len(text)}): Reconstructed exactly across {len(chunks)} chunks.")

    with TestClient(app) as client:
        # Create a test document and chunk in SQLite to test real POST /api/cards/quote and /tape endpoints
        from app.db import engine
        from sqlmodel import Session

        with Session(engine) as session:
            test_doc = Document(
                id="doc_release_gate_test",
                filename="gate_test.txt",
                title="Gate Test Document",
                status="ready",
                chunk_count=1,
            )
            test_chunk = ReadingChunk(
                id="chunk_release_gate_test",
                document_id="doc_release_gate_test",
                sequence=1,
                raw_text="The quick brown fox jumps over the lazy dog in the late afternoon sun.",
                source_pages_json="[1]",
                start_offset=0,
                end_offset=len("The quick brown fox jumps over the lazy dog in the late afternoon sun."),
                checksum="chk_release_gate",
                boundary_method="sentence",
                canonical_sha256="testsha256",
            )
            session.merge(test_doc)
            session.merge(test_chunk)
            session.commit()

        # Real POST /api/cards/quote validation:
        # 1. Valid quote substring -> 200 OK
        valid_res = client.post(
            "/api/cards/quote",
            json={
                "document_id": "doc_release_gate_test",
                "chunk_id": "chunk_release_gate_test",
                "exact_quote": "the lazy dog",
                "body": "User noted this excerpt about the lazy dog.",
            },
        )
        if valid_res.status_code != 200:
            fail_gate(8, "Core Invariants", f"POST /api/cards/quote with valid substring failed: {valid_res.status_code} {valid_res.text}")
        print("  + Real POST /api/cards/quote verified with valid substring anchor (200 OK).")

        # 2. Invalid quote substring -> 422 Unprocessable Entity
        invalid_res = client.post(
            "/api/cards/quote",
            json={
                "document_id": "doc_release_gate_test",
                "chunk_id": "chunk_release_gate_test",
                "exact_quote": "the hyperactive cat",
                "body": "Hallucinated excerpt that does not exist in chunk.",
            },
        )
        if invalid_res.status_code != 422:
            fail_gate(8, "Core Invariants", f"POST /api/cards/quote with non-existent quote was not rejected with 422: {invalid_res.status_code}")
        print("  + Real POST /api/cards/quote rejected non-verbatim quote (422 QUOTE_NOT_IN_CHUNK).")

        # 3. Binary tape header check: magic bytes b"ATHN\x00\x00\x00\x01"
        tape_res = client.get("/api/documents/doc_release_gate_test/tape")
        if tape_res.status_code != 200:
            fail_gate(8, "Core Invariants", f"GET /api/documents/.../tape failed: {tape_res.status_code}")
        tape_bytes = tape_res.content
        expected_magic = b"ATHN\x00\x00\x00\x01"
        if not tape_bytes.startswith(expected_magic):
            fail_gate(8, "Core Invariants", f"Binary tape magic header mismatch! Expected prefix {expected_magic!r}, got {tape_bytes[:8]!r}")
        print("  + Binary tape header validated (magic: ATHN v1).")

    pass_gate(8, "Core Invariants")


# ==============================================================================
# MAIN ENTRYPOINT
# ==============================================================================
def main():
    print("*" * 70)
    print("        ATHENA RELEASE VERIFICATION GATE (verify_release.py)")
    print("*" * 70)

    gate_1_version_consistency()
    gate_2_static_grep()
    gate_3_cargo_test()
    gate_4_technical_words()
    gate_5_api_matrix()
    gate_6_pytest()
    gate_7_flutter()
    gate_8_invariants()

    print("=" * 70)
    if SKIPPED_GATES:
        print(f"  >>> {len(PASSED_GATES)} GATES PASSED, {len(SKIPPED_GATES)} HONESTLY SKIPPED <<<")
        for num, title, reason in SKIPPED_GATES:
            print(f"  * Gate {num}: {title} -> SKIPPED ({reason})")
    else:
        print("  >>> ALL 8 GATES PASSED! ATHENA IS 100% PRODUCTION READY <<<")
    print("=" * 70)
    sys.exit(0)


if __name__ == "__main__":
    main()
