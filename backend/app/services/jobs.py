from concurrent.futures import ThreadPoolExecutor
import json
import logging
import multiprocessing
from typing import Optional
from sqlmodel import Session, select, delete

from app.db import engine
from app.errors import AppException, ERROR_MESSAGES
from app.models import Document, ReadingChunk, Concept, ContextCard, DocumentChapter, ReadingState, utc_now
from app.services.extraction import validate_pdf_file, extract_document_content, extract_toc_with_chunk_mapping, get_document_file_path
from app.services.chunker import chunk_document
from app.services.integrity import verify_integrity
from app.services.concepts import extract_concepts
from app.services.cards import generate_context_cards
from app.services.edge_ai import classify_document_purpose
from app.config import UPLOADS_DIR

logger = logging.getLogger(__name__)

# Single background worker thread (§6.5b in CLAUDE.md)
_executor = ThreadPoolExecutor(max_workers=1)


def cleanup_interrupted_jobs() -> None:
    """Marks any lingering 'queued' or 'processing' documents as failed INTERRUPTED on startup."""
    with Session(engine) as session:
        statement = select(Document).where(Document.status.in_(["queued", "processing"]))
        stale_docs = session.exec(statement).all()
        for doc in stale_docs:
            doc.status = "failed"
            doc.error_code = "INTERRUPTED"
            doc.error_message = ERROR_MESSAGES["INTERRUPTED"]
            doc.updated_at = utc_now()
            session.add(doc)
        if stale_docs:
            session.commit()
            logger.info("Marked %d interrupted documents as failed INTERRUPTED", len(stale_docs))


def _update_doc_progress(
    session: Session,
    doc_id: str,
    stage: str,
    percent: int,
    status: str = "processing",
) -> Optional[Document]:
    doc = session.get(Document, doc_id)
    if doc:
        doc.stage = stage
        doc.percent = percent
        doc.status = status
        doc.updated_at = utc_now()
        session.add(doc)
        session.commit()
        session.refresh(doc)
    return doc


def process_document_job(doc_id: str) -> None:
    """Executes the pipeline for a single document in a background worker."""
    pdf_path = get_document_file_path(doc_id)

    with Session(engine) as session:
        doc = session.get(Document, doc_id)
        if not doc:
            logger.error("Job started for nonexistent doc %s", doc_id)
            return

        try:
            # 1. Validating stage (5%)
            _update_doc_progress(session, doc_id, stage="validating", percent=5)
            page_count = validate_pdf_file(pdf_path)
            doc.page_count = page_count
            session.add(doc)
            session.commit()

            # 2. Extracting stage (25%)
            _update_doc_progress(session, doc_id, stage="extracting", percent=25)
            last_reported_percent = 25

            def extraction_progress(phase: str, current: int, total: int) -> None:
                nonlocal last_reported_percent
                if total <= 0:
                    return
                fraction = min(1.0, current / total)
                if phase == "triage":
                    percent = 25 + int(fraction * 5)
                elif phase == "ocr":
                    percent = 30 + int(fraction * 3)
                else:
                    percent = 33 + int(fraction * 7)
                # Cap database writes to at most about one per percentage point.
                if percent > last_reported_percent:
                    _update_doc_progress(
                        session, doc_id, stage="extracting", percent=percent
                    )
                    last_reported_percent = percent

            extracted = extract_document_content(
                doc_id=doc_id,
                file_path=pdf_path,
                original_filename=doc.filename,
                progress_callback=extraction_progress,
            )

            # Stage-0 Document Bouncer: Admission & Genre Triage Gate
            if doc.error_message != "FORCE_ACCEPTED":
                pages_meta = extracted.get("triage", {}).get("pages", [])
                sample_texts = [extracted.get("canonical_text", "")]
                bouncer_result = classify_document_purpose(
                    pages_meta=pages_meta,
                    sample_texts=sample_texts,
                    raw_filename=doc.filename or "",
                    pdf_path=pdf_path,
                    telemetry=extracted.get("telemetry"),
                )
                if not bouncer_result["allowed"]:
                    logger.info("Stage-0 Bouncer rejected document %s: %s", doc_id, bouncer_result)
                    doc.status = "unsupported"
                    doc.error_code = "DOCUMENT_UNSUPPORTED"
                    doc.error_message = f"{bouncer_result['display_label']}||{bouncer_result['reason']}"
                    doc.title = extracted.get("title") or doc.title
                    doc.page_count = extracted.get("page_count") or doc.page_count
                    doc.updated_at = utc_now()
                    session.add(doc)
                    session.commit()
                    return

            # 3. Cleaning stage (40%)
            _update_doc_progress(session, doc_id, stage="cleaning", percent=40)
            doc.title = extracted["title"]
            doc.page_count = extracted["page_count"]
            doc.canonical_text = extracted["canonical_text"]
            doc.spans_json = json.dumps(extracted["spans"])
            doc.layout_warning = extracted["layout_warning"]
            session.add(doc)
            session.commit()

            # 4. Chunking stage (55%)
            _update_doc_progress(session, doc_id, stage="chunking", percent=55)
            spans_data = json.loads(doc.spans_json) if doc.spans_json else []
            chunk_dicts = chunk_document(
                doc_id=doc_id,
                canonical_text=doc.canonical_text or "",
                spans=spans_data,
            )

            # Clear any previous chunks/chapters for idempotency on re-ingestion
            session.exec(delete(ReadingChunk).where(ReadingChunk.document_id == doc_id))
            session.exec(delete(DocumentChapter).where(DocumentChapter.doc_id == doc_id))

            # Persist chunks as ReadingChunk rows
            for cd in chunk_dicts:
                chunk_row = ReadingChunk(
                    id=cd["id"],
                    document_id=doc_id,
                    sequence=cd["sequence"],
                    section_title=cd["section_title"],
                    raw_text=cd["raw_text"],
                    source_pages_json=json.dumps(cd["source_pages_json"]),
                    start_offset=cd["start_offset"],
                    end_offset=cd["end_offset"],
                    checksum=cd["checksum"],
                    boundary_method=cd.get("boundary_method", "paragraph"),
                    canonical_sha256=cd.get("canonical_sha256"),
                )
                session.add(chunk_row)
            session.commit()

            # Build page to chunk index mapping and save TOC chapters
            raw_toc = extracted.get("raw_toc", [])
            if not raw_toc and extracted.get("printed_toc"):
                raw_toc = [
                    [entry.get("level", 1), entry.get("title", ""), entry.get("page", 1)]
                    for entry in extracted["printed_toc"]
                ]
            page_to_first_chunk: dict[int, int] = {}
            for cd in chunk_dicts:
                seq = cd["sequence"]
                pages = cd.get("source_pages_json") or []
                for p in pages:
                    p0 = max(0, p - 1)
                    if p0 not in page_to_first_chunk:
                        page_to_first_chunk[p0] = seq

            if raw_toc:
                chapters_data = extract_toc_with_chunk_mapping(raw_toc, page_to_first_chunk)
                for ch in chapters_data:
                    chap_row = DocumentChapter(
                        doc_id=doc_id,
                        level=ch["level"],
                        title=ch["title"],
                        start_page=ch["start_page"],
                        start_chunk_index=ch["start_chunk_index"],
                    )
                    session.add(chap_row)

            # Initialize reading state
            existing_state = session.get(ReadingState, doc_id)
            if not existing_state:
                session.add(ReadingState(doc_id=doc_id, current_chunk_index=1, reading_mode="feed"))
            session.commit()


            # 5. Verifying integrity stage (65%)
            _update_doc_progress(session, doc_id, stage="verifying", percent=65)
            integrity_input = [
                {
                    "sequence": cd["sequence"],
                    "raw_text": cd["raw_text"],
                    "start_offset": cd["start_offset"],
                    "end_offset": cd["end_offset"],
                }
                for cd in chunk_dicts
            ]
            integrity_result = verify_integrity(
                canonical_text=doc.canonical_text or "",
                chunks=integrity_input,
            )

            if not integrity_result["verified"]:
                logger.error(
                    "Integrity check FAILED for doc %s: %s",
                    doc_id,
                    integrity_result.get("failure_reason", "unknown"),
                )
                raise AppException("INTERNAL")

            doc.integrity_verified = True
            doc.original_checksum = integrity_result["original_checksum"]
            doc.reconstructed_checksum = integrity_result["reconstructed_checksum"]
            session.add(doc)
            session.commit()

            # 6. Finding concepts stage (72%)
            _update_doc_progress(session, doc_id, stage="finding_concepts", percent=72)
            chunk_rows = session.exec(
                select(ReadingChunk)
                .where(ReadingChunk.document_id == doc_id)
                .order_by(ReadingChunk.sequence)
            ).all()

            concepts = extract_concepts(
                canonical_text=doc.canonical_text or "",
                chunks=chunk_rows,
                document_id=doc_id,
            )
            for concept in concepts:
                session.add(concept)
            session.commit()

            # 7. Preparing context stage (72 -> 95%)
            _update_doc_progress(session, doc_id, stage="preparing_context", percent=75)

            def progress_cb(current: int, total: int) -> None:
                if total > 0:
                    pct = int(75 + (current / total) * 20)
                    _update_doc_progress(session, doc_id, stage="preparing_context", percent=pct)

            try:
                cards, updated_concepts = generate_context_cards(
                    concepts=concepts,
                    chunks=chunk_rows,
                    document_id=doc_id,
                    canonical_text=doc.canonical_text,
                    progress_callback=progress_cb,
                )
                for card in cards:
                    session.add(card)
                for concept in updated_concepts:
                    session.add(concept)
                session.commit()

                if cards:
                    doc.context_status = "ready"
                elif concepts:
                    doc.context_status = "partial"
                else:
                    doc.context_status = "ready"
            except Exception as e:
                logger.warning("Context generation failed for doc %s, finishing ready: %s", doc_id, e)
                doc.context_status = "unavailable"

            # 8. Ready (100%)
            doc.stage = "done"
            doc.percent = 100
            doc.status = "ready"
            doc.updated_at = utc_now()
            session.add(doc)
            session.commit()

        except MemoryError:
            logger.exception("Book %s exceeded available memory during processing", doc_id)
            doc.status = "failed"
            doc.error_code = "RESOURCE_LIMIT"
            doc.error_message = ERROR_MESSAGES["RESOURCE_LIMIT"]
            doc.updated_at = utc_now()
            session.add(doc)
            session.commit()
        except OSError as e:
            import errno

            code = "RESOURCE_LIMIT" if e.errno == errno.ENOSPC else "INTERNAL"
            if code == "RESOURCE_LIMIT":
                logger.exception("Book %s exhausted available storage during processing", doc_id)
            else:
                logger.exception("Storage error while processing book %s", doc_id)
            doc.status = "failed"
            doc.error_code = code
            doc.error_message = ERROR_MESSAGES[code]
            doc.updated_at = utc_now()
            session.add(doc)
            session.commit()
        except AppException as e:
            logger.warning("Document %s failed with code %s: %s", doc_id, e.code, e.message)
            doc.status = "failed"
            doc.error_code = e.code
            doc.error_message = e.message
            doc.updated_at = utc_now()
            session.add(doc)
            session.commit()
        except Exception as e:
            logger.exception("Unexpected error processing document %s", doc_id)
            doc.status = "failed"
            doc.error_code = "INTERNAL"
            doc.error_message = ERROR_MESSAGES["INTERNAL"]
            doc.updated_at = utc_now()
            session.add(doc)
            session.commit()


def queue_document_job(doc_id: str) -> None:
    """Runs one document worker at a time, isolated from the API process."""
    _executor.submit(_run_isolated_document_job, doc_id)


def _run_isolated_document_job(doc_id: str) -> None:
    """Keep expensive PDF parsing in a child so a worker crash cannot kill FastAPI."""
    worker = multiprocessing.get_context("spawn").Process(
        target=process_document_job,
        args=(doc_id,),
        name=f"athena-book-{doc_id[:8]}",
    )
    try:
        worker.start()
        worker.join()
        exit_code = worker.exitcode
        worker.close()
        if exit_code == 0:
            return
        logger.error("Book worker for %s exited unexpectedly (%s)", doc_id, exit_code)
    except Exception:
        logger.exception("Could not start isolated worker for book %s", doc_id)

    # A hard worker exit (for example, an OS memory termination) leaves the API
    # process alive and gives the user a recoverable document status.
    try:
        with Session(engine) as session:
            doc = session.get(Document, doc_id)
            if doc and doc.status in {"queued", "processing"}:
                doc.status = "failed"
                doc.error_code = "RESOURCE_LIMIT"
                doc.error_message = ERROR_MESSAGES["RESOURCE_LIMIT"]
                doc.updated_at = utc_now()
                session.add(doc)
                session.commit()
    except Exception:
        logger.exception("Could not record worker exit for book %s", doc_id)


def reset_and_requeue_document(doc_id: str) -> None:
    """Deletes existing chunks, concepts, and cards, resets doc state, and requeues."""
    with Session(engine) as session:
        doc = session.get(Document, doc_id)
        if not doc:
            raise AppException("NOT_FOUND", status_code=404)

        if doc.status != "failed":
            raise AppException("CONFLICT", "Document is currently processing", status_code=409)

        # Clean existing derived items
        for chunk in session.exec(select(ReadingChunk).where(ReadingChunk.document_id == doc_id)).all():
            session.delete(chunk)
        for concept in session.exec(select(Concept).where(Concept.document_id == doc_id)).all():
            session.delete(concept)
        for card in session.exec(select(ContextCard).where(ContextCard.document_id == doc_id)).all():
            session.delete(card)

        # Reset document status
        doc.status = "queued"
        doc.stage = "validating"
        doc.percent = 0
        doc.error_code = None
        doc.error_message = None
        doc.canonical_text = None
        doc.spans_json = None
        doc.integrity_verified = False
        doc.original_checksum = None
        doc.reconstructed_checksum = None
        doc.layout_warning = None
        doc.context_status = "pending"
        doc.updated_at = utc_now()
        session.add(doc)
        session.commit()

    queue_document_job(doc_id)


def force_requeue_document(doc_id: str) -> None:
    """Deletes existing derived items, sets FORCE_ACCEPTED marker, and force-requeues the document."""
    with Session(engine) as session:
        doc = session.get(Document, doc_id)
        if not doc:
            raise AppException("NOT_FOUND", status_code=404)

        # Clean existing derived items
        for chunk in session.exec(select(ReadingChunk).where(ReadingChunk.document_id == doc_id)).all():
            session.delete(chunk)
        for concept in session.exec(select(Concept).where(Concept.document_id == doc_id)).all():
            session.delete(concept)
        for card in session.exec(select(ContextCard).where(ContextCard.document_id == doc_id)).all():
            session.delete(card)

        # Reset document status with FORCE_ACCEPTED marker
        doc.status = "queued"
        doc.stage = "validating"
        doc.percent = 0
        doc.error_code = None
        doc.error_message = "FORCE_ACCEPTED"
        doc.canonical_text = None
        doc.spans_json = None
        doc.integrity_verified = False
        doc.original_checksum = None
        doc.reconstructed_checksum = None
        doc.layout_warning = None
        doc.context_status = "pending"
        doc.updated_at = utc_now()
        session.add(doc)
        session.commit()

    queue_document_job(doc_id)

