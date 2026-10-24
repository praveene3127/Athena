from typing import Any, Dict
from fastapi import Request, status
from fastapi.responses import JSONResponse

ERROR_MESSAGES: Dict[str, str] = {
    "UNSUPPORTED_FILE": "Please choose a PDF or EPUB book.",
    "PDF_UNREADABLE": "This book could not be read.",
    "PDF_ENCRYPTED": "This book is password-protected.",
    "RESOURCE_LIMIT": "This book exceeded the memory or storage available on this PC. Free up resources and retry.",
    "SCANNED_NOT_SUPPORTED": "This looks like a scanned PDF. Athena currently supports digital PDFs with selectable text.",
    "NO_TEXT": "No usable text was found in this PDF.",
    "INTERRUPTED": "Processing was interrupted. Tap retry.",
    "NOT_FOUND": "That item no longer exists.",
    "INTERNAL": "Something went wrong. Please try again.",
    "CONFLICT": "Action conflicts with current item state.",
}


class AppException(Exception):
    """Application-level exception that serializes into the standardized error envelope."""

    def __init__(self, code: str, message: str | None = None, status_code: int = 400):
        self.code = code
        self.message = message or ERROR_MESSAGES.get(code, "Something went wrong. Please try again.")
        self.status_code = status_code
        super().__init__(self.message)


def error_envelope(code: str, message: str | None = None) -> Dict[str, Any]:
    """Builds the standardized error envelope dict."""
    msg = message or ERROR_MESSAGES.get(code, "Something went wrong. Please try again.")
    return {"error": {"code": code, "message": msg}}


async def app_exception_handler(request: Request, exc: AppException) -> JSONResponse:
    """FastAPI handler for AppException."""
    return JSONResponse(
        status_code=exc.status_code,
        content=error_envelope(exc.code, exc.message),
    )


async def generic_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Catch-all handler ensuring even unhandled 500s return the standardized envelope."""
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content=error_envelope("INTERNAL"),
    )
