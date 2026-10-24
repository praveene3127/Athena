from datetime import datetime, timezone
from typing import Optional
from sqlmodel import Field, SQLModel
import uuid


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Document(SQLModel, table=True):
    __tablename__ = "documents"

    id: str = Field(default_factory=lambda: uuid.uuid4().hex, primary_key=True)
    filename: str
    title: str = ""
    status: str = Field(default="queued", index=True)  # queued | processing | ready | failed
    stage: str = Field(default="validating")
    percent: int = Field(default=0)
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    page_count: int = Field(default=0)

    # Text layer & integrity
    canonical_text: Optional[str] = None
    spans_json: Optional[str] = None  # JSON list of block offset spans stored as TEXT
    integrity_verified: bool = Field(default=False)
    original_checksum: Optional[str] = None
    reconstructed_checksum: Optional[str] = None
    layout_warning: Optional[str] = None  # e.g. "multi_column" or None
    context_status: str = Field(default="pending")  # pending | ready | partial | unavailable

    created_at: datetime = Field(default_factory=utc_now)
    updated_at: datetime = Field(default_factory=utc_now)


class ReadingChunk(SQLModel, table=True):
    __tablename__ = "reading_chunks"

    id: str = Field(primary_key=True)  # {doc_id}-c{seq:04d}
    document_id: str = Field(index=True, foreign_key="documents.id")
    sequence: int = Field(index=True)  # 1-based
    section_title: Optional[str] = None
    raw_text: str
    source_pages_json: str = "[]"  # list of pages (1-indexed) stored as TEXT
    start_offset: int
    end_offset: int
    checksum: str  # sha256 of raw_text
    boundary_method: str = Field(default="paragraph")  # paragraph | sentence
    canonical_sha256: Optional[str] = None


class Concept(SQLModel, table=True):
    __tablename__ = "concepts"

    id: str = Field(default_factory=lambda: uuid.uuid4().hex, primary_key=True)
    document_id: str = Field(index=True, foreign_key="documents.id")
    chunk_id: Optional[str] = Field(default=None, index=True)
    name: str
    type: str = "phrase"  # yake | acronym | entity
    importance: float = 0.5
    status: str = Field(default="candidate")  # candidate | carded | no_source | skipped


class ContextCard(SQLModel, table=True):
    __tablename__ = "context_cards"

    id: str = Field(default_factory=lambda: uuid.uuid4().hex, primary_key=True)
    document_id: str = Field(index=True, foreign_key="documents.id")
    source_chunk_id: str = Field(index=True)
    concept_name: str
    card_type: str = "explain"
    title: str
    body: str
    why_here: str
    citations_json: str = "[]"  # list of citation dicts stored as TEXT
    exact_quote: Optional[str] = None  # Verbatim supporting quote from source chunk
    support_status: str = Field(default="fully_supported")  # fully_supported | partially_supported | unsupported | abstain
    canonical_sha256: Optional[str] = None
    generation_mode: str = "extractive"  # extractive | llm
    verified: bool = True
    saved: bool = Field(default=False)
    dismissed: bool = Field(default=False)
    created_at: datetime = Field(default_factory=utc_now)


class ConceptCache(SQLModel, table=True):
    __tablename__ = "concept_cache"

    concept_slug: str = Field(primary_key=True)
    title: str
    body: str
    citations_json: str
    source_model: str
    created_at: datetime = Field(default_factory=utc_now)


class DocumentChapter(SQLModel, table=True):
    __tablename__ = "document_chapters"

    id: Optional[int] = Field(default=None, primary_key=True)
    doc_id: str = Field(index=True, foreign_key="documents.id")
    level: int = 1
    title: str
    start_page: int = 0
    start_chunk_index: int = 1


class ReadingState(SQLModel, table=True):
    __tablename__ = "reading_state"

    doc_id: str = Field(primary_key=True, foreign_key="documents.id")
    current_chunk_index: int = Field(default=1)
    reading_mode: str = Field(default="feed")  # 'feed' or 'flow'
    updated_at: datetime = Field(default_factory=utc_now)


class AISettings(SQLModel, table=True):
    __tablename__ = "ai_settings"

    id: str = Field(default="global", primary_key=True)
    primary_provider: str = Field(default="openrouter")
    primary_api_key: Optional[str] = Field(default=None)
    primary_model: Optional[str] = Field(default=None)
    primary_base_url: Optional[str] = Field(default=None)

    fallback_provider: Optional[str] = Field(default=None)
    fallback_api_key: Optional[str] = Field(default=None)
    fallback_model: Optional[str] = Field(default=None)
    fallback_base_url: Optional[str] = Field(default=None)

    updated_at: datetime = Field(default_factory=utc_now)


