import re
import time
import secrets
from typing import Any, Dict, Optional
from fastapi import APIRouter, Depends, Header, Request
from pydantic import BaseModel, Field
from sqlmodel import Session, select

from app.config import (
    ASK_RATE_LIMIT,
    ATHENA_CONTEXT_PROXY_TOKEN,
    is_llm_configured,
)
from app.db import get_session
from app.errors import AppException
from app.models import ReadingChunk, ContextCard, DocumentChapter
from app.services.marginalia.llm import LLMService
from app.rate_limit import limiter

router = APIRouter(tags=["ask"])

def check_rate_limit(client_ip: str = "unknown") -> bool:
    """Returns True if this client IP is below the per-minute ask limit."""
    return limiter.allow(f"ask:{client_ip}", ASK_RATE_LIMIT)


ASK_MAX_QUESTION_CHARS = 2000

class AskRequest(BaseModel):
    document_id: str
    chunk_id: str
    question: str = Field(max_length=ASK_MAX_QUESTION_CHARS)
    passage_text: Optional[str] = Field(default=None, max_length=16000)
    selected_text: Optional[str] = Field(default=None, max_length=16000)


class LocalAskRequest(BaseModel):
    document_id: str = Field(min_length=1, max_length=100)
    chunk_id: str = Field(min_length=1, max_length=150)
    question: str = Field(min_length=1, max_length=ASK_MAX_QUESTION_CHARS)
    passage_text: str = Field(min_length=1, max_length=16000)
    neighbors_text: str = Field(default="", max_length=32000)
    selected_text: Optional[str] = Field(default=None, max_length=16000)


class LocalContextRequest(BaseModel):
    document_id: str = Field(min_length=1, max_length=100)
    chunk_id: str = Field(min_length=1, max_length=150)
    concept_name: str = Field(min_length=2, max_length=120)
    passage_text: str = Field(min_length=1, max_length=16000)
    neighbors_text: str = Field(default="", max_length=32000)
    exact_quote: str = Field(min_length=1, max_length=2000)


def require_context_proxy_token(token: Optional[str]) -> bool:
    configured = ATHENA_CONTEXT_PROXY_TOKEN
    return bool(configured and token and secrets.compare_digest(configured, token))


@router.post("/api/ask")
def ask_about_passage(
    req: AskRequest,
    request: Request,
    session: Session = Depends(get_session),
) -> Dict[str, Any]:
    """
    Answers reader question using 3-chunk sliding context.
    Always returns HTTP 200 with status: ok | unverified | unavailable | not_configured | rate_limited.
    """
    # 1. Rate limit check
    if not check_rate_limit(request.client.host if request.client else "unknown"):
        return {
            "status": "rate_limited",
            "answer": None,
            "message": "Too many requests. Please wait a moment before asking again.",
        }

    # 2. Configured key check
    if not is_llm_configured():
        # Immediate grounded passage fallback if no key is configured
        raw_p = req.passage_text or req.selected_text or ""
        if not raw_p and req.chunk_id:
            c_row = session.get(ReadingChunk, req.chunk_id)
            if c_row:
                raw_p = c_row.raw_text
        sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", raw_p) if s.strip()]
        if sentences:
            clean_s = sentences[0]
            for s in sentences:
                if any(w in s.lower() for w in req.question.lower().split() if len(w) > 3):
                    clean_s = s
                    break
            return {
                "status": "llm_not_configured",
                "fallback": True,
                "answer": f"From this passage: {clean_s}",
            }
        return {
            "status": "llm_not_configured",
            "fallback": True,
            "answer": None,
            "message": "Ask needs an AI key. Please configure your key in Settings (AI ENGINES).",
        }

    # 3. Locate target chunk (robustly handles chunk IDs or card IDs)
    chunk = session.get(ReadingChunk, req.chunk_id)
    if not chunk or chunk.document_id != req.document_id:
        card = session.get(ContextCard, req.chunk_id)
        if card and card.document_id == req.document_id:
            chunk = session.get(ReadingChunk, card.source_chunk_id)

    if not chunk or chunk.document_id != req.document_id:
        if req.chunk_id:
            raise AppException("NOT_FOUND", f"Chunk {req.chunk_id} not found in document {req.document_id}", status_code=404)
        chunk = session.exec(
            select(ReadingChunk)
            .where(ReadingChunk.document_id == req.document_id)
            .order_by(ReadingChunk.sequence)
        ).first()

    if not chunk:
        if req.passage_text and req.passage_text.strip():
            # Robust fallback for client passages or excerpts
            passage_text = req.passage_text.strip()
            neighbors_text = "None."
            llm = LLMService()
            status_code, answer = llm.answer_question(
                question=req.question.strip(),
                passage_text=passage_text,
                neighbors_text=neighbors_text,
            )
            return {
                "status": status_code,
                "answer": answer,
            }
        raise AppException("NOT_FOUND", "Target chunk not found", status_code=404)

    # 4. Fetch enriched sliding context: chapter, neighbors [chunk-2..chunk+1], and verified cards
    neighbor_parts = []

    # Active chapter outline
    active_chapter = session.exec(
        select(DocumentChapter)
        .where(
            DocumentChapter.doc_id == req.document_id,
            DocumentChapter.start_chunk_index <= chunk.sequence,
        )
        .order_by(DocumentChapter.start_chunk_index.desc())
    ).first()
    if active_chapter:
        neighbor_parts.append(f"CURRENT CHAPTER: {active_chapter.title}")

    # Chunks [chunk - 2, chunk - 1, chunk + 1]
    surrounding_chunks = session.exec(
        select(ReadingChunk)
        .where(
            ReadingChunk.document_id == req.document_id,
            ReadingChunk.sequence.in_([chunk.sequence - 2, chunk.sequence - 1, chunk.sequence + 1]),
        )
        .order_by(ReadingChunk.sequence)
    ).all()

    for sc in surrounding_chunks:
        if sc.sequence < chunk.sequence:
            neighbor_parts.append(f"PRECEDING PASSAGE (Chunk {sc.sequence}):\n{sc.raw_text.strip()}")
        else:
            neighbor_parts.append(f"SUBSEQUENT PASSAGE (Chunk {sc.sequence}):\n{sc.raw_text.strip()}")

    # Verified Context Cards in this local range
    relevant_chunk_ids = [chunk.id] + [sc.id for sc in surrounding_chunks]
    cards = session.exec(
        select(ContextCard).where(
            ContextCard.document_id == req.document_id,
            ContextCard.source_chunk_id.in_(relevant_chunk_ids),
            ContextCard.dismissed == False,
        )
    ).all()
    for card in cards:
        neighbor_parts.append(f"VERIFIED CONTEXT NOTE ({card.title}):\n{card.body.strip()}")

    neighbors_text = "\n\n".join(neighbor_parts) if neighbor_parts else "None."


    # Use selected text if provided and in chunk, otherwise full chunk
    passage_text = chunk.raw_text.strip()
    if req.selected_text and req.selected_text.strip() in passage_text:
        passage_text = req.selected_text.strip()
    elif req.passage_text and req.passage_text.strip():
        passage_text = req.passage_text.strip()

    # 5. Call LLM service
    llm = LLMService()
    status_code, answer = llm.answer_question(
        question=req.question.strip(),
        passage_text=passage_text,
        neighbors_text=neighbors_text,
    )

    return {
        "status": status_code,
        "answer": answer,
    }


@router.post("/api/ask/local")
def ask_about_local_passage(
    req: LocalAskRequest,
    request: Request,
    context_token: Optional[str] = Header(default=None, alias="X-Athena-Context-Token"),
) -> Dict[str, Any]:
    """Authenticated Gemini proxy for excerpts from the phone-local database."""
    if not require_context_proxy_token(context_token):
        raise AppException("UNAUTHORIZED", "AI service authentication failed", status_code=401)
    if not check_rate_limit(request.client.host if request.client else "unknown"):
        return {"status": "rate_limited", "answer": None}
    llm = LLMService()
    if not llm.is_configured:
        return {"status": "no_key", "answer": None}

    passage = req.passage_text.strip()
    if req.selected_text and req.selected_text.strip() in passage:
        passage = req.selected_text.strip()
    status, answer = llm.answer_question(
        question=req.question.strip(),
        passage_text=passage,
        neighbors_text=req.neighbors_text.strip() or "None.",
    )
    return {"status": status, "answer": answer}


@router.post("/api/context/local")
def generate_local_context(
    req: LocalContextRequest,
    request: Request,
    context_token: Optional[str] = Header(default=None, alias="X-Athena-Context-Token"),
) -> Dict[str, Any]:
    """Search-grounded context for a phone-local chunk; never accepts a PDF."""
    if not require_context_proxy_token(context_token):
        raise AppException("UNAUTHORIZED", "AI service authentication failed", status_code=401)
    if not check_rate_limit(request.client.host if request.client else "unknown"):
        return {"status": "rate_limited", "card": None}
    if req.exact_quote not in req.passage_text:
        return {"status": "invalid_quote", "card": None}

    llm = LLMService()
    if not llm.is_configured:
        return {"status": "no_key", "card": None}
    context = llm.generate_grounded_context(
        concept_name=req.concept_name.strip(),
        passage_text=req.passage_text.strip(),
        neighbors_text=req.neighbors_text.strip() or "None.",
    )
    if not context:
        return {"status": "no_verified_sources", "card": None}
    return {
        "status": "ready",
        "card": {
            "title": req.concept_name.strip(),
            "body": context["body"],
            "citations": context["citations"],
            "exact_quote": req.exact_quote,
        },
    }


