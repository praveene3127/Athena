import json
from pathlib import Path
import pytest

from app import config
from app.services.ingestion.chunker import chunk_document


def _load_contract() -> dict:
    contract_file = Path(__file__).resolve().parent.parent.parent / "contracts" / "athena-contract.json"
    assert contract_file.exists(), f"Contract file missing at {contract_file}"
    return json.loads(contract_file.read_text(encoding="utf-8"))


def test_python_config_matches_canonical_contract():
    contract = _load_contract()

    # Document states
    assert config.DOCUMENT_STATES == contract["document_states"]

    # Segmentation policy
    sp = contract["segmentation_policy"]
    assert config.TARGET_CHUNK_WORDS == sp["target_words"]
    assert config.MIN_CHUNK_WORDS == sp["min_words"]
    assert config.MAX_CHUNK_WORDS == sp["max_words"]
    assert config.MAX_CHUNK_CHARS == sp["soft_max_chars"]
    assert config.CHUNK_ID_PAD_WIDTH == sp["chunk_id_pad_width"]
    assert config.SEGMENTATION_VERSION == sp["version"]
    assert config.OFFSET_PROTOCOL == sp["offset_protocol"]

    # Limits
    limits = contract["limits"]
    assert config.ASK_MAX_QUESTION_CHARS == limits["ask_max_question_chars"]
    assert config.CARD_MAX_WORDS == limits["card_max_words"]
    assert config.STATUS_POLL_MS == limits["status_poll_ms"]

    # Method Channel
    mc = contract["method_channel"]
    assert config.METHOD_CHANNEL_NAME == mc["channel"]
    assert config.METHOD_CHANNEL_METHODS == mc["methods"]


def test_kotlin_main_activity_matches_contract():
    contract = _load_contract()
    kt_path = (
        Path(__file__).resolve().parent.parent.parent
        / "app"
        / "android"
        / "app"
        / "src"
        / "main"
        / "kotlin"
        / "com"
        / "athena"
        / "reading"
        / "MainActivity.kt"
    )
    assert kt_path.exists()
    content = kt_path.read_text(encoding="utf-8")

    # Channel check
    assert contract["method_channel"]["channel"] in content

    # Methods check
    for method in contract["method_channel"]["methods"]:
        assert f'"{method}"' in content, f"MainActivity.kt missing contract method {method}"


def test_rust_chunker_matches_contract():
    contract = _load_contract()
    rust_path = (
        Path(__file__).resolve().parent.parent.parent
        / "backend"
        / "rust_core"
        / "src"
        / "chunker.rs"
    )
    assert rust_path.exists()
    content = rust_path.read_text(encoding="utf-8")

    sp = contract["segmentation_policy"]
    assert f'pub const DEFAULT_TARGET_WORDS: usize = {sp["target_words"]};' in content
    assert f'pub const MIN_CHUNK_WORDS: usize = {sp["min_words"]};' in content
    assert f'pub const MAX_CHUNK_WORDS: usize = {sp["max_words"]};' in content
    assert f'pub const MAX_CHUNK_CHARS: usize = {sp["soft_max_chars"]};' in content
    assert f'pub const CHUNK_ID_PAD_WIDTH: usize = {sp["chunk_id_pad_width"]};' in content
    assert f'pub const SEGMENTATION_VERSION: &str = "{sp["version"]}";' in content
    assert f'pub const OFFSET_PROTOCOL: &str = "{sp["offset_protocol"]}";' in content


def test_golden_chunking_fixture():
    contract = _load_contract()
    fixture = contract["golden_fixture"]
    text = fixture["sample_text"]

    spans = [{"start": 0, "end": len(text), "page_number": 1}]
    chunks = chunk_document("contract_test", text, spans)
    assert len(chunks) >= 1
    # Lossless byte exactness check
    reconstructed = "".join(c["raw_text"] for c in chunks)
    assert reconstructed == text

    # Word count check
    words = sum(len(c["raw_text"].split()) for c in chunks)
    assert words == fixture["expected_word_count"]
