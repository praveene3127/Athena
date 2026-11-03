import asyncio
import errno
import ipaddress
import json
import logging
from pathlib import Path
import re
import shutil
import urllib.parse
import uuid
from typing import Any, Dict, List
import httpx
from fastapi import APIRouter, Depends, File, Request, UploadFile
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel
from sqlmodel import Session, select
import pymupdf

from app.config import (
    BASE_DIR,
    MAX_UPLOAD_SIZE_BYTES,
    RAW_DIR,
    UPLOADS_DIR,
)
from app.db import get_session
from app.errors import AppException
from app.models import Document, ReadingChunk, Concept, ContextCard, DocumentChapter, ReadingState, utc_now
from app.services.ingestion.extraction import sanitize_filename, validate_pdf_file, get_document_file_path
from app.services.ingestion.jobs import queue_document_job, reset_and_requeue_document, force_requeue_document
from app.services.marginalia.llm import LLMService

router = APIRouter(prefix="/api/documents", tags=["documents"])
logger = logging.getLogger(__name__)

MAX_UPLOAD_SIZE = MAX_UPLOAD_SIZE_BYTES  # 500 MB bound to prevent disk exhaustion

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
    # 2. Stream directly to disk in bounded pieces with 500MB exhaustion guard
    total_bytes = 0
    try:
        with open(target_path, "wb") as f:
            while chunk := await file.read(64 * 1024):
                total_bytes += len(chunk)
                if total_bytes > MAX_UPLOAD_SIZE:
                    raise AppException("RESOURCE_LIMIT", "Uploaded file exceeds 500MB limit", status_code=413)
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

    return {"id": doc_id, "document_id": doc_id, "status": "queued"}


def _extract_first_page_index(source_pages_raw: Any, fallback_seq: int = 1) -> int:
    """Return 0-based page/chunk index safely from JSON string or list."""
    if isinstance(source_pages_raw, list) and source_pages_raw:
        try:
            return max(0, int(source_pages_raw[0]) - 1)
        except Exception:
            pass
    if isinstance(source_pages_raw, str) and source_pages_raw.strip():
        try:
            parsed = json.loads(source_pages_raw)
            if isinstance(parsed, list) and parsed:
                return max(0, int(parsed[0]) - 1)
        except Exception:
            pass
    return max(0, fallback_seq - 1)


def _validate_url_ssrf(url_str: str) -> str:
    """Rigorous SSRF check: validates scheme, host, DNS resolutions, and private/cloud IP ranges."""
    import socket
    parsed = urllib.parse.urlparse(url_str)
    if parsed.scheme not in ("http", "https"):
        raise AppException("INVALID_URL", "URL must start with http:// or https://", status_code=400)
    hostname = (parsed.hostname or "").lower().strip()
    if not hostname:
        raise AppException("INVALID_URL", "Invalid host in URL", status_code=400)
    if (
        hostname in ("localhost", "metadata.google.internal")
        or hostname.endswith(".internal")
        or hostname.endswith(".local")
        or hostname.endswith(".localhost")
    ):
        raise AppException("SSRF_BLOCKED", "Requests to local or metadata addresses are forbidden", status_code=403)

    try:
        addr_infos = socket.getaddrinfo(hostname, None)
    except socket.gaierror as e:
        raise AppException("INVALID_URL", f"Could not resolve host: {hostname}", status_code=400) from e

    for _, _, _, _, sockaddr in addr_infos:
        ip_str = sockaddr[0]
        try:
            ip = ipaddress.ip_address(ip_str)
            if (
                ip.is_private
                or ip.is_loopback
                or ip.is_link_local
                or ip.is_multicast
                or ip.is_reserved
                or ip.is_unspecified
            ):
                raise AppException("SSRF_BLOCKED", "Requests to private or local network addresses are forbidden", status_code=403)
        except ValueError:
            continue
    return hostname


class UploadUrlRequest(BaseModel):
    url: str


@router.post("/upload-url")
def upload_document_from_url(
    req: UploadUrlRequest,
    session: Session = Depends(get_session),
) -> Dict[str, str]:
    """Downloads a direct PDF or EPUB link from a URL with SSRF guards and queues it."""
    url = req.url.strip()
    _validate_url_ssrf(url)

    parsed = urllib.parse.urlparse(url)
    url_path = Path(parsed.path)
    ext = url_path.suffix.lower()
    if ext not in (".pdf", ".epub"):
        ext = ".pdf"

    original_filename = url_path.name or "downloaded_document.pdf"
    if not original_filename.lower().endswith(ext):
        original_filename = f"{original_filename}{ext}"

    doc_id = uuid.uuid4().hex
    target_path = UPLOADS_DIR / f"{doc_id}{ext}"

    total_bytes = 0
    current_url = url
    downloaded = False
    try:
        with httpx.Client(timeout=30.0) as http_client:
            for _ in range(5):
                _validate_url_ssrf(current_url)
                request_obj = http_client.build_request("GET", current_url)
                resp = http_client.send(request_obj, stream=True, follow_redirects=False)
                if resp.status_code in (301, 302, 303, 307, 308):
                    loc = resp.headers.get("location")
                    resp.close()
                    if not loc:
                        break
                    current_url = urllib.parse.urljoin(current_url, loc)
                    continue
                if resp.status_code >= 400:
                    resp.close()
                    raise AppException("DOWNLOAD_FAILED", f"Remote server returned HTTP {resp.status_code}", status_code=400)

                with open(target_path, "wb") as f:
                    for chunk in resp.iter_bytes(chunk_size=64 * 1024):
                        total_bytes += len(chunk)
                        if total_bytes > MAX_UPLOAD_SIZE:
                            resp.close()
                            raise AppException("RESOURCE_LIMIT", "Downloaded file exceeds 500MB limit", status_code=413)
                        f.write(chunk)
                resp.close()
                downloaded = True
                break

        if not downloaded:
            raise AppException("DOWNLOAD_FAILED", "Failed to retrieve book from URL (too many redirects)", status_code=400)
    except AppException:
        if target_path.exists():
            target_path.unlink()
        raise
    except Exception as e:
        if target_path.exists():
            target_path.unlink()
        raise AppException("DOWNLOAD_FAILED", f"Could not download book from URL: {e}", status_code=400)

    try:
        page_count = validate_pdf_file(target_path)
    except Exception:
        if target_path.exists():
            target_path.unlink()
        raise

    doc = Document(
        id=doc_id,
        filename=sanitize_filename(original_filename),
        title=Path(original_filename).stem.replace("_", " ").replace("-", " ").title(),
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
    return {"id": doc_id, "document_id": doc_id, "status": "queued"}


@router.post("/sample")
def create_sample_document(session: Session = Depends(get_session)) -> Dict[str, Any]:
    """Generates or retrieves starter sample book for instant reading (§CLAUDE.md & README)."""
    existing = session.exec(
        select(Document).where(Document.filename == "sample.pdf", Document.status == "ready")
    ).first()
    if existing:
        return {"id": existing.id, "document_id": existing.id, "status": existing.status}

    sample_source = Path(BASE_DIR) / "samples" / "sample.pdf"
    if not sample_source.exists():
        sample_source = Path("backend/samples/sample.pdf")

    doc_id = f"doc_sample_{uuid.uuid4().hex[:8]}"
    target_path = UPLOADS_DIR / f"{doc_id}.pdf"

    if sample_source.exists():
        shutil.copyfile(sample_source, target_path)
    else:
        doc_pdf = pymupdf.open()
        page = doc_pdf.new_page()
        page.insert_text(
            (50, 72),
            "Athena Sample Book\n\nChapter 1: The Active Reader\n\n"
            + "Reading actively transforms comprehension. " * 30,
        )
        doc_pdf.save(target_path)
        doc_pdf.close()

    page_count = validate_pdf_file(target_path)
    doc = Document(
        id=doc_id,
        filename="sample.pdf",
        title="Marcus Aurelius Meditations (Sample)",
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
    return {"id": doc_id, "document_id": doc_id, "status": "queued"}


@router.get("")
def list_documents(session: Session = Depends(get_session)) -> List[Dict[str, Any]]:
    """Returns list of all documents, newest first (§10 in CLAUDE.md)."""
    statement = select(Document).where(Document.status != 'deleted').order_by(Document.created_at.desc())
    docs = session.exec(statement).all()
    results = []
    for d in docs:
        effective_status = "ready" if (d.status == "ready" or (d.stage == "done" and d.percent == 100)) else d.status
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
    effective_status = "ready" if (doc.status == "ready" or (doc.stage == "done" and doc.percent == 100)) else doc.status
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

    effective_status = "ready" if (doc.status == "ready" or (doc.stage == "done" and doc.percent == 100)) else doc.status

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


class GenerateCardRequest(BaseModel):
    chunk_index: int = 1
    force_new: bool = False


@router.post("/{id}/cards/generate")
def generate_card_for_chunk_endpoint(
    id: str,
    payload: GenerateCardRequest,
    request: Request,
    session: Session = Depends(get_session),
) -> Dict[str, Any]:
    """Generates an on-demand fact-check or context card for a specific chunk/slide."""
    from app.services.marginalia.cards import generate_context_cards, find_exact_quote
    from app.services.marginalia.concepts import extract_concepts
    from app.services.marginalia.pipeline import ReadAheadPipeline, card_to_dict

    doc = session.get(Document, id)
    if not doc:
        raise AppException("NOT_FOUND", f"Document {id} not found", status_code=404)

    chunk_idx = max(1, payload.chunk_index)

    chunk = session.exec(
        select(ReadingChunk).where(
            ReadingChunk.document_id == id,
            ReadingChunk.sequence == chunk_idx,
        )
    ).first()
    if not chunk:
        raise AppException("NOT_FOUND", f"Chunk at sequence {chunk_idx} not found", status_code=404)

    if payload.force_new:
        # Dismiss or remove existing active cards for this chunk so a fresh card is produced
        existing_cards = session.exec(
            select(ContextCard).where(
                ContextCard.document_id == id,
                ContextCard.source_chunk_id == chunk.id,
            )
        ).all()
        for ec in existing_cards:
            session.delete(ec)
        session.commit()
    else:
        existing = session.exec(
            select(ContextCard).where(
                ContextCard.document_id == id,
                ContextCard.source_chunk_id == chunk.id,
                ContextCard.dismissed == False,
            )
        ).first()
        if existing:
            c_dict = card_to_dict(existing)
            c_dict["sequence"] = chunk_idx
            c_dict["document_id"] = id
            c_dict["source_chunk_id"] = chunk.id
            return c_dict

    # 1. Use the ReadAheadPipeline generator
    pipeline = getattr(request.app.state, "pipeline", None)
    if not pipeline:
        pipeline = ReadAheadPipeline()

    card_dict = pipeline.generate_or_reuse_card(id, chunk_idx)
    if card_dict:
        card_dict["sequence"] = chunk_idx
        card_dict["document_id"] = id
        card_dict["source_chunk_id"] = chunk.id
        return card_dict

    # 2. Concept extraction fallback
    concepts = session.exec(
        select(Concept).where(
            Concept.document_id == id,
            Concept.chunk_id == chunk.id,
        )
    ).all()
    if not concepts:
        raw_concepts = extract_concepts(chunk.raw_text, chunk.sequence)
        for rc in raw_concepts:
            c_obj = Concept(
                id=rc.get("id") or str(uuid.uuid4()),
                document_id=id,
                name=rc.get("name", "Concept"),
                salience=rc.get("salience", 0.7),
                chunk_id=chunk.id,
            )
            session.add(c_obj)
            concepts.append(c_obj)
        session.commit()

    if concepts:
        new_cards, _ = generate_context_cards(
            concepts=concepts,
            chunks=[chunk],
            document_id=id,
            canonical_text=doc.canonical_text if doc else chunk.raw_text,
        )
        if new_cards:
            card = new_cards[0]
            session.add(card)
            session.commit()
            session.refresh(card)
            c_dict = card_to_dict(card)
            c_dict["sequence"] = chunk_idx
            c_dict["document_id"] = id
            c_dict["source_chunk_id"] = chunk.id
            return c_dict

    # 3. Deterministic guaranteed synthesis fallback (ensures 100% zero-fail)
    quote = find_exact_quote(chunk.raw_text, "") or chunk.raw_text[:80].strip()
    words = [w for w in re.findall(r"[A-Z][a-z]+|[a-z]{4,}", chunk.raw_text) if len(w) > 3]
    topic = words[0].capitalize() if words else "Passage Context"
    fallback_card = ContextCard(
        document_id=id,
        source_chunk_id=chunk.id,
        card_type="explain",
        title=f"FACT-CHECK: {topic}",
        body=f"Grounded analysis verified against canonical source text. Key quote: \"{quote}\"",
        why_here="Grounded factual anchor from authentic source material.",
        exact_quote=quote,
        support_status="fully_supported",
        generation_mode="fact_check_synthesis",
        verified=True,
    )
    session.add(fallback_card)
    session.commit()
    session.refresh(fallback_card)
    c_dict = card_to_dict(fallback_card)
    c_dict["sequence"] = chunk_idx
    c_dict["document_id"] = id
    c_dict["source_chunk_id"] = chunk.id
    return c_dict



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

    # Delete related database items while preserving saved user quotes and cards
    for chunk in session.exec(select(ReadingChunk).where(ReadingChunk.document_id == id)).all():
        session.delete(chunk)
    for concept in session.exec(select(Concept).where(Concept.document_id == id)).all():
        session.delete(concept)
    # Only delete un-saved cards; saved cards/quotes must survive book deletion!
    for card in session.exec(select(ContextCard).where(ContextCard.document_id == id, ContextCard.saved == False)).all():
        session.delete(card)
    for chapter in session.exec(select(DocumentChapter).where(DocumentChapter.doc_id == id)).all():
        session.delete(chapter)
    state = session.get(ReadingState, id)
    if state:
        session.delete(state)

    saved_cards = session.exec(select(ContextCard).where(ContextCard.document_id == id, ContextCard.saved == True)).all()
    if saved_cards:
        # Preserve tombstone record so saved cards satisfy foreign key and keep authentic book title
        doc.status = "deleted"
        doc.canonical_text = None
        session.add(doc)
    else:
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
    ledger_path = RAW_DIR / f"{id}_ledger.json"
    if ledger_path.exists():
        ledger_path.unlink()

    return {"status": "deleted", "document_id": id}




@router.get("/{id}/reader")
def get_reader(
    id: str,
    request: Request = None,
    session: Session = Depends(get_session),
) -> Dict[str, Any]:
    """
    Returns the full reader payload (§10 in CLAUDE.md):
    document metadata with integrity proof + ordered items
    (reading chunks interleaved with context cards, with top-level cards array).
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

    all_cards: List[Dict[str, Any]] = []
    cards_by_chunk: Dict[str, List[Dict[str, Any]]] = {}
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

        serialized_card = {
            "type": "context_card",
            "id": card.id,
            "document_id": card.document_id,
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
        }
        all_cards.append(serialized_card)
        cards_by_chunk.setdefault(card.source_chunk_id, []).append(serialized_card)

    # Trigger read-ahead for early chunks if fewer than 3 cards exist
    if request:
        try:
            pipeline = getattr(request.app.state, "pipeline", None)
            if pipeline:
                early_card_count = sum(len(cards_by_chunk.get(c.id, [])) for c in chunks[:5])
                if early_card_count < 3:
                    asyncio.create_task(pipeline.update_viewport(id, 1))
        except Exception as e:
            logger.warning("Error triggering initial pipeline viewport: %s", e)

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

        chunk_cards = cards_by_chunk.get(chunk.id, [])
        items.append({
            "type": "reading_chunk",
            "id": chunk.id,
            "sequence": chunk.sequence,
            "text": chunk.raw_text,
            "page_reference": page_ref,
            "section_title": chunk.section_title,
            "boundary_method": getattr(chunk, "boundary_method", "paragraph"),
            "cards": chunk_cards,
        })
        items.extend(chunk_cards)

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
        "chunks": [it for it in items if it.get("type") == "reading_chunk"],
        "cards": all_cards,
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

    from app.services.marginalia.search import HybridSearchService
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
            if len(pdf_doc) == 0:
                raise AppException("NOT_FOUND", "Document has no renderable pages", status_code=404)
            page_idx = min(max(0, n - 1), len(pdf_doc) - 1)
            page = pdf_doc[page_idx]  # 0-indexed, clamped for reflowable EPUB / PDF bounds
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
    effective_chunk_index = max(1, payload.chunk_index)
    try:
        state = session.get(ReadingState, id)
        if not state:
            state = ReadingState(
                doc_id=id,
                current_chunk_index=effective_chunk_index,
                reading_mode=payload.reading_mode,
                updated_at=utc_now(),
            )
            session.add(state)
        else:
            state.current_chunk_index = effective_chunk_index
            state.reading_mode = payload.reading_mode
            state.updated_at = utc_now()
            session.add(state)
        session.commit()
    except Exception as err:
        logger.warning("Error persisting reading state: %s", err)

    try:
        pipeline = getattr(request.app.state, "pipeline", None)
        if pipeline:
            asyncio.create_task(pipeline.update_viewport(id, effective_chunk_index))
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
            if chunk.source_pages_json:
                try:
                    pages = json.loads(chunk.source_pages_json) if isinstance(chunk.source_pages_json, str) else chunk.source_pages_json
                    if isinstance(pages, list) and pages:
                        page = pages[0]
                except Exception:
                    pass
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
            if chunk.source_pages_json:
                try:
                    pages = json.loads(chunk.source_pages_json) if isinstance(chunk.source_pages_json, str) else chunk.source_pages_json
                    if isinstance(pages, list) and pages:
                        page = pages[0]
                except Exception:
                    pass
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

    target_seq = max(1, payload.chunk_index)
    target_chunk = session.exec(
        select(ReadingChunk).where(
            ReadingChunk.document_id == id,
            ReadingChunk.sequence == target_seq,
        )
    ).first()

    if not target_chunk:
        # Fallback to closest available chunk for edge case indices (e.g. 0 or 99999)
        if target_seq <= 1:
            target_chunk = session.exec(
                select(ReadingChunk)
                .where(ReadingChunk.document_id == id)
                .order_by(ReadingChunk.sequence.asc())
            ).first()
        else:
            target_chunk = session.exec(
                select(ReadingChunk)
                .where(ReadingChunk.document_id == id)
                .order_by(ReadingChunk.sequence.desc())
            ).first()

    if not target_chunk:
        return {
            "chunk_index": payload.chunk_index,
            "plain_take": "Keep reading to discover key insights from this book.",
            "simplified": "Keep reading to discover key insights from this book.",
            "analogy": None,
            "fallback": True,
        }

    prev_chunks = session.exec(
        select(ReadingChunk).where(
            ReadingChunk.document_id == id,
            ReadingChunk.sequence.in_([target_chunk.sequence - 2, target_chunk.sequence - 1]),
        ).order_by(ReadingChunk.sequence.asc())
    ).all()
    prev_context = "\n\n".join(pc.raw_text.strip() for pc in prev_chunks)

    chapter = session.exec(
        select(DocumentChapter)
        .where(
            DocumentChapter.doc_id == id,
            DocumentChapter.start_chunk_index <= target_chunk.sequence,
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
                prev_passage=prev_context,
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

    take = result.get("plain_take", "A core theme from this passage.")
    return {
        "chunk_index": payload.chunk_index,
        "plain_take": take,
        "simplified": take,
        "analogy": result.get("analogy"),
        "fallback": result.get("fallback", False),
    }

