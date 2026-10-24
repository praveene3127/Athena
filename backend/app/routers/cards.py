import json
from typing import Any, Dict, List
from fastapi import APIRouter, Depends
from sqlmodel import Session, select

from app.db import get_session
from app.errors import AppException
from app.models import ContextCard, Document, ReadingChunk

router = APIRouter(tags=["cards"])


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
    """Returns saved cards with document and chunk context (CLAUDE.md §10)."""
    cards = session.exec(
        select(ContextCard).where(ContextCard.saved == True)
    ).all()

    results: List[Dict[str, Any]] = []
    for card in cards:
        doc = session.get(Document, card.document_id)
        chunk = session.get(ReadingChunk, card.source_chunk_id)

        doc_title = doc.title if doc else "Document"
        seq = chunk.sequence if chunk else 1
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
            "citations": citations,
            "saved": True,
        })

    return results
