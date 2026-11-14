import json
from pathlib import Path
import pytest
from sqlmodel import Session

from app.db import engine, init_db
from app.models import Document, utc_now
from app.services.ingestion.jobs import _update_doc_progress

init_db()

CONTRACTS_DIR = Path(__file__).resolve().parents[2] / "contracts"


def test_state_machines_contract_exists_and_defines_10_machines():
    """Prove that contracts/state-machines.json exists and defines all 10 core machines."""
    contract_path = CONTRACTS_DIR / "state-machines.json"
    assert contract_path.exists(), f"Missing contract file: {contract_path}"

    with open(contract_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    machines = data.get("machines", {})
    required_machines = [
        "DocumentLifecycle",
        "ContextEnrichment",
        "IngestionWorkerFgs",
        "AppearanceSettings",
        "ConnectionMode",
        "ReaderViewport",
        "CardSlotSynthesis",
        "CardUserState",
        "AIProviderSlot",
        "SavedVault",
    ]
    for m in required_machines:
        assert m in machines, f"Machine {m} missing from state-machines.json"
        assert "states" in machines[m]
        assert "transitions" in machines[m]
        assert len(machines[m]["states"]) > 0

    # Verify DocumentLifecycle specific invariants
    doc_machine = machines["DocumentLifecycle"]
    assert "ready" in doc_machine["states"]
    assert "processing" in doc_machine["states"]
    assert "processing" not in doc_machine["transitions"]["ready"]

    forbidden = doc_machine.get("forbidden_transitions", [])
    has_ready_to_processing_forbidden = any(
        rule.get("from") == "ready" and rule.get("to") == "processing"
        for rule in forbidden
    )
    assert has_ready_to_processing_forbidden, "ready -> processing must be explicitly forbidden"


def test_update_doc_progress_never_regresses_ready_to_processing():
    """Prove that _update_doc_progress preserves ready state and updates context_status instead."""
    doc_id = "test_doc_ready_preserve_101"
    with Session(engine) as session:
        existing = session.get(Document, doc_id)
        if existing:
            session.delete(existing)
            session.commit()

        doc = Document(
            id=doc_id,
            filename="ready_book.pdf",
            status="ready",
            stage="chunking",
            percent=70,
            context_status="pending",
            created_at=utc_now(),
            updated_at=utc_now(),
        )
        session.add(doc)
        session.commit()

    try:
        with Session(engine) as session:
            # Simulate 72% concept discovery update with default status='processing'
            updated = _update_doc_progress(
                session,
                doc_id=doc_id,
                stage="finding_concepts",
                percent=72,
                status="processing",
            )
            assert updated is not None
            assert updated.status == "ready", "Status MUST remain 'ready' once readable!"
            assert updated.context_status == "finding_concepts"
            assert updated.percent == 72
            assert updated.stage == "finding_concepts"

            # Simulate 75% preparing context update with default status='processing'
            updated2 = _update_doc_progress(
                session,
                doc_id=doc_id,
                stage="preparing_context",
                percent=75,
                status="processing",
            )
            assert updated2 is not None
            assert updated2.status == "ready", "Status MUST remain 'ready'!"
            assert updated2.context_status == "preparing_context"
            assert updated2.percent == 75
    finally:
        with Session(engine) as session:
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
                session.commit()


def test_update_doc_progress_preserves_partially_readable():
    """Prove that _update_doc_progress preserves partially_readable status against processing regression."""
    doc_id = "test_doc_partial_preserve_102"
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
            context_status="pending",
            created_at=utc_now(),
            updated_at=utc_now(),
        )
        session.add(doc)
        session.commit()

    try:
        with Session(engine) as session:
            updated = _update_doc_progress(
                session,
                doc_id=doc_id,
                stage="extracting",
                percent=45,
                status="processing",
            )
            assert updated is not None
            assert updated.status == "partially_readable"
            assert updated.percent == 45
    finally:
        with Session(engine) as session:
            d = session.get(Document, doc_id)
            if d:
                session.delete(d)
                session.commit()
