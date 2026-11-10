import json
from typing import Any, Dict, List, Optional
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlmodel import Session, select

from app.db import get_session
from app.errors import AppException
from app.models import ContextCard, Document, ReadingChunk

router = APIRouter(tags=["cards"])


import uuid

class UserQuoteRequest(BaseModel):
    id: Optional[str] = None
    document_id: str
    source_chunk_id: Optional[str] = None
    chunk_id: Optional[str] = None
    title: Optional[str] = "Saved Passage"
    body: Optional[str] = None
    quote_text: Optional[str] = None
    exact_quote: Optional[str] = None
    document_title: Optional[str] = None


@router.post("/api/cards/quote")
def create_or_save_user_quote(
    req: UserQuoteRequest, session: Session = Depends(get_session)
) -> Dict[str, Any]:
    """Saves or updates an authentic user passage quote into the SQLite ContextCard vault."""
    # Verify document exists
    doc = session.get(Document, req.document_id)
    if not doc:
        raise AppException("NOT_FOUND", "Document not found", status_code=404)

    effective_chunk_id = req.source_chunk_id or req.chunk_id
    if not effective_chunk_id:
        raise AppException("INVALID_REQUEST", "chunk_id or source_chunk_id required", status_code=422)

    chunk = session.get(ReadingChunk, effective_chunk_id)
    if not chunk or chunk.document_id != req.document_id:
        raise AppException("NOT_FOUND", "Chunk not found in specified document", status_code=404)

    effective_body = (req.body or req.quote_text or "")[:4000]
    effective_title = (req.title or "Saved Passage")[:300]
    effective_exact = (req.exact_quote or req.quote_text or effective_body)[:2000]

    # Enforce verbatim substring check (allowing trailing sentence punctuation normalization)
    is_verbatim = bool(
        effective_exact
        and (
            effective_exact in chunk.raw_text
            or effective_exact.rstrip(".!?,;: ") in chunk.raw_text
            or chunk.raw_text.strip().startswith(effective_exact.rstrip(".!?,;: "))
        )
    )
    if not is_verbatim:
        raise AppException("QUOTE_NOT_IN_CHUNK", "exact_quote must be an exact verbatim substring of the source chunk", status_code=422)

    # Document title, section title, page reference snapshots
    doc_title = req.document_title or doc.title or doc.filename or "Saved Passage"
    sec_title = chunk.section_title or None
    page_ref = None
    if chunk.source_pages_json:
        try:
            pages = json.loads(chunk.source_pages_json)
            if isinstance(pages, list) and pages:
                page_ref = f"Page {pages[0]}" if len(pages) == 1 else f"Pages {pages[0]}-{pages[-1]}"
        except Exception:
            pass

    card_id = req.id
    existing_card = session.get(ContextCard, card_id) if card_id else None
    if existing_card and (existing_card.generation_mode != "user_highlight" or existing_card.card_type != "user_highlight"):
        # Do not overwrite AI card; allocate a new ID for the user highlight
        card_id = f"quote_{uuid.uuid4().hex[:12]}"
        existing_card = None

    if not card_id:
        card_id = f"quote_{uuid.uuid4().hex[:12]}"

    if not existing_card:
        card = ContextCard(
            id=card_id,
            document_id=req.document_id,
            source_chunk_id=effective_chunk_id,
            concept_name="Saved Passage",
            card_type="user_highlight",
            title=effective_title,
            body=effective_body,
            why_here=f"From: {doc_title}",
            exact_quote=effective_exact,
            document_title=doc_title,
            section_title=sec_title,
            page_reference=page_ref,
            saved=True,
            dismissed=False,
            citations_json="[]",
            support_status="fully_supported",
            generation_mode="user_highlight",
            verified=True,
        )
    else:
        # Cross-document ownership check
        if existing_card.document_id != req.document_id:
            raise AppException("FORBIDDEN", "Card does not belong to the specified document", status_code=403)
        card = existing_card
        card.saved = True
        card.dismissed = False
        card.title = effective_title
        if effective_body:
            card.body = effective_body
        card.exact_quote = effective_exact
        card.source_chunk_id = effective_chunk_id
        card.document_title = doc_title
        if sec_title:
            card.section_title = sec_title
        if page_ref:
            card.page_reference = page_ref
        card.why_here = f"From: {doc_title}"

    session.add(card)
    session.commit()
    return {"id": card.id, "saved": True}


@router.post("/api/cards/{id}/save")
def save_card(id: str, session: Session = Depends(get_session)) -> Dict[str, Any]:
    card = session.get(ContextCard, id)
    if not card:
        raise AppException("NOT_FOUND", "Card not found", status_code=404)
    card.saved = True
    card.dismissed = False
    session.add(card)
    session.commit()
    return {"id": card.id, "saved": True}


@router.delete("/api/cards/{id}/save")
def unsave_card(id: str, session: Session = Depends(get_session)) -> Dict[str, Any]:
    card = session.get(ContextCard, id)
    if not card:
        raise AppException("NOT_FOUND", "Card not found", status_code=404)
    card.saved = False
    session.add(card)
    session.commit()
    return {"id": card.id, "saved": False}


@router.post("/api/cards/{id}/dismiss")
def dismiss_card(id: str, session: Session = Depends(get_session)) -> Dict[str, Any]:
    card = session.get(ContextCard, id)
    if not card:
        raise AppException("NOT_FOUND", "Card not found", status_code=404)
    card.dismissed = True
    session.add(card)
    session.commit()
    return {"id": card.id, "dismissed": True}


@router.post("/api/cards/{id}/restore")
def restore_card(id: str, session: Session = Depends(get_session)) -> Dict[str, Any]:
    card = session.get(ContextCard, id)
    if not card:
        raise AppException("NOT_FOUND", "Card not found", status_code=404)
    card.dismissed = False
    session.add(card)
    session.commit()
    return {"id": card.id, "dismissed": False}


@router.get("/api/saved")
def get_saved_cards(session: Session = Depends(get_session)) -> List[Dict[str, Any]]:
    """Returns saved cards with document and chunk context."""
    cards = session.exec(
        select(ContextCard).where(ContextCard.saved == True)
    ).all()

    results: List[Dict[str, Any]] = []
    for card in cards:
        doc = session.get(Document, card.document_id)
        chunk = session.get(ReadingChunk, card.source_chunk_id) if card.source_chunk_id else None

        fallback_title = card.why_here.replace("From: ", "").strip() if (card.why_here and card.why_here.startswith("From: ")) else "Document"
        doc_title = getattr(card, "document_title", None) or (doc.title if (doc and doc.title) else fallback_title)
        seq = chunk.sequence if chunk else 1
        page_ref = getattr(card, "page_reference", None)
        if not page_ref:
            page_ref = "Page 1"
            if chunk and chunk.source_pages_json:
                try:
                    pages = json.loads(chunk.source_pages_json)
                    if len(pages) == 1:
                        page_ref = f"Page {pages[0]}"
                    elif len(pages) >= 2:
                        page_ref = f"Pages {pages[0]}\u2013{pages[-1]}"
                except Exception:
                    pass
        sec_title = getattr(card, "section_title", None) or (chunk.section_title if chunk else None)

        citations = []
        if card.citations_json:
            try:
                citations = json.loads(card.citations_json)
            except Exception:
                pass

        results.append({
            "id": card.id,
            "document_id": card.document_id,
            "document_title": doc_title,
            "chunk_id": card.source_chunk_id,
            "sequence": seq,
            "page_reference": page_ref,
            "card_type": card.card_type,
            "title": card.title,
            "body": card.body,
            "why_here": card.why_here,
            "exact_quote": card.exact_quote,
            "support_status": getattr(card, "support_status", "fully_supported"),
            "citations": citations,
            "saved": True,
        })

    return results
