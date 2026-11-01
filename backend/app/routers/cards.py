import json
from typing import Any, Dict, List, Optional
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlmodel import Session, select

from app.db import get_session
from app.errors import AppException
from app.models import ContextCard, Document, ReadingChunk

router = APIRouter(tags=["cards"])


class UserQuoteRequest(BaseModel):
    id: str
    document_id: str
    source_chunk_id: Optional[str] = ""
    title: Optional[str] = "Saved Passage"
    body: str
    exact_quote: Optional[str] = None


@router.post("/api/cards/quote")
def create_or_save_user_quote(
    req: UserQuoteRequest, session: Session = Depends(get_session)
) -> Dict[str, Any]:
    """Saves or updates an authentic user passage quote into the SQLite ContextCard vault."""
    card = session.get(ContextCard, req.id)
    if not card:
        card = ContextCard(
            id=req.id,
            document_id=req.document_id,
            source_chunk_id=req.source_chunk_id or "",
            concept_name="Saved Passage",
            card_type="user_highlight",
            title=req.title or "Saved Passage",
            body=req.body,
            why_here="Saved directly by reader",
            exact_quote=req.exact_quote or (req.body[:280] if len(req.body) > 280 else req.body),
            saved=True,
            dismissed=False,
            citations_json="[]",
            support_status="fully_supported",
            generation_mode="user_highlight",
            verified=True,
        )
    else:
        card.saved = True
        card.dismissed = False
        if req.title:
            card.title = req.title
        if req.body:
            card.body = req.body
        if req.exact_quote:
            card.exact_quote = req.exact_quote

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
    """Returns saved cards with document and chunk context (CLAUDE.md §10)."""
    cards = session.exec(
        select(ContextCard).where(ContextCard.saved == True)
    ).all()

    results: List[Dict[str, Any]] = []
    for card in cards:
        doc = session.get(Document, card.document_id)
        chunk = session.get(ReadingChunk, card.source_chunk_id) if card.source_chunk_id else None

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
