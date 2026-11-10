"""Shared network destination validation and secret storage for user-supplied URLs and API keys."""
import base64
import hashlib
import ipaddress
import os
from pathlib import Path
import secrets
import socket
from typing import Optional
from urllib.parse import urlsplit

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.config import DATA_DIR
from app.errors import AppException

_SECRET_FILE = DATA_DIR / ".athena_secret"


def _get_encryption_key() -> bytes:
    """Gets or atomically generates a stable 32-byte master key stored in DATA_DIR/.athena_secret."""
    if _SECRET_FILE.exists():
        try:
            key_data = _SECRET_FILE.read_bytes().strip()
            if len(key_data) == 32:
                return key_data
            elif len(key_data) > 0:
                return hashlib.sha256(key_data).digest()
        except Exception:
            pass
    # Generate new random 32-byte key atomically
    new_key = secrets.token_bytes(32)
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        temp_file = _SECRET_FILE.with_suffix(f".tmp.{secrets.token_hex(6)}")
        temp_file.write_bytes(new_key)
        os.replace(temp_file, _SECRET_FILE)
    except Exception:
        pass
    return new_key


def encrypt_secret(plain_text: Optional[str]) -> Optional[str]:
    """Transparently encrypts a sensitive string using AES-256-GCM (enc:v2:)."""
    if not plain_text or not plain_text.strip():
        return plain_text
    key = _get_encryption_key()
    data = plain_text.strip().encode("utf-8")
    nonce = secrets.token_bytes(12)
    aesgcm = AESGCM(key)
    ciphertext = aesgcm.encrypt(nonce, data, None)
    b64_nonce = base64.b64encode(nonce).decode("ascii")
    b64_ct = base64.b64encode(ciphertext).decode("ascii")
    return f"enc:v2:{b64_nonce}:{b64_ct}"


def decrypt_secret(cipher_text: Optional[str]) -> Optional[str]:
    """
    Decrypts a previously encrypted secret.
    Returns plain text as-is if unencrypted.
    Fails closed (returns "") on tamper or decryption failure.
    """
    if not cipher_text:
        return cipher_text
    if cipher_text.startswith("enc:v2:"):
        parts = cipher_text.split(":")
        if len(parts) != 4:
            return ""
        try:
            nonce = base64.b64decode(parts[2])
            ct = base64.b64decode(parts[3])
            key = _get_encryption_key()
            aesgcm = AESGCM(key)
            plain = aesgcm.decrypt(nonce, ct, None)
            return plain.decode("utf-8")
        except Exception:
            return ""
    if cipher_text.startswith("enc:v1:"):
        # Legacy v1 keystream backward compatibility
        try:
            raw_b64 = cipher_text[7:]
            payload = base64.b64decode(raw_b64)
            if len(payload) < 17:
                return ""
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
            return ""
    return cipher_text


def validate_provider_http_url(url: str, allow_local: bool = False) -> str:
    """
    Validates provider HTTP URL:
    - Blocks cloud metadata (169.254.169.254, metadata.google.internal, fd00:ec2::254).
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
            if address.is_link_local or str(address) == "169.254.169.254" or str(address).lower() == "fd00:ec2::254":
                raise AppException("SSRF_BLOCKED", "Requests to link-local metadata addresses are forbidden", status_code=403)
            if not allow_local and (not address.is_global or address.is_private or address.is_loopback or address.is_reserved or address.is_multicast):
                raise AppException("SSRF_BLOCKED", "Requests to private or local network addresses are forbidden", status_code=403)

        return hostname
    except AppException:
        raise
    except (ValueError, OSError) as exc:
        raise AppException("INVALID_URL", "Invalid or unresolvable HTTP(S) URL", status_code=400) from exc


def validate_public_http_url(url: str) -> str:
    """Reject local, private, reserved, and metadata destinations before outbound requests."""
    return validate_provider_http_url(url, allow_local=False)


