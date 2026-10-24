import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.db import engine, init_db
from app.main import app
from app.models import AISettings
from app.services.llm import LLMService
from app.services.providers import fetch_provider_models, _parse_models_response, PROVIDER_CONFIGS


@pytest.fixture(autouse=True)
def setup_db():
    init_db()


@pytest.fixture
def client():
    return TestClient(app)


def test_list_providers(client):
    response = client.get("/api/settings/providers")
    assert response.status_code == 200
    data = response.json()
    assert "providers" in data
    provider_ids = [p["id"] for p in data["providers"]]
    assert "openrouter" in provider_ids
    assert "gemini" in provider_ids
    assert "nvidia" in provider_ids
    assert "groq" in provider_ids
    assert "deepseek" in provider_ids
    assert "openai" in provider_ids
    assert "anthropic" in provider_ids
    assert "mistral" in provider_ids
    assert "together" in provider_ids
    assert "custom" in provider_ids


def test_parse_openai_compatible_models():
    sample_data = {
        "data": [
            {"id": "meta/llama-3.3-70b-instruct", "name": "Llama 3.3 70B", "context_length": 131072},
            {"id": "text-embedding-3-small", "name": "Embedding Small"},  # Non-chat, should be excluded
            {"id": "whisper-large-v3", "name": "Whisper"},  # Non-chat, should be excluded
            {"id": "deepseek-ai/deepseek-r1", "name": "DeepSeek R1"},
        ]
    }
    parsed = _parse_models_response("nvidia", sample_data)
    ids = [m["id"] for m in parsed]
    assert "meta/llama-3.3-70b-instruct" in ids
    assert "deepseek-ai/deepseek-r1" in ids
    assert "text-embedding-3-small" not in ids
    assert "whisper-large-v3" not in ids


def test_parse_gemini_models():
    sample_gemini = {
        "models": [
            {
                "name": "models/gemini-2.5-flash",
                "displayName": "Gemini 2.5 Flash",
                "description": "Fast and intelligent model",
                "inputTokenLimit": 1048576,
                "supportedGenerationMethods": ["generateContent"],
            },
            {
                "name": "models/text-embedding-004",
                "displayName": "Embedding 004",
                "supportedGenerationMethods": ["embedContent"],
            },
        ]
    }
    parsed = _parse_models_response("gemini", sample_gemini)
    assert len(parsed) == 1
    assert parsed[0]["id"] == "gemini-2.5-flash"
    assert parsed[0]["name"] == "Gemini 2.5 Flash"
    assert parsed[0]["context_length"] == 1048576


@pytest.mark.anyio
async def test_fetch_provider_models_fallback():
    # Calling with invalid or missing key must strictly return empty list across all providers (no static models)
    for prov in ["gemini", "openai", "openrouter", "anthropic", "groq", "deepseek", "mistral", "together", "nvidia"]:
        models_empty_key = await fetch_provider_models(prov, api_key=None)
        assert models_empty_key == [], f"Provider {prov} leaked static models without API key"

    models_invalid = await fetch_provider_models("groq", api_key="invalid_test_key")
    assert models_invalid == []


def test_ai_config_crud_and_masking(client):
    from sqlmodel import Session, select
    from app.db import engine
    from app.models import AISettings
    existing_attrs = None
    with Session(engine) as s:
        existing = s.exec(select(AISettings).where(AISettings.id == "global")).first()
        if existing:
            existing_attrs = {
                "id": existing.id,
                "primary_provider": existing.primary_provider,
                "primary_api_key": existing.primary_api_key,
                "primary_model": existing.primary_model,
                "primary_base_url": existing.primary_base_url,
                "fallback_provider": existing.fallback_provider,
                "fallback_api_key": existing.fallback_api_key,
                "fallback_model": existing.fallback_model,
                "fallback_base_url": existing.fallback_base_url,
            }

    try:
        # 1. Post new AI config
        payload = {
            "primary_provider": "openrouter",
            "primary_api_key": "sk-or-v1-abcdef1234567890abcdef",
            "primary_model": "anthropic/claude-3.5-sonnet",
            "primary_base_url": "https://openrouter.ai/api/v1",
            "fallback_provider": "groq",
            "fallback_api_key": "gsk_1234567890abcdef123456",
            "fallback_model": "llama-3.3-70b-versatile",
        }
        res = client.post("/api/settings/ai-config", json=payload)
        assert res.status_code == 200
        assert res.json()["status"] == "success"

        # 2. Get AI config - verify masking
        get_res = client.get("/api/settings/ai-config")
        assert get_res.status_code == 200
        cfg = get_res.json()
        assert cfg["is_configured"] is True
        assert cfg["primary_provider"] == "openrouter"
        assert cfg["primary_model"] == "anthropic/claude-3.5-sonnet"
        assert "..." in cfg["primary_api_key_masked"]
        assert cfg["primary_api_key_masked"].startswith("sk-or-")
        assert cfg["fallback_provider"] == "groq"
        assert "..." in cfg["fallback_api_key_masked"]

        # 3. Verify LLMService loads from DB AISettings
        service = LLMService()
        assert service.is_configured is True
        assert service.model == "anthropic/claude-3.5-sonnet"
        assert len(service._openai_clients) == 2  # Primary + Fallback
    finally:
        from sqlmodel import Session, select
        from app.db import engine
        from app.models import AISettings
        with Session(engine) as s:
            row = s.exec(select(AISettings).where(AISettings.id == "global")).first()
            if row:
                s.delete(row)
            if existing_attrs:
                s.add(AISettings(**existing_attrs))
            s.commit()

