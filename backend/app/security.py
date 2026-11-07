"""Shared network destination validation for user supplied URLs."""
import ipaddress
import socket
from urllib.parse import urlsplit

from app.errors import AppException


def validate_public_http_url(url: str) -> str:
    """Reject local, private, reserved, and metadata destinations before outbound requests."""
    try:
        parsed = urlsplit((url or "").strip())
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("Expected an HTTP(S) URL with a hostname and no embedded credentials")
        hostname = parsed.hostname.rstrip(".").lower()
        if hostname in {"localhost", "metadata.google.internal"} or hostname.endswith((".local", ".internal", ".localhost")):
            raise AppException("SSRF_BLOCKED", "Requests to local or metadata addresses are forbidden", status_code=403)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        addresses = socket.getaddrinfo(hostname, port, type=socket.SOCK_STREAM)
        if not addresses:
            raise ValueError("Host did not resolve")
        for info in addresses:
            address = ipaddress.ip_address(info[4][0])
            if not address.is_global:
                raise AppException("SSRF_BLOCKED", "Requests to private or local network addresses are forbidden", status_code=403)
        return hostname
    except AppException:
        raise
    except (ValueError, OSError) as exc:
        raise AppException("INVALID_URL", "Invalid or unresolvable HTTP(S) URL", status_code=400) from exc
