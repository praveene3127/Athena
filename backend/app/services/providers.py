import logging
import re
import time
from typing import Any, Dict, List, Optional
import httpx

logger = logging.getLogger("athena.providers")

DEFAULT_TIMEOUT = 12.0

PROVIDER_CONFIGS = {
    "openrouter": {
        "name": "OpenRouter",
        "base_url": "https://openrouter.ai/api/v1",
        "models_url": "https://openrouter.ai/api/v1/models",
        "auth_type": "bearer",
    },
    "gemini": {
        "name": "Google Gemini",
        "base_url": "https://generativelanguage.googleapis.com/v1beta",
        "models_url": "https://generativelanguage.googleapis.com/v1beta/models",
        "auth_type": "goog_api_key",
    },
    "nvidia": {
        "name": "NVIDIA NIM",
        "base_url": "https://integrate.api.nvidia.com/v1",
        "models_url": "https://integrate.api.nvidia.com/v1/models",
        "auth_type": "bearer",
    },
    "groq": {
        "name": "Groq",
        "base_url": "https://api.groq.com/openai/v1",
        "models_url": "https://api.groq.com/openai/v1/models",
        "auth_type": "bearer",
    },
    "deepseek": {
        "name": "DeepSeek",
        "base_url": "https://api.deepseek.com",
        "models_url": "https://api.deepseek.com/models",
        "auth_type": "bearer",
    },
    "openai": {
        "name": "OpenAI",
        "base_url": "https://api.openai.com/v1",
        "models_url": "https://api.openai.com/v1/models",
        "auth_type": "bearer",
    },
    "anthropic": {
        "name": "Anthropic",
        "base_url": "https://api.anthropic.com/v1",
        "models_url": "https://api.anthropic.com/v1/models",
        "auth_type": "anthropic_header",
    },
    "mistral": {
        "name": "Mistral AI",
        "base_url": "https://api.mistral.ai/v1",
        "models_url": "https://api.mistral.ai/v1/models",
        "auth_type": "bearer",
    },
    "together": {
        "name": "Together AI",
        "base_url": "https://api.together.xyz/v1",
        "models_url": "https://api.together.xyz/v1/models",
        "auth_type": "bearer",
    },
    "custom": {
        "name": "Custom / Local (Ollama, vLLM, LM Studio)",
        "base_url": "http://localhost:11434/v1",
        "models_url": None,
        "auth_type": "bearer",
    },
}

# Zero static models - all models are dynamically discovered via live provider API
NON_CHAT_KEYWORDS = {
    "embedding",
    "embed",
    "whisper",
    "tts",
    "dall-e",
    "moderation",
    "rerank",
    "bge",
    "audio",
    "transcription",
    "image-generation",
}


def _is_chat_model(model_id: str) -> bool:
    low = model_id.lower()
    return not any(kw in low for kw in NON_CHAT_KEYWORDS)


async def fetch_provider_models(
    provider: str,
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """
    Dynamically fetches live available models from the provider's official catalog endpoint.
    Zero static models: returns an empty list if no API key is provided or if the request fails.
    """
    provider_key = provider.lower()
    cfg = PROVIDER_CONFIGS.get(provider_key, PROVIDER_CONFIGS["custom"])
    clean_key = (api_key or "").strip()

    # Unless custom self-hosted endpoint, require a valid API key
    if provider_key != "custom" and (not clean_key or "..." in clean_key):
        return []

    # Determine endpoint URL
    if provider_key == "custom":
        root_url = (base_url or cfg["base_url"]).rstrip("/")
        endpoint = f"{root_url}/models" if not root_url.endswith("/models") else root_url
    else:
        endpoint = cfg.get("models_url") or f"{(base_url or cfg['base_url']).rstrip('/')}/models"

    headers = {"Accept": "application/json"}
    params = {}

    auth_type = cfg.get("auth_type", "bearer")
    if clean_key:
        if auth_type == "bearer":
            headers["Authorization"] = f"Bearer {clean_key}"
        elif auth_type == "anthropic_header":
            headers["x-api-key"] = clean_key
            headers["anthropic-version"] = "2023-06-01"
        elif auth_type in ("goog_api_key", "query_param_or_bearer") or provider_key == "gemini":
            headers["x-goog-api-key"] = clean_key
            params["key"] = clean_key

    try:
        async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, follow_redirects=True) as client:
            resp = await client.get(endpoint, headers=headers, params=params)
            if resp.status_code == 200:
                data = resp.json()
                parsed = _parse_models_response(provider_key, data)
                if parsed:
                    return parsed
            else:
                logger.warning(
                    "Dynamic model fetch for %s failed with HTTP %s: %s",
                    provider_key,
                    resp.status_code,
                    resp.text[:200],
                )
    except Exception as exc:
        logger.warning("Dynamic model fetch for %s encountered error: %s", provider_key, exc)

    # Strictly empty list - never return static or hardcoded fallback models
    return []


def _parse_models_response(provider: str, data: Any) -> List[Dict[str, Any]]:
    """Standardizes disparate provider response schemas into unified model dictionaries."""
    results: List[Dict[str, Any]] = []

    if provider == "gemini":
        raw_list = data.get("models", []) if isinstance(data, dict) else []
        for item in raw_list:
            model_name = item.get("name", "")
            # e.g. "models/gemini-2.5-flash" -> "gemini-2.5-flash"
            slug = model_name.replace("models/", "") if model_name.startswith("models/") else model_name
            # Exclude non-generateContent models or embedding models
            supported_methods = item.get("supportedGenerationMethods", [])
            if supported_methods and "generateContent" not in supported_methods:
                continue
            if not _is_chat_model(slug):
                continue
            results.append({
                "id": slug,
                "name": item.get("displayName") or slug,
                "description": item.get("description", ""),
                "context_length": item.get("inputTokenLimit"),
            })
        return results

    # Standard OpenAI-like response: {"data": [...]}
    raw_list = []
    if isinstance(data, dict):
        raw_list = data.get("data", [])
        if not raw_list and "models" in data:
            raw_list = data.get("models", [])
    elif isinstance(data, list):
        raw_list = data

    for item in raw_list:
        if not isinstance(item, dict):
            continue
        mid = item.get("id") or item.get("name")
        if not mid or not isinstance(mid, str):
            continue
        if not _is_chat_model(mid):
            continue

        name = item.get("name") or item.get("display_name") or mid
        context_len = (
            item.get("context_length")
            or item.get("context_window")
            or item.get("max_tokens")
        )
        description = item.get("description", "")

        results.append({
            "id": mid,
            "name": name,
            "description": description,
            "context_length": context_len,
        })

    # Sort so most relevant/recent models appear first
    results.sort(key=lambda m: (len(m["id"]), m["id"]))
    return results


async def test_provider_model(
    provider: str,
    api_key: Optional[str] = None,
    model: Optional[str] = None,
    base_url: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Executes a connection test against the provider.
    Upon successful authentication, discovers and returns live available models.
    """
    provider_key = provider.lower()
    cfg = PROVIDER_CONFIGS.get(provider_key, PROVIDER_CONFIGS["custom"])
    clean_key = (api_key or "").strip()

    if provider_key != "custom" and (not clean_key or "..." in clean_key):
        return {"ok": False, "latency_ms": 0, "message": "API key is required", "models": []}

    t0 = time.perf_counter()

    if provider_key == "gemini":
        # 1. First test credentials via official models catalog
        models_url = f"https://generativelanguage.googleapis.com/v1beta/models?key={clean_key}"
        try:
            async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT) as client:
                resp = await client.get(models_url)
                latency_ms = int((time.perf_counter() - t0) * 1000)
                if resp.status_code == 200:
                    data = resp.json()
                    live_models = _parse_models_response("gemini", data)
                    return {
                        "ok": True,
                        "latency_ms": latency_ms,
                        "message": f"Verified ({len(live_models)} models discovered)",
                        "models": live_models,
                    }
                else:
                    return {
                        "ok": False,
                        "latency_ms": latency_ms,
                        "message": f"Gemini error {resp.status_code}: {resp.text[:120]}",
                        "models": [],
                    }
        except Exception as e:
            return {"ok": False, "latency_ms": 0, "message": f"Connection failed: {str(e)}", "models": []}

    elif provider_key == "anthropic":
        url = "https://api.anthropic.com/v1/messages"
        headers = {
            "x-api-key": clean_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
        target_model = model or cfg.get("default_model", "claude-3-5-sonnet-20241022")
        payload = {
            "model": target_model,
            "max_tokens": 3,
            "messages": [{"role": "user", "content": "ping"}],
        }
        try:
            async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT) as client:
                resp = await client.post(url, headers=headers, json=payload)
                latency_ms = int((time.perf_counter() - t0) * 1000)
                if resp.status_code == 200:
                    live_models = await fetch_provider_models("anthropic", clean_key, base_url)
                    return {
                        "ok": True,
                        "latency_ms": latency_ms,
                        "message": "Connection verified",
                        "models": live_models,
                    }
                else:
                    return {
                        "ok": False,
                        "latency_ms": latency_ms,
                        "message": f"Anthropic error {resp.status_code}: {resp.text[:120]}",
                        "models": [],
                    }
        except Exception as e:
            return {"ok": False, "latency_ms": 0, "message": f"Connection failed: {str(e)}", "models": []}

    else:
        # OpenAI compatible: test models catalog first, then completion ping
        root_url = (base_url or cfg["base_url"]).rstrip("/")
        models_endpoint = cfg.get("models_url") or f"{root_url}/models"
        headers = {"Accept": "application/json"}
        if clean_key:
            headers["Authorization"] = f"Bearer {clean_key}"

        try:
            async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT) as client:
                resp = await client.get(models_endpoint, headers=headers)
                latency_ms = int((time.perf_counter() - t0) * 1000)
                if resp.status_code == 200:
                    data = resp.json()
                    live_models = _parse_models_response(provider_key, data)
                    return {
                        "ok": True,
                        "latency_ms": latency_ms,
                        "message": f"Verified ({len(live_models)} models discovered)",
                        "models": live_models,
                    }
                elif resp.status_code in (401, 403):
                    return {
                        "ok": False,
                        "latency_ms": latency_ms,
                        "message": f"Authentication failed: HTTP {resp.status_code}",
                        "models": [],
                    }
        except Exception as e:
            logger.debug("Models endpoint check failed, falling back to chat/completions: %s", e)

        # Fallback to chat/completions ping if models endpoint not enabled
        chat_url = f"{root_url}/chat/completions" if not root_url.endswith("/chat/completions") else root_url
        target_model = model or cfg.get("default_model", "gpt-4o-mini")
        payload = {
            "model": target_model,
            "messages": [{"role": "user", "content": "ping"}],
            "max_tokens": 3,
        }
        headers = {"Content-Type": "application/json"}
        if clean_key:
            headers["Authorization"] = f"Bearer {clean_key}"

        try:
            async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT) as client:
                resp = await client.post(chat_url, headers=headers, json=payload)
                latency_ms = int((time.perf_counter() - t0) * 1000)
                if resp.status_code == 200:
                    live_models = await fetch_provider_models(provider_key, clean_key, base_url)
                    return {
                        "ok": True,
                        "latency_ms": latency_ms,
                        "message": "Connection verified",
                        "models": live_models,
                    }
                else:
                    return {
                        "ok": False,
                        "latency_ms": latency_ms,
                        "message": f"Provider error {resp.status_code}: {resp.text[:120]}",
                        "models": [],
                    }
        except Exception as e:
            return {"ok": False, "latency_ms": 0, "message": f"Connection failed: {str(e)}", "models": []}
