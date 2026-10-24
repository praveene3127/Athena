from google.genai.errors import APIError

from app.services.llm import LLMService


def test_gemini_quota_error_fails_over_to_secondary_account():
    service = LLMService()
    primary, secondary = object(), object()
    service._gemini_clients = [primary, secondary]
    calls = []

    def request(client):
        calls.append(client)
        if client is primary:
            raise APIError(429, {"message": "quota exceeded"})
        return "grounded context from secondary"

    result = service._call_gemini_with_key_failover(request)
    assert result == "grounded context from secondary"
    assert calls == [primary, secondary]


def test_gemini_non_retryable_error_does_not_switch_accounts():
    service = LLMService()
    primary, secondary = object(), object()
    service._gemini_clients = [primary, secondary]
    calls = []

    def request(client):
        calls.append(client)
        raise APIError(400, {"message": "invalid request"})

    try:
        service._call_gemini_with_key_failover(request)
    except APIError as error:
        assert error.code == 400
    else:
        raise AssertionError("Expected a non-retryable provider error")

    assert calls == [primary]


def test_gemini_service_error_tries_secondary():
    service = LLMService()
    primary, secondary = object(), object()
    service._gemini_clients = [primary, secondary]
    calls = []

    def request(client):
        calls.append(client)
        if client is primary:
            raise APIError(503, {"message": "temporarily unavailable"})
        return "answer"

    assert service._call_gemini_with_key_failover(request) == "answer"
    assert calls == [primary, secondary]
