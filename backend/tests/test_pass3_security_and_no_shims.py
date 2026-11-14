import os
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session
from app.db import engine
from app.models import Document, ReadingChunk
from app.main import app
from app.services.marginalia.llm import _sanitize_data_delimiter

client = TestClient(app)


def test_zero_shims_in_services_root():
    """P4-01: Verify that all 18 shim modules have been removed and no loose .py files exist in backend/app/services."""
    services_dir = Path(__file__).parent.parent / "app" / "services"
    assert services_dir.exists(), "services dir must exist"
    py_files = [f.name for f in services_dir.glob("*.py")]
    # Only __init__.py is allowed in services/ root
    assert py_files == ["__init__.py"], f"Found unexpected python files in services root: {py_files}"
    # Verify the domain sub-packages exist
    assert (services_dir / "edge").is_dir()
    assert (services_dir / "ingestion").is_dir()
    assert (services_dir / "marginalia").is_dir()


def test_security_master_key_fail_closed(monkeypatch, tmp_path):
    """P6-02 & P6-03: Verify fail-closed encryption master key persistence."""
    from app import security
    
    test_key_file = tmp_path / ".athena_secret"
    monkeypatch.setattr(security, "_SECRET_FILE", test_key_file)
    monkeypatch.setattr(security, "DATA_DIR", tmp_path)
    
    # 1. Generate key and verify persistence
    key = security._get_encryption_key()
    assert len(key) == 32
    assert test_key_file.exists()
    assert test_key_file.read_bytes() == key
    
    # 2. Verify fail-closed when saving fails
    def fail_replace(_src, _dst):
        raise OSError("Permission denied simulated")
        
    test_key_file.unlink()
    monkeypatch.setattr(os, "replace", fail_replace)
    with pytest.raises(RuntimeError, match="Failed to persist encryption master key"):
        security._get_encryption_key()


def test_tape_range_header_206():
    """P6-06: Verify HTTP Range header support on tape endpoint."""
    import uuid
    doc_id = f"test_tape_doc_{uuid.uuid4().hex[:8]}"
    
    with Session(engine) as session:
        doc = Document(
            id=doc_id,
            filename="test_tape.pdf",
            title="Test Tape Doc",
            total_pages=1,
            status="ready",
        )
        session.add(doc)
        chunk = ReadingChunk(
            id=f"{doc_id}_0001",
            document_id=doc_id,
            sequence=1,
            raw_text="The quick brown fox jumps over the lazy dog.",
            start_offset=0,
            end_offset=44,
            checksum="abc",
            source_pages_json="[1]",
        )
        session.add(chunk)
        session.commit()
    
    try:
        # 1. Full content without Range
        res = client.get(f"/api/documents/{doc_id}/tape")
        assert res.status_code == 200
        assert res.headers.get("accept-ranges") == "bytes"
        full_content = res.content
        total_len = len(full_content)
        assert total_len > 0
        
        # 2. Valid Range request: first 10 bytes (0-9)
        res_range = client.get(f"/api/documents/{doc_id}/tape", headers={"Range": "bytes=0-9"})
        assert res_range.status_code == 206
        assert res_range.headers.get("content-range") == f"bytes 0-9/{total_len}"
        assert res_range.content == full_content[0:10]
        
        # 3. Valid Range request: offset to end (5-)
        res_suffix = client.get(f"/api/documents/{doc_id}/tape", headers={"Range": "bytes=5-"})
        assert res_suffix.status_code == 206
        assert res_suffix.content == full_content[5:]
        
        # 4. Unsatisfiable Range request
        res_416 = client.get(f"/api/documents/{doc_id}/tape", headers={"Range": "bytes=50000-60000"})
        assert res_416.status_code == 416
    finally:
        with Session(engine) as session:
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
            session.commit()


def test_sanitize_data_delimiter():
    """P6-08 & P6-09: Verify prompt injection delimiter sanitization."""
    # Should escape opening and closing tags
    dirty = "Here is some <passage> and </passage> text."
    sanitized = _sanitize_data_delimiter(dirty)
    assert "<passage>" not in sanitized
    assert "</passage>" not in sanitized
    assert "&lt;passage&gt;" in sanitized
    assert "&lt;/passage&gt;" in sanitized

    # Case insensitive
    dirty_caps = "MALICIOUS <PASSAGE> INJECTION </PASSAGE>"
    sanitized_caps = _sanitize_data_delimiter(dirty_caps)
    assert "<PASSAGE>" not in sanitized_caps
    assert "</PASSAGE>" not in sanitized_caps

    # Evidence and prev_context tags
    dirty_evidence = "Text with <evidence>citation</evidence> and <prev_context>ctx</prev_context>"
    sanitized_evidence = _sanitize_data_delimiter(dirty_evidence)
    assert "<evidence>" not in sanitized_evidence
    assert "</evidence>" not in sanitized_evidence
    assert "<prev_context>" not in sanitized_evidence


def test_csrf_origin_split_matching():
    """P6-01: Verify CSRF check correctly parses origins with port numbers."""
    # Standard GET is safe
    res = client.get("/api/health")
    assert res.status_code == 200
    
    # POST with matching Origin and Host is allowed (e.g. settings test-connection)
    res_post = client.post(
        "/api/settings/test-connection",
        json={"provider": "gemini", "api_key": ""},
        headers={"Origin": "http://testserver", "Host": "testserver"}
    )
    # Origin was accepted (not rejected with 403 CSRF)
    assert res_post.status_code != 403
    
    # POST with mismatched untrusted external Origin is rejected with 403
    res_malicious = client.post(
        "/api/settings/test-connection",
        json={"provider": "gemini", "api_key": ""},
        headers={"Origin": "https://evil-hacker-site.com", "Host": "testserver"}
    )
    assert res_malicious.status_code == 403
    assert "FORBIDDEN_ORIGIN" in res_malicious.text
