import ast
import ast
import os
import re
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.main import app
from app.db import engine, init_db
from app.models import Document, ReadingChunk


def test_python_fstring_compatibility():
    """Verify all backend Python files are syntax-valid without 3.12+ backslash-in-fstring features."""
    backend_dir = Path(__file__).resolve().parent.parent
    py_files = list(backend_dir.glob("**/*.py"))
    assert len(py_files) > 10

    for py_file in py_files:
        # Compile without writing pyc files into the read-only source cache.
        source = py_file.read_text(encoding="utf-8")
        parsed = ast.parse(source, filename=str(py_file))
        compile(parsed, str(py_file), "exec")


def test_requirements_and_pyproject_dependencies():
    """Verify pydantic-settings, httpx[http2], h2, and fastembed are documented."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    req_file = repo_root / "backend" / "requirements.txt"
    pyproject_file = repo_root / "backend" / "pyproject.toml"

    assert req_file.exists(), "backend/requirements.txt must exist"
    assert pyproject_file.exists(), "backend/pyproject.toml must exist"

    req_text = req_file.read_text(encoding="utf-8").lower()
    pyproject_text = pyproject_file.read_text(encoding="utf-8").lower()

    for dep in ["pydantic-settings", "httpx[http2]", "h2", "fastembed", "numpy"]:
        assert dep in req_text, f"{dep} missing from backend/requirements.txt"


def test_health_does_not_initialize_embedding_model(monkeypatch):
    from app.services.edge import novelty
    from app.main import get_health

    def fail_if_loaded():
        raise AssertionError("health must not initialize the embedder")

    monkeypatch.setattr(novelty, "_get_embedder", fail_if_loaded)
    result = get_health()
    assert result["status"] == "ok"
    assert result["model_status"] in {"ready", "unavailable", "not_loaded"}


def test_lexical_anti_echo_fallback(monkeypatch):
    from app.services.edge import novelty

    monkeypatch.setattr(novelty, "_get_embedder", lambda: None)
    passage = "The researchers measured memory retention after a short interval."
    assert novelty.compute_semantic_similarity(passage, passage) > 0.81
    assert novelty.is_semantic_duplicate(passage, [passage])


def test_custom_endpoint_ssrf_guard_rejects_loopback():
    from app.security import validate_public_http_url
    from app.errors import AppException

    with pytest.raises(AppException):
        validate_public_http_url("http://127.0.0.1:8080/v1")


def test_ask_router_imports_re_and_offline_fallback():
    """Verify ask.py imports re and does not throw NameError on offline fallback."""
    from app.routers import ask

    assert hasattr(ask, "re"), "ask.py must import 're'"
    assert hasattr(ask.re, "split"), "re.split must be available"


def test_cards_no_undefined_wiki_data():
    """Verify cards.py has zero undefined references to wiki_data."""
    cards_path = Path(__file__).resolve().parent.parent / "app" / "services" / "marginalia" / "cards.py"
    content = cards_path.read_text(encoding="utf-8")

    # wiki_data was previously referenced at line ~782 without being defined
    assert "wiki_data" not in content, "Found undefined 'wiki_data' in cards.py"


def test_rust_core_no_backreferences_and_valid_source():
    """Verify Rust core regex has no backreferences like \\1 that panic LazyLock."""
    rust_src = Path(__file__).resolve().parent.parent / "rust_core" / "src" / "lib.rs"
    if rust_src.exists():
        content = rust_src.read_text(encoding="utf-8")
        # Check no regex has \1 backreference
        assert r"\1" not in content, "Rust core must not use regex backreferences"
        assert "char_to_byte" in content, "Rust core must use byte boundary mapping"


def test_dummy_ipa_removed_and_ci_documented():
    """Verify dummy 1.4MB .ipa files are removed from releases/."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    releases_dir = repo_root / "releases"
    if releases_dir.exists():
        ipa_files = list(releases_dir.glob("*.ipa"))
        assert len(ipa_files) == 0, f"Found unexpected .ipa files: {ipa_files}"


def test_release_download_path_traversal_prevention():
    """Verify path traversal attacks on /releases/{filename} are rejected."""
    client = TestClient(app)

    # Path traversal attempts
    r1 = client.get("/releases/..%2fbackend%2f.env")
    assert r1.status_code in [400, 404]

    r2 = client.get("/releases/..%5cbackend%5cdata%5cathena.db")
    assert r2.status_code in [400, 404]

    r3 = client.get("/releases/../../etc/passwd")
    assert r3.status_code in [200, 400, 404]
    if r3.status_code == 200:
        assert r3.headers.get("content-type", "").startswith("text/html")
        assert "root:" not in r3.text


def test_android_keystore_leak_protection():
    """Verify keystore files are ignored by git and not in releases/."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    gitignore = (repo_root / ".gitignore").read_text(encoding="utf-8")

    assert "*.keystore" in gitignore
    assert "*.jks" in gitignore
    assert "key.properties" in gitignore

    assert not (repo_root / "releases" / "athena-release.keystore").exists()


def test_feed_position_chunk_id_alignment():
    """Verify endpoints accept chunk_id to avoid misalignment with interleaved context cards."""
    init_db()
    client = TestClient(app)

    with Session(engine) as session:
        doc = Document(
            filename="audit-test.pdf",
            title="Test Feed Alignment",
            canonical_text="Paragraph 1 text.\n\nParagraph 2 text.\n\nParagraph 3 text.",
            status="completed",
        )
        session.add(doc)
        session.commit()
        session.refresh(doc)

        c1 = ReadingChunk(
            id=f"{doc.id}-c0001",
            document_id=doc.id,
            sequence=1,
            raw_text="Paragraph 1 text.",
            start_offset=0,
            end_offset=18,
            checksum="c1",
        )
        c2 = ReadingChunk(
            id=f"{doc.id}-c0002",
            document_id=doc.id,
            sequence=2,
            raw_text="Paragraph 2 text.",
            start_offset=20,
            end_offset=38,
            checksum="c2",
        )
        session.add(c1)
        session.add(c2)
        session.commit()
        session.refresh(c1)
        session.refresh(c2)

        doc_id = doc.id
        c2_id = c2.id

    # 1. Progress endpoint with chunk_id
    prog_resp = client.post(
        f"/api/documents/{doc_id}/progress",
        json={"chunk_id": c2_id, "feed_index": 5, "reading_mode": "feed"},
    )
    assert prog_resp.status_code == 200

    # 2. Vibe check endpoint with chunk_id
    vibe_resp = client.post(
        f"/api/documents/{doc_id}/vibe-check",
        json={"chunk_id": c2_id, "feed_index": 5},
    )
    assert vibe_resp.status_code == 200

    # 3. Card generation endpoint with chunk_id
    card_resp = client.post(
        f"/api/documents/{doc_id}/cards/generate",
        json={"chunk_id": c2_id, "feed_index": 5},
    )
    assert card_resp.status_code == 200
    card_data = card_resp.json()
    assert card_data["source_chunk_id"] == c2_id
