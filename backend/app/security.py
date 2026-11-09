"""Shared network destination validation and secret storage for user-supplied URLs and API keys."""
import base64
import hashlib
import ipaddress
from pathlib import Path
import secrets
import socket
from typing import Optional
from urllib.parse import urlsplit

from app.config import DATA_DIR
from app.errors import AppException

_SECRET_FILE = DATA_DIR / ".athena_secret"


def _get_encryption_key() -> bytes:
    """Gets or generates a stable 32-byte master key stored in DATA_DIR/.athena_secret."""
    if _SECRET_FILE.exists():
        try:
            key_data = _SECRET_FILE.read_bytes().strip()
            if len(key_data) == 32:
                return key_data
            elif len(key_data) > 0:
                return hashlib.sha256(key_data).digest()
        except Exception:
            pass
    # Generate new random key
    new_key = secrets.token_bytes(32)
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        _SECRET_FILE.write_bytes(new_key)
    except Exception:
        pass
    return new_key


def encrypt_secret(plain_text: Optional[str]) -> Optional[str]:
    """Transparently encrypts a sensitive string using AES-CTR or keystream."""
    if not plain_text or not plain_text.strip():
        return plain_text
    key = _get_encryption_key()
    data = plain_text.strip().encode("utf-8")
    iv = secrets.token_bytes(16)
    # Keystream generator using SHA-256 blocks: block_i = sha256(key + iv + counter)
    keystream = bytearray()
    counter = 0
    while len(keystream) < len(data):
        keystream.extend(hashlib.sha256(key + iv + counter.to_bytes(4, "big")).digest())
        counter += 1
    cipher = bytes(b ^ k for b, k in zip(data, keystream))
    # Return encoded string with prefix "enc:v1:"
    payload = iv + cipher
    return "enc:v1:" + base64.b64encode(payload).decode("ascii")


def decrypt_secret(cipher_text: Optional[str]) -> Optional[str]:
    """Decrypts a previously encrypted secret. Returns plain text as-is if unencrypted."""
    if not cipher_text:
        return cipher_text
    if not cipher_text.startswith("enc:v1:"):
        return cipher_text
    try:
        raw_b64 = cipher_text[7:]
        payload = base64.b64decode(raw_b64)
        if len(payload) < 17:
            return cipher_text
        iv = payload[:16]
        cipher = payload[16:]
        key = _get_encryption_key()
        keystream = bytearray()
        counter = 0
        while len(keystream) < len(cipher):
            keystream.extend(hashlib.sha256(key + iv + counter.to_bytes(4, "big")).digest())
            counter += 1
        plain = bytes(b ^ k for b, k in zip(cipher, keystream))
        return plain.decode("utf-8")
    except Exception:
        return cipher_text


def validate_provider_http_url(url: str, allow_local: bool = False) -> str:
    """
    Validates provider HTTP URL:
    - Blocks cloud metadata (169.254.169.254, metadata.google.internal).
    - If allow_local=False (standard non-custom providers like OpenAI, Anthropic): requires https:// and non-private global IP.
    - If allow_local=True (custom Ollama/vLLM): allows loopback (127.0.0.1, localhost) and RFC1918 private LAN, but strictly blocks link-local metadata.
    """
    try:
        parsed = urlsplit((url or "").strip())
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("Expected an HTTP(S) URL with a hostname and no embedded credentials")
        if not allow_local and parsed.scheme != "https":
            raise AppException("INSECURE_URL", "Non-local provider URLs must use HTTPS", status_code=400)

        hostname = parsed.hostname.rstrip(".").lower()
        if hostname in {"169.254.169.254", "metadata.google.internal"} or hostname.endswith(".internal"):
            raise AppException("SSRF_BLOCKED", "Requests to cloud metadata endpoints are forbidden", status_code=403)

        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        try:
            addresses = socket.getaddrinfo(hostname, port, type=socket.SOCK_STREAM)
        except Exception as resolve_err:
            if allow_local and hostname in {"localhost", "127.0.0.1", "::1"}:
                return hostname
            raise ValueError("Host did not resolve") from resolve_err

        if not addresses:
            raise ValueError("Host did not resolve")

        for info in addresses:
            addr_str = info[4][0]
            address = ipaddress.ip_address(addr_str)
            if address.is_link_local or str(address) == "169.254.169.254":
                raise AppException("SSRF_BLOCKED", "Requests to link-local metadata addresses are forbidden", status_code=403)
            if not allow_local and not address.is_global:
                raise AppException("SSRF_BLOCKED", "Requests to private or local network addresses are forbidden", status_code=403)

        return hostname
    except AppException:
        raise
    except (ValueError, OSError) as exc:
        raise AppException("INVALID_URL", "Invalid or unresolvable HTTP(S) URL", status_code=400) from exc


def validate_public_http_url(url: str) -> str:
    """Reject local, private, reserved, and metadata destinations before outbound requests."""
    return validate_provider_http_url(url, allow_local=False)

