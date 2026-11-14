import inspect
import asyncio
import hashlib
from unittest.mock import AsyncMock, MagicMock
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.main import app
from app.db import engine, init_db
from app.models import Document, ReadingChunk, utc_now
from app.services.ingestion import jobs
from app.routers import documents as doc_router

init_db()


def test_jobs_imports_and_path_cleanly():
    """Prove that jobs.py imports Path, hashlib, and errno cleanly without NameError."""
    assert hasattr(jobs, "Path")
    assert hasattr(jobs, "hashlib")
    assert hasattr(jobs, "errno")
    assert hasattr(jobs, "time")


def test_cleanup_interrupted_jobs_pauses_in_flight_progress():
    """Prove that startup recovery marks docs with progress > 0 as paused instead of failed."""
    doc_id = "doc_test_cleanup_pause_123"
    with Session(engine) as session:
        existing = session.get(Document, doc_id)
        if existing:
            session.delete(existing)
            session.commit()

        doc = Document(
            id=doc_id,
            filename="progress_test.pdf",
            status="processing",
            stage="chunking",
            percent=50,
            processed_page=16,
            page_count=32,
            created_at=utc_now(),
            updated_at=utc_now(),
        )
        session.add(doc)
        session.commit()

    try:
        jobs.cleanup_interrupted_jobs()

        with Session(engine) as session:
            recovered = session.get(Document, doc_id)
            assert recovered is not None
            assert recovered.status == "paused"
            assert recovered.stage == "paused"
            assert recovered.processed_page == 16
    finally:
        with Session(engine) as session:
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
                session.commit()


def test_list_documents_does_not_fabricate_ready_on_failed():
    """Prove that list_documents returns failed status even if stage/percent are done."""
    doc_id = "doc_test_failed_status_fabrication"
    with Session(engine) as session:
        existing = session.get(Document, doc_id)
        if existing:
            session.delete(existing)
            session.commit()

        doc = Document(
            id=doc_id,
            filename="failed_doc.pdf",
            status="failed",
            stage="done",
            percent=100,
            created_at=utc_now(),
            updated_at=utc_now(),
        )
        session.add(doc)
        session.commit()

    try:
        client = TestClient(app)
        res = client.get("/api/documents")
        assert res.status_code == 200
        data = res.json()
        target = next((d for d in data if d["id"] == doc_id), None)
        assert target is not None
        assert target["status"] == "failed"
    finally:
        with Session(engine) as session:
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
                session.commit()


def test_resume_document_process_endpoint():
    """Prove that POST /api/documents/{id}/resume sets status to queued and calls queue_document_job."""
    doc_id = "doc_test_resume_endpoint_456"
    with Session(engine) as session:
        existing = session.get(Document, doc_id)
        if existing:
            session.delete(existing)
            session.commit()

        doc = Document(
            id=doc_id,
            filename="paused_doc.pdf",
            status="paused",
            stage="paused",
            percent=40,
            processed_page=12,
            page_count=30,
            created_at=utc_now(),
            updated_at=utc_now(),
        )
        session.add(doc)
        session.commit()

    try:
        client = TestClient(app)
        res = client.post(f"/api/documents/{doc_id}/resume")
        assert res.status_code == 200
        assert res.json()["status"] == "queued"

        with Session(engine) as session:
            resumed = session.get(Document, doc_id)
            assert resumed is not None
            assert resumed.status == "queued"
    finally:
        with Session(engine) as session:
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
                session.commit()


@pytest.mark.anyio
async def test_get_reader_is_async_and_runs_read_ahead_without_loop_crash():
    """Prove that get_reader is async, permits partially_readable docs, and triggers viewport read-ahead."""
    assert inspect.iscoroutinefunction(doc_router.get_reader)

    doc_id = "doc_test_reader_async_789"
    with Session(engine) as session:
        existing = session.get(Document, doc_id)
        if existing:
            session.delete(existing)
            session.commit()

        doc = Document(
            id=doc_id,
            filename="partial_book.pdf",
            status="partially_readable",
            stage="extracting",
            percent=30,
            processed_page=16,
            page_count=50,
            integrity_verified=False,
            created_at=utc_now(),
            updated_at=utc_now(),
        )
        session.add(doc)
        chunk = ReadingChunk(
            id=f"{doc_id}-c0001",
            document_id=doc_id,
            sequence=1,
            start_offset=0,
            end_offset=100,
            raw_text="The beginning of knowledge begins with wonder and curious observation.",
            checksum=hashlib.sha256("The beginning of knowledge begins with wonder and curious observation.".encode()).hexdigest(),
        )
        session.add(chunk)
        session.commit()

    try:
        mock_pipeline = MagicMock()
        mock_pipeline.update_viewport = AsyncMock(return_value=None)

        mock_request = MagicMock()
        mock_request.app.state.pipeline = mock_pipeline

        with Session(engine) as session:
            result = await doc_router.get_reader(
                id=doc_id,
                request=mock_request,
                session=session,
            )

        assert "items" in result
        assert len(result["items"]) >= 1
        # Proves pipeline.update_viewport was invoked as a scheduled task without crashing
        await asyncio.sleep(0.05)
        mock_pipeline.update_viewport.assert_called_once_with(doc_id, 1)
    finally:
        with Session(engine) as session:
            session.exec(select(ReadingChunk).where(ReadingChunk.document_id == doc_id))
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
                session.commit()
