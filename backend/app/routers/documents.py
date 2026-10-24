import asyncio
import errno
import json
import logging
from pathlib import Path
import re
import shutil
import uuid
from typing import Any, Dict, List
from fastapi import APIRouter, Depends, File, Request, UploadFile, status
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel
from sqlmodel import Session, select
import pymupdf

from app.config import (
    BASE_DIR,
    RAW_DIR,
    UPLOADS_DIR,
)
from app.db import get_session
from app.errors import AppException
from app.models import Document, ReadingChunk, Concept, ContextCard, DocumentChapter, ReadingState, utc_now
from app.services.extraction import sanitize_filename, validate_pdf_file, get_document_file_path
from app.services.jobs import queue_document_job, reset_and_requeue_document, force_requeue_document
from app.services.llm import LLMService

router = APIRouter(prefix="/api/documents", tags=["documents"])
logger = logging.getLogger(__name__)

STAGE_LABELS: Dict[str, str] = {
    "validating": "Reading PDF",
    "extracting": "Extracting text",
    "cleaning": "Preserving page order",
    "chunking": "Creating reading chunks",
    "verifying": "Verifying integrity",
    "finding_concepts": "Finding useful concepts",
    "preparing_context": "Preparing context",
    "done": "Ready",
}


@router.post("/upload")
async def upload_document(
    file: UploadFile = File(...),
    session: Session = Depends(get_session),
) -> Dict[str, str]:
    """Streams a book PDF or EPUB to local disk and queues sequential processing."""
    original_filename = file.filename or "document.pdf"
    ext = Path(original_filename).suffix.lower()

    # 1. Extension check (.pdf and .epub case-insensitive)
    if ext not in (".pdf", ".epub"):
        raise AppException("UNSUPPORTED_FILE")

    doc_id = uuid.uuid4().hex
    target_path = UPLOADS_DIR / f"{doc_id}{ext}"
    # 2. Stream directly to disk in bounded pieces; avoid a fixed file-size cap.
    try:
        with open(target_path, "wb") as f:
            while chunk := await file.read(64 * 1024):
                f.write(chunk)
    except OSError as e:
        if target_path.exists():
            target_path.unlink()
        if e.errno == errno.ENOSPC:
            raise AppException("RESOURCE_LIMIT") from e
        raise
    except Exception:
        if target_path.exists():
            target_path.unlink()
        raise

    # 3. Validation: magic bytes and PyMuPDF inspection
    try:
        page_count = validate_pdf_file(target_path)
    except AppException:
        if target_path.exists():
            target_path.unlink()
        raise
    except Exception:
        if target_path.exists():
            target_path.unlink()
        raise

    # 4. Create Document record
    doc = Document(
        id=doc_id,
        filename=sanitize_filename(original_filename),
        title=Path(original_filename).stem,
        status="queued",
        stage="validating",
        percent=5,
        page_count=page_count,
        created_at=utc_now(),
        updated_at=utc_now(),
    )
    session.add(doc)
    session.commit()

    # 5. Dispatch background extraction
    queue_document_job(doc_id)

    return {"document_id": doc_id}


@router.post("/sample")
def load_sample_document(session: Session = Depends(get_session)) -> Dict[str, str]:
    """Loads and queues the bundled sample document for immediate explore."""
    sample_pdf = BASE_DIR / "samples" / "sample.pdf"
    if not sample_pdf.exists():
        raise AppException("NOT_FOUND", "Bundled sample PDF not found", status_code=404)

    doc_id = uuid.uuid4().hex
    target_path = UPLOADS_DIR / f"{doc_id}.pdf"
    shutil.copy2(sample_pdf, target_path)

    try:
        page_count = validate_pdf_file(target_path)
    except Exception:
        if target_path.exists():
            target_path.unlink()
        raise


    doc = Document(
        id=doc_id,
        filename="sample.pdf",
        title="Introduction to Cellular Respiration",
        status="queued",
        stage="validating",
        percent=5,
        page_count=page_count,
        created_at=utc_now(),
        updated_at=utc_now(),
    )
    session.add(doc)
    session.commit()

    queue_document_job(doc_id)
    return {"document_id": doc_id}


@router.get("")
def list_documents(session: Session = Depends(get_session)) -> List[Dict[str, Any]]:
    """Returns list of all documents, newest first (§10 in CLAUDE.md)."""
    statement = select(Document).order_by(Document.created_at.desc())
    docs = session.exec(statement).all()
    results = []
    for d in docs:
        effective_status = d.status
        if effective_status != "ready" and effective_status != "failed":
            chunk_exists = session.exec(select(ReadingChunk.id).where(ReadingChunk.document_id == d.id)).first()
            if chunk_exists:
                effective_status = "ready"
                d.status = "ready"
                session.add(d)
                try:
                    session.commit()
                except Exception:
                    session.rollback()
        results.append({
            "id": d.id,
            "title": d.title or d.filename,
            "filename": d.filename,
            "status": effective_status,
            "stage": d.stage,
            "stage_label": STAGE_LABELS.get(d.stage, "Processing..."),
            "percent": d.percent,
            "error_code": d.error_code,
            "error_message": d.error_message,
            "page_count": d.page_count,
            "layout_warning": d.layout_warning,
            "context_status": d.context_status,
            "created_at": d.created_at.isoformat(),
            "updated_at": d.updated_at.isoformat(),
        })
    return results


@router.get("/{id}")
def get_document(id: str, session: Session = Depends(get_session)) -> Dict[str, Any]:
    """Returns metadata for a specific document."""
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)
    effective_status = doc.status
    if effective_status != "ready" and effective_status != "failed":
        if session.exec(select(ReadingChunk.id).where(ReadingChunk.document_id == doc.id)).first():
            effective_status = "ready"
            doc.status = "ready"
            session.add(doc)
            try:
                session.commit()
            except Exception:
                session.rollback()
    return {
        "id": doc.id,
        "title": doc.title,
        "filename": doc.filename,
        "status": effective_status,
        "stage": doc.stage,
        "percent": doc.percent,
        "page_count": doc.page_count,
        "layout_warning": doc.layout_warning,
        "context_status": doc.context_status,
        "created_at": doc.created_at.isoformat(),
        "updated_at": doc.updated_at.isoformat(),
    }


@router.get("/{id}/status")
def get_document_status(id: str, session: Session = Depends(get_session)) -> Dict[str, Any]:
    """Returns status polling payload (§10 in CLAUDE.md)."""
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)

    effective_status = doc.status
    if effective_status not in {"ready", "failed", "unsupported"}:
        if session.exec(select(ReadingChunk.id).where(ReadingChunk.document_id == doc.id)).first():
            effective_status = "ready"
            doc.status = "ready"
            session.add(doc)
            try:
                session.commit()
            except Exception:
                session.rollback()

    error_obj = None
    if doc.error_code:
        error_obj = {
            "code": doc.error_code,
            "message": doc.error_message or "",
        }

    return {
        "document_id": doc.id,
        "status": effective_status,
        "stage": doc.stage,
        "stage_label": STAGE_LABELS.get(doc.stage, "Processing..."),
        "percent": doc.percent,
        "error": error_obj,
        "context_status": doc.context_status,
    }


@router.post("/{id}/process")
def retry_document_process(id: str, session: Session = Depends(get_session)) -> Dict[str, str]:
    """Retries processing for a failed document (§10 in CLAUDE.md)."""
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)
    if doc.status != "failed":
        raise AppException("CONFLICT", "Only failed documents can be retried", status_code=409)

    reset_and_requeue_document(id)
    return {"status": "queued", "document_id": id}


@router.post("/{id}/force-ingest")
def force_ingest_document(id: str, session: Session = Depends(get_session)) -> Dict[str, str]:
    """Force-bypasses the Stage-0 Document Bouncer to read any document (§Stage-0 in CLAUDE.md)."""
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)
    force_requeue_document(id)
    return {"status": "queued", "document_id": id}



@router.delete("/{id}")
def delete_document(id: str, session: Session = Depends(get_session)) -> Dict[str, str]:
    """Deletes document rows and physical disk files."""
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)
    if doc.status in {"queued", "processing"}:
        raise AppException(
            "CONFLICT",
            "A document cannot be deleted while it is processing.",
            status_code=409,
        )

    # Delete related database items
    for chunk in session.exec(select(ReadingChunk).where(ReadingChunk.document_id == id)).all():
        session.delete(chunk)
    for concept in session.exec(select(Concept).where(Concept.document_id == id)).all():
        session.delete(concept)
    for card in session.exec(select(ContextCard).where(ContextCard.document_id == id)).all():
        session.delete(card)
    for chapter in session.exec(select(DocumentChapter).where(DocumentChapter.doc_id == id)).all():
        session.delete(chapter)
    state = session.get(ReadingState, id)
    if state:
        session.delete(state)

    session.delete(doc)
    session.commit()


    # Clean disk files
    for ext in (".pdf", ".epub"):
        p = UPLOADS_DIR / f"{id}{ext}"
        if p.exists():
            p.unlink()
    raw_path = RAW_DIR / f"{id}.txt"
    if raw_path.exists():
        raw_path.unlink()

    return {"status": "deleted", "document_id": id}


@router.post("/sample")
def load_sample_document(session: Session = Depends(get_session)) -> Dict[str, str]:
    """Copies sample.pdf into pipeline as a normal document (§10 in CLAUDE.md)."""
    sample_candidates = [
        BASE_DIR / "samples" / "sample.pdf",
        BASE_DIR.parent / "backend" / "samples" / "sample.pdf",
        BASE_DIR / "backend" / "samples" / "sample.pdf",
    ]

    sample_src = next((p for p in sample_candidates if p.exists()), None)
    if not sample_src:
        raise AppException("NOT_FOUND", "Sample document is missing from samples/sample.pdf", status_code=404)

    doc_id = uuid.uuid4().hex
    target_path = UPLOADS_DIR / f"{doc_id}.pdf"
    shutil.copyfile(sample_src, target_path)

    page_count = validate_pdf_file(target_path)
    doc = Document(
        id=doc_id,
        filename="sample.pdf",
        title="Sample Document",
        status="queued",
        stage="validating",
        percent=5,
        page_count=page_count,
        created_at=utc_now(),
        updated_at=utc_now(),
    )
    session.add(doc)
    session.commit()

    queue_document_job(doc_id)
    return {"document_id": doc_id}


@router.get("/{id}/reader")
def get_reader(
    id: str,
    session: Session = Depends(get_session),
) -> Dict[str, Any]:
    """
    Returns the full reader payload (§10 in CLAUDE.md):
    document metadata with integrity proof + ordered items
    (reading chunks interleaved with context cards, once Phase 5 is wired).
    """
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)
    if doc.status != "ready":
        raise AppException("CONFLICT", "Document is not ready", status_code=409)

    # Fetch chunks ordered by sequence
    chunks = session.exec(
        select(ReadingChunk)
        .where(ReadingChunk.document_id == id)
        .order_by(ReadingChunk.sequence)
    ).all()

    # Build integrity proof
    integrity = {
        "verified": doc.integrity_verified,
        "original_checksum": doc.original_checksum,
        "reconstructed_checksum": doc.reconstructed_checksum,
        "chunk_count": len(chunks),
    }

    # Fetch active (non-dismissed) context cards for this document
    cards = session.exec(
        select(ContextCard)
        .where(ContextCard.document_id == id, ContextCard.dismissed == False)
    ).all()

    cards_by_chunk: Dict[str, List[ContextCard]] = {}
    for card in cards:
        cards_by_chunk.setdefault(card.source_chunk_id, []).append(card)

    # Build items list: reading chunks interleaved with context cards (§10 in CLAUDE.md)
    items: List[Dict[str, Any]] = []
    for chunk in chunks:
        pages = json.loads(chunk.source_pages_json) if chunk.source_pages_json else []
        if len(pages) == 1:
            page_ref = f"Page {pages[0]}"
        elif len(pages) >= 2:
            page_ref = f"Pages {pages[0]}\u2013{pages[-1]}"
        else:
            page_ref = "Page 1"

        items.append({
            "type": "reading_chunk",
            "id": chunk.id,
            "sequence": chunk.sequence,
            "text": chunk.raw_text,
            "page_reference": page_ref,
            "section_title": chunk.section_title,
            "boundary_method": getattr(chunk, "boundary_method", "paragraph"),
        })

        for card in cards_by_chunk.get(chunk.id, []):
            citations = []
            if card.citations_json:
                try:
                    citations = json.loads(card.citations_json)
                except Exception:
                    pass
            items.append({
                "type": "context_card",
                "id": card.id,
                "insert_after": card.source_chunk_id,
                "card_type": card.card_type,
                "title": card.title,
                "body": card.body,
                "why_here": card.why_here,
                "exact_quote": card.exact_quote,
                "support_status": getattr(card, "support_status", "fully_supported"),
                "generation_mode": card.generation_mode,
                "saved": card.saved,
                "citations": citations,
            })

    reading_state = session.get(ReadingState, id)
    saved_chunk_index = reading_state.current_chunk_index if reading_state else None
    saved_reading_mode = reading_state.reading_mode if reading_state else None

    return {
        "document": {
            "id": doc.id,
            "title": doc.title,
            "page_count": doc.page_count,
            "layout_warning": doc.layout_warning,
            "context_status": doc.context_status,
            "integrity": integrity,
            "current_chunk_index": saved_chunk_index,
            "reading_mode": saved_reading_mode,
        },
        "items": items,
    }


@router.get("/{id}/search")
def search_document(
    id: str,
    q: str = "",
    top_k: int = 5,
    session: Session = Depends(get_session),
) -> Dict[str, Any]:
    """
    Runs Hybrid Intelligent Search (BM25 + Dense + RRF k=60) over verified document chunks.
    """
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)

    query = q.strip()
    if not query:
        return {"document_id": id, "query": "", "results": []}

    chunks = session.exec(
        select(ReadingChunk).where(ReadingChunk.document_id == id).order_by(ReadingChunk.sequence)
    ).all()

    if not chunks:
        return {"document_id": id, "query": query, "results": []}

    from app.services.search import HybridSearchService
    search_svc = HybridSearchService(chunks)
    results = search_svc.search(query=query, top_k=top_k)

    return {
        "document_id": id,
        "query": query,
        "results": results,
    }


@router.get("/{id}/pages/{n}/image")
def get_page_image(
    id: str,
    n: int,
    session: Session = Depends(get_session),
) -> Response:
    """
    Returns a PNG image of page N (1-indexed) at 110 DPI (§10 in CLAUDE.md).
    Uses ``page.get_pixmap(dpi=110)`` via PyMuPDF.
    """
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)

    if n < 1 or n > doc.page_count:
        raise AppException(
            "NOT_FOUND",
            f"Page {n} does not exist (document has {doc.page_count} pages)",
            status_code=404,
        )

    file_path = get_document_file_path(id)
    if not file_path.exists():
        raise AppException("NOT_FOUND", "Document file not found on disk", status_code=404)

    try:
        with pymupdf.open(file_path) as pdf_doc:
            page = pdf_doc[n - 1]  # 0-indexed
            rect = page.rect
            dpi = 110
            estimated_pixels = (rect.width * dpi / 72) * (rect.height * dpi / 72)
            max_pixels = 12_000_000
            if estimated_pixels > max_pixels:
                dpi = max(1, int(dpi * (max_pixels / estimated_pixels) ** 0.5))
            if (rect.width * dpi / 72) * (rect.height * dpi / 72) > max_pixels:
                raise AppException("RESOURCE_LIMIT")
            pixmap = page.get_pixmap(dpi=dpi, alpha=False)
            png_bytes = pixmap.tobytes(output="png")
    except AppException:
        raise
    except Exception as e:
        logger.exception("Failed to render page %s of document %s", n, id)
        raise AppException("INTERNAL") from e

    return Response(
        content=png_bytes,
        media_type="image/png",
        headers={"Cache-Control": "private, max-age=3600"},
    )


class ProgressUpdate(BaseModel):
    chunk_index: int
    reading_mode: str = "feed"


@router.post("/{id}/progress")
async def sync_reading_progress(
    id: str,
    payload: ProgressUpdate,
    request: Request,
    session: Session = Depends(get_session),
) -> Dict[str, Any]:
    """
    1. Saves exact reading position to SQLite WAL (syncs Web <-> Android).
    2. Triggers the Read-Ahead Priority Pipeline for [chunk_index, chunk_index + 16].
    """
    try:
        state = session.get(ReadingState, id)
        if not state:
            state = ReadingState(
                doc_id=id,
                current_chunk_index=payload.chunk_index,
                reading_mode=payload.reading_mode,
                updated_at=utc_now(),
            )
            session.add(state)
        else:
            state.current_chunk_index = payload.chunk_index
            state.reading_mode = payload.reading_mode
            state.updated_at = utc_now()
            session.add(state)
        session.commit()
    except Exception as err:
        logger.warning("Error persisting reading state: %s", err)

    try:
        pipeline = getattr(request.app.state, "pipeline", None)
        if pipeline:
            asyncio.create_task(pipeline.update_viewport(id, payload.chunk_index))
    except Exception as err:
        logger.warning("Error updating pipeline viewport: %s", err)

    cards = session.exec(
        select(ContextCard).where(
            ContextCard.document_id == id,
            ContextCard.dismissed == False,
        )
    ).all()
    in_flight = pipeline.get_in_flight_indices(id) if pipeline else []

    cards_data = []
    for card in cards:
        citations = []
        if card.citations_json:
            try:
                citations = json.loads(card.citations_json)
            except Exception:
                citations = []
        seq_num = None
        if card.source_chunk_id:
            m = re.search(r"-c(\d+)$", card.source_chunk_id)
            if m:
                seq_num = int(m.group(1))

        cards_data.append({
            "type": "context_card",
            "id": card.id,
            "source_chunk_id": card.source_chunk_id,
            "insert_after": card.source_chunk_id,
            "seq_num": seq_num,
            "sequence": seq_num,
            "card_type": card.card_type,
            "title": card.title,
            "body": card.body,
            "why_here": card.why_here,
            "exact_quote": card.exact_quote,
            "support_status": getattr(card, "support_status", "fully_supported"),
            "generation_mode": card.generation_mode,
            "saved": card.saved,
            "citations": citations,
        })

    return {
        "status": "ok",
        "prefetched_from": payload.chunk_index,
        "in_flight": in_flight,
        "cards": cards_data,
    }


@router.get("/{id}/events")
async def stream_document_events(id: str, request: Request):
    """
    Server-Sent Events (SSE) stream: pushes newly grounded Context Cards
    to Flutter the millisecond they pass validation.
    """
    pipeline = getattr(request.app.state, "pipeline", None)
    if not pipeline:
        raise AppException("INTERNAL", "Pipeline not initialized")

    client_queue: asyncio.Queue = asyncio.Queue()
    pipeline.subscribers.setdefault(id, set()).add(client_queue)

    async def event_generator():
        try:
            while True:
                if await request.is_disconnected():
                    break
                try:
                    event = await asyncio.wait_for(client_queue.get(), timeout=15.0)
                    yield f"data: {json.dumps(event)}\n\n"
                except asyncio.TimeoutError:
                    yield ": heartbeat\n\n"
        finally:
            subs = pipeline.subscribers.get(id)
            if subs:
                subs.discard(client_queue)

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.get("/{id}/chapters")
def get_document_chapters(
    id: str, session: Session = Depends(get_session)
) -> List[Dict[str, Any]]:
    """Returns Table of Contents mapped directly to chunk sequence indices."""
    chapters = session.exec(
        select(DocumentChapter)
        .where(DocumentChapter.doc_id == id)
        .order_by(DocumentChapter.start_chunk_index, DocumentChapter.id)
    ).all()
    if chapters:
        return [
            {
                "id": ch.id,
                "level": ch.level,
                "title": ch.title,
                "start_page": ch.start_page,
                "start_chunk_index": ch.start_chunk_index,
            }
            for ch in chapters
        ]

    # Auto-detect chapters from chunk text when no PDF outline exists
    import re
    chunks = session.exec(
        select(ReadingChunk)
        .where(ReadingChunk.document_id == id)
        .order_by(ReadingChunk.sequence)
    ).all()
    if not chunks:
        return []

    heading_pattern = re.compile(
        r"^(?:CHAPTER\s+[\dIVXLCDM]+[^\r\n]*|PART\s+[\dIVXLCDM]+[^\r\n]*|ACT\s+[\dIVXLCDM]+[^\r\n]*|BOOK\s+[\dIVXLCDM]+[^\r\n]*|INTRODUCTION[^\r\n]*|PROLOGUE[^\r\n]*|EPILOGUE[^\r\n]*|SECTION\s+[\dIVXLCDM]+[^\r\n]*|#\s+[^\r\n]+)",
        re.IGNORECASE,
    )
    detected = []
    for chunk in chunks:
        raw = (chunk.raw_text or "").strip()
        first_line = raw.split("\n")[0].strip() if raw else ""
        m = heading_pattern.match(first_line)
        if m:
            clean_title = m.group(0).lstrip("#").strip()
            page = 1
            if chunk.source_pages_json and isinstance(chunk.source_pages_json, list) and chunk.source_pages_json:
                page = chunk.source_pages_json[0]
            detected.append({
                "id": chunk.id,
                "level": 1,
                "title": clean_title,
                "start_page": max(0, page - 1),
                "start_chunk_index": chunk.sequence,
            })

    if detected:
        return detected

    # Fallback to logical section checkpoints for long documents (>10 chunks)
    if len(chunks) > 10:
        step = max(8, len(chunks) // 8)
        for i in range(0, len(chunks), step):
            chunk = chunks[i]
            page = 1
            if chunk.source_pages_json and isinstance(chunk.source_pages_json, list) and chunk.source_pages_json:
                page = chunk.source_pages_json[0]
            detected.append({
                "id": f"sec-{chunk.sequence}",
                "level": 1,
                "title": f"Section {(i // step) + 1} (Chunk {chunk.sequence})",
                "start_page": max(0, page - 1),
                "start_chunk_index": chunk.sequence,
            })
        return detected

    return []


@router.get("/{id}/export-markdown")
def export_document_markdown(
    id: str, session: Session = Depends(get_session)
) -> Response:
    """Exports verified reading highlights and Google Search citations as clean Markdown."""
    import re

    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404)

    cards = session.exec(
        select(ContextCard).where(ContextCard.document_id == id, ContextCard.dismissed == False)
    ).all()

    chunks = session.exec(
        select(ReadingChunk).where(ReadingChunk.document_id == id).order_by(ReadingChunk.sequence)
    ).all()
    chunk_map = {c.id: c for c in chunks}

    md_lines = [
        f"# {doc.title or doc.filename} — Reading Notes & Grounded Highlights",
        f"*Exported from Athena on {utc_now().strftime('%Y-%m-%d %H:%M:%S UTC')}*",
        "",
        "---",
        "",
    ]

    if not cards:
        md_lines.append("No context cards saved yet.")
    else:
        for card in cards:
            src_chunk = chunk_map.get(card.source_chunk_id)
            seq_str = f"Chunk {src_chunk.sequence}" if src_chunk else "Passage"
            page_ref = ""
            if src_chunk and src_chunk.source_pages_json:
                try:
                    p_list = json.loads(src_chunk.source_pages_json)
                    if p_list:
                        page_ref = f" (Page {p_list[0]})"
                except Exception:
                    pass

            md_lines.append(f"## {card.title} — {seq_str}{page_ref}")
            if card.exact_quote:
                md_lines.append(f'> "{card.exact_quote}"')
                md_lines.append("")
            md_lines.append(f"{card.body}")
            md_lines.append("")

            if card.citations_json:
                try:
                    citations = json.loads(card.citations_json)
                    if citations:
                        md_lines.append("**Verified Sources:**")
                        for cit in citations:
                            title = cit.get("title") or "Source"
                            url = cit.get("url") or "#"
                            pub = cit.get("publisher") or "Web"
                            md_lines.append(f"- [{title} ({pub})]({url})")
                        md_lines.append("")
                except Exception:
                    pass
            md_lines.append("---")
            md_lines.append("")

    md_content = "\n".join(md_lines)
    safe_title = re.sub(r"[^a-zA-Z0-9_\-]+", "_", doc.title or "notes").strip("_")
    return Response(
        content=md_content,
        media_type="text/markdown; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{safe_title}_notes.md"'},
    )


class VibeCheckRequest(BaseModel):
    chunk_index: int


@router.post("/{id}/vibe-check")
async def get_chunk_vibe_check(
    id: str,
    payload: VibeCheckRequest,
    session: Session = Depends(get_session),
) -> Dict[str, Any]:
    """Generates a 5-second plain-English take and modern analogy for a dense chunk."""
    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", status_code=404, message="Document not found")

    target_chunk = session.exec(
        select(ReadingChunk).where(
            ReadingChunk.document_id == id,
            ReadingChunk.sequence == payload.chunk_index,
        )
    ).first()

    if not target_chunk:
        # Fallback to closest available chunk for edge case indices (e.g. 0 or 99999)
        target_chunk = session.exec(
            select(ReadingChunk)
            .where(ReadingChunk.document_id == id)
            .order_by(ReadingChunk.sequence.desc())
        ).first()

    if not target_chunk:
        return {
            "chunk_index": payload.chunk_index,
            "plain_take": "Keep reading to discover key insights from this book.",
            "analogy": None,
            "fallback": True,
        }

    prev_chunk = None
    if payload.chunk_index > 0:
        prev_chunk = session.exec(
            select(ReadingChunk).where(
                ReadingChunk.document_id == id,
                ReadingChunk.sequence == payload.chunk_index - 1,
            )
        ).first()

    chapter = session.exec(
        select(DocumentChapter)
        .where(
            DocumentChapter.doc_id == id,
            DocumentChapter.start_chunk_index <= payload.chunk_index,
        )
        .order_by(DocumentChapter.start_chunk_index.desc())
    ).first()

    try:
        from app.config import settings
        llm = LLMService()
        result = await asyncio.wait_for(
            asyncio.to_thread(
                llm.generate_vibe_check,
                passage=target_chunk.raw_text,
                prev_passage=prev_chunk.raw_text if prev_chunk else "",
                doc_title=doc.title or doc.filename,
                chapter_title=chapter.title if chapter else "",
            ),
            timeout=settings.VIBE_CHECK_TIMEOUT_S,
        )
    except Exception as err:
        logger.warning("Vibe check LLM error/timeout: %s; using deterministic fallback", err)
        sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", target_chunk.raw_text) if s.strip()]
        first_sentence = sentences[0] if sentences else target_chunk.raw_text[:120]
        result = {
            "plain_take": f"The core idea is that {first_sentence[0].lower() + first_sentence[1:] if len(first_sentence) > 1 else first_sentence}",
            "analogy": None,
            "fallback": True,
        }

    return {
        "chunk_index": payload.chunk_index,
        "plain_take": result.get("plain_take", "A core theme from this passage."),
        "analogy": result.get("analogy"),
        "fallback": result.get("fallback", False),
    }

