import time
import secrets
from collections import deque
from threading import Lock
from typing import Any, Dict, Optional
from fastapi import APIRouter, Depends, Header, Query
from pydantic import BaseModel, Field
from sqlmodel import Session, select

from app.config import (
    ASK_MAX_QUESTION_CHARS,
    ASK_RATE_LIMIT,
    ATHENA_CONTEXT_PROXY_TOKEN,
    is_llm_configured,
)
from app.db import get_session
from app.errors import AppException
from app.models import ReadingChunk, ContextCard, DocumentChapter
from app.services.llm import LLMService

router = APIRouter(tags=["ask"])

# In-memory sliding-window rate limiter (12 req / 60 seconds per CLAUDE.md §2 & §8)
_request_timestamps = deque()
_rate_limit_lock = Lock()


def check_rate_limit() -> bool:
    """Returns True if request is allowed, False if rate limited."""
    with _rate_limit_lock:
        now = time.time()
        while _request_timestamps and _request_timestamps[0] < now - 60.0:
            _request_timestamps.popleft()

        if len(_request_timestamps) >= ASK_RATE_LIMIT:
            return False

        _request_timestamps.append(now)
        return True


class AskRequest(BaseModel):
    document_id: str
    chunk_id: str
    question: str = Field(max_length=2000)
    selected_text: Optional[str] = Field(default=None, max_length=16000)


class LocalAskRequest(BaseModel):
    document_id: str = Field(min_length=1, max_length=100)
    chunk_id: str = Field(min_length=1, max_length=150)
    question: str = Field(min_length=1, max_length=2000)
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
    session: Session = Depends(get_session),
) -> Dict[str, Any]:
    """
    Answers reader question using 3-chunk sliding context (§8 in CLAUDE.md).
    Always returns HTTP 200 with status: ok | unverified | unavailable | not_configured | rate_limited.
    """
    # 1. Rate limit check
    if not check_rate_limit():
        return {
            "status": "rate_limited",
            "answer": None,
            "message": "Too many requests. Please wait a moment before asking again.",
        }

    # 2. Configured key check
    if not is_llm_configured():
        return {
            "status": "not_configured",
            "answer": None,
            "message": "Ask needs an AI key. Please configure your key in Settings (AI ENGINES).",
        }

    # 3. Locate target chunk (robustly handles chunk IDs, card IDs, or document fallback)
    chunk = session.get(ReadingChunk, req.chunk_id)
    if not chunk or chunk.document_id != req.document_id:
        card = session.get(ContextCard, req.chunk_id)
        if card and card.document_id == req.document_id:
            chunk = session.get(ReadingChunk, card.source_chunk_id)

    if not chunk or chunk.document_id != req.document_id:
        chunk = session.exec(
            select(ReadingChunk)
            .where(ReadingChunk.document_id == req.document_id)
            .order_by(ReadingChunk.sequence)
        ).first()

    if not chunk:
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
    context_token: Optional[str] = Header(default=None, alias="X-Athena-Context-Token"),
) -> Dict[str, Any]:
    """Authenticated Gemini proxy for excerpts from the phone-local database."""
    if not require_context_proxy_token(context_token):
        raise AppException("UNAUTHORIZED", "AI service authentication failed", status_code=401)
    if not check_rate_limit():
        return {"status": "rate_limited", "answer": None}
    llm = LLMService()
    if not llm.is_gemini_configured:
        return {"status": "not_configured", "answer": None}

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
    context_token: Optional[str] = Header(default=None, alias="X-Athena-Context-Token"),
) -> Dict[str, Any]:
    """Search-grounded context for a phone-local chunk; never accepts a PDF."""
    if not require_context_proxy_token(context_token):
        raise AppException("UNAUTHORIZED", "AI service authentication failed", status_code=401)
    if not check_rate_limit():
        return {"status": "rate_limited", "card": None}
    if req.exact_quote not in req.passage_text:
        return {"status": "invalid_quote", "card": None}

    llm = LLMService()
    if not llm.is_gemini_configured:
        return {"status": "not_configured", "card": None}
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


