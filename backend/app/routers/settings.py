import logging
from typing import Any, Dict, List, Optional
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from sqlmodel import Session, select

from app.config import (
    GEMINI_API_KEY_PRIMARY,
    GEMINI_API_KEY_SECONDARY,
    GEMINI_MODEL,
    LLM_API_KEY,
    LLM_BASE_URL,
    LLM_MODEL,
    is_llm_configured,
)
from app.db import get_session
from app.models import AISettings, utc_now
from app.services.llm import LLMService
from app.services.providers import (
    PROVIDER_CONFIGS,
    fetch_provider_models,
    test_provider_model,
)

logger = logging.getLogger("athena.settings")
router = APIRouter(prefix="/api/settings", tags=["settings"])


def _mask_key(key: Optional[str]) -> Optional[str]:
    if not key or len(key.strip()) < 8:
        return None
    k = key.strip()
    return f"{k[:6]}...{k[-4:]}"


class FetchModelsRequest(BaseModel):
    provider: str
    api_key: Optional[str] = None
    base_url: Optional[str] = None


class TestConnectionRequest(BaseModel):
    provider: str
    api_key: Optional[str] = None
    model: Optional[str] = None
    base_url: Optional[str] = None


class SaveAIConfigRequest(BaseModel):
    primary_provider: str
    primary_api_key: Optional[str] = None
    primary_model: Optional[str] = None
    primary_base_url: Optional[str] = None

    fallback_provider: Optional[str] = None
    fallback_api_key: Optional[str] = None
    fallback_model: Optional[str] = None
    fallback_base_url: Optional[str] = None


@router.get("/providers")
async def list_providers():
    """Returns the list of supported providers and their metadata."""
    providers = []
    for key, cfg in PROVIDER_CONFIGS.items():
        providers.append({
            "id": key,
            "name": cfg["name"],
            "base_url": cfg.get("base_url"),
            "default_model": cfg.get("default_model"),
        })
    return {"providers": providers}


@router.post("/fetch-models")
async def fetch_models(payload: FetchModelsRequest, session: Session = Depends(get_session)):
    """Dynamically queries the provider's live models catalog API."""
    api_key = payload.api_key
    # If key wasn't supplied or is masked placeholder, check saved DB setting
    if not api_key or "..." in api_key:
        saved = session.exec(select(AISettings).where(AISettings.id == "global")).first()
        if saved:
            if saved.primary_provider == payload.provider:
                api_key = saved.primary_api_key
            elif saved.fallback_provider == payload.provider:
                api_key = saved.fallback_api_key

    models = await fetch_provider_models(
        provider=payload.provider,
        api_key=api_key,
        base_url=payload.base_url,
    )
    return {"provider": payload.provider, "models": models}


@router.post("/test-connection")
async def test_connection(payload: TestConnectionRequest, session: Session = Depends(get_session)):
    """Tests live connection to the provider with a 5-token completion ping."""
    api_key = payload.api_key
    if not api_key or "..." in api_key:
        saved = session.exec(select(AISettings).where(AISettings.id == "global")).first()
        if saved:
            if saved.primary_provider == payload.provider:
                api_key = saved.primary_api_key
            elif saved.fallback_provider == payload.provider:
                api_key = saved.fallback_api_key

    result = await test_provider_model(
        provider=payload.provider,
        api_key=api_key,
        model=payload.model,
        base_url=payload.base_url,
    )
    return result


@router.get("/ai-config")
async def get_ai_config(session: Session = Depends(get_session)):
    """Returns current active AI engine configuration with masked API keys."""
    saved = session.exec(select(AISettings).where(AISettings.id == "global")).first()

    if saved and (saved.primary_api_key or saved.primary_provider == "custom"):
        return {
            "is_configured": bool(saved.primary_api_key or saved.primary_provider == "custom"),
            "primary_provider": saved.primary_provider,
            "primary_model": saved.primary_model or "",
            "primary_api_key_masked": _mask_key(saved.primary_api_key),
            "primary_base_url": saved.primary_base_url,
            "fallback_provider": saved.fallback_provider,
            "fallback_model": saved.fallback_model,
            "fallback_api_key_masked": _mask_key(saved.fallback_api_key),
            "fallback_base_url": saved.fallback_base_url,
        }

    # Fallback to environment variables if database is empty
    env_gemini = bool(GEMINI_API_KEY_PRIMARY)
    env_llm = bool(LLM_API_KEY)
    is_configured = env_gemini or env_llm

    primary_prov = "gemini" if env_gemini else ("openai" if env_llm else "openrouter")
    primary_model = GEMINI_MODEL if env_gemini else (LLM_MODEL or "")
    masked_key = _mask_key(GEMINI_API_KEY_PRIMARY) if env_gemini else _mask_key(LLM_API_KEY)

    return {
        "is_configured": is_configured,
        "primary_provider": primary_prov,
        "primary_model": primary_model if is_configured else "",
        "primary_api_key_masked": masked_key,
        "primary_base_url": LLM_BASE_URL if env_llm else None,
        "fallback_provider": "gemini" if (env_gemini and GEMINI_API_KEY_SECONDARY) else None,
        "fallback_model": GEMINI_MODEL if (env_gemini and GEMINI_API_KEY_SECONDARY) else None,
        "fallback_api_key_masked": _mask_key(GEMINI_API_KEY_SECONDARY) if env_gemini else None,
        "fallback_base_url": None,
    }


@router.post("/ai-config")
async def save_ai_config(
    payload: SaveAIConfigRequest,
    request: Request,
    session: Session = Depends(get_session),
):
    """Commits new AI configuration and immediately updates pipeline LLM service."""
    saved = session.exec(select(AISettings).where(AISettings.id == "global")).first()
    if not saved:
        saved = AISettings(id="global")
        session.add(saved)

    # Primary provider & key update
    saved.primary_provider = payload.primary_provider
    if payload.primary_api_key and "..." not in payload.primary_api_key:
        saved.primary_api_key = payload.primary_api_key.strip()
    saved.primary_model = payload.primary_model or ""
    saved.primary_base_url = payload.primary_base_url

    # Fallback provider & key update
    saved.fallback_provider = payload.fallback_provider
    if payload.fallback_api_key and "..." not in payload.fallback_api_key:
        saved.fallback_api_key = payload.fallback_api_key.strip()
    elif not payload.fallback_provider:
        saved.fallback_api_key = None
    saved.fallback_model = payload.fallback_model
    saved.fallback_base_url = payload.fallback_base_url
    saved.updated_at = utc_now()

    session.add(saved)
    session.commit()
    session.refresh(saved)

    # Immediately hot-reload pipeline LLMService in memory
    try:
        pipeline = getattr(request.app.state, "pipeline", None)
        if pipeline:
            pipeline.llm_service = LLMService(settings=saved)
            logger.info("Pipeline LLMService hot-reloaded with updated provider settings: %s", saved.primary_provider)
    except Exception as e:
        logger.warning("Could not hot-reload pipeline LLMService: %s", e)

    return {
        "status": "success",
        "message": "AI configuration saved successfully",
        "primary_provider": saved.primary_provider,
        "primary_model": saved.primary_model,
        "fallback_provider": saved.fallback_provider,
        "fallback_model": saved.fallback_model,
    }
