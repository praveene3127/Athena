import json
import os
import re
from pathlib import Path
import urllib.parse
from fastapi import APIRouter, Query, Request, Response
from fastapi.responses import FileResponse, RedirectResponse

router = APIRouter(tags=["updates"])

GITHUB_REPO_DEFAULT = "praveene3127/Athena"


def _version_data() -> dict:
    root = Path(__file__).resolve().parents[3]
    version_path = root / "scripts" / "version.json"
    try:
        with version_path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError) as exc:
        logger = __import__("logging").getLogger("athena.updates")
        logger.warning("Could not read canonical version metadata at %s: %s", version_path, exc)
        return {}


def parse_semver(v: str) -> tuple:
    nums = [int(x) for x in re.findall(r"\d+", v)]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums[:3])


@router.get("/api/app-update")
def get_app_update(
    request: Request,
    current_version: str = Query("1.1.0", description="Current client app version"),
    platform: str = Query("unknown", description="Client device platform (android, ios, desktop)"),
):
    """Checks for latest Athena client release across Android (.apk) and iOS (.ipa)."""
    version_data = _version_data()
    latest_version = str(version_data.get("version") or "0.0.0")
    github_repo = os.environ.get("GITHUB_REPO", GITHUB_REPO_DEFAULT)

    curr_tuple = parse_semver(current_version)
    latest_tuple = parse_semver(latest_version)
    update_available = latest_tuple > curr_tuple

    release_notes = (
        "Improved Per-Page Document Bouncer, 4-Archetype Marginalia Cards, "
        "and Mobile Touch Ergonomics."
    )
    published_at = version_data.get("published_at")

    android_gh = f"https://github.com/{github_repo}/releases/latest/download/Athena-Android.apk"
    android_raw = version_data.get("github_apk_url") or f"https://github.com/{github_repo}/raw/main/releases/athena-release.apk"

    return {
        "version": latest_version,
        "build_number": version_data.get("build_number", 1),
        "update_available": update_available,
        "current_version": current_version,
        "latest_version": latest_version,
        "release_notes": version_data.get("release_notes", release_notes),
        "published_at": published_at,
        "android": {
            "filename": "Athena-Android.apk",
            "download_url": "/api/download/android",
            "github_release_url": android_gh,
            "github_raw_url": android_raw,
        },
        "ios": {
            "filename": "Athena-iOS.ipa",
            "download_url": "/api/download/ios",
            "github_release_url": f"https://github.com/{github_repo}/releases/latest/download/Athena-iOS.ipa",
            "github_raw_url": f"https://github.com/{github_repo}/raw/main/releases/Athena-iOS.ipa",
        },
    }


def _find_release_file(candidates: list) -> Path | None:
    for c in candidates:
        p = Path(c)
        if p.is_file():
            return p
    return None


@router.get("/api/download/android")
def download_android_apk():
    """Streams local compiled Android APK if present, or redirects to GitHub release asset."""
    base_dir = Path(__file__).resolve().parent.parent.parent
    candidates = [
        base_dir / "data" / "releases" / "Athena-Android.apk",
        base_dir.parent / "releases" / "Athena-Android.apk",
        base_dir.parent / "releases" / "athena-release.apk",
        base_dir.parent / "app" / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk",
        base_dir.parent / "app" / "build" / "app" / "outputs" / "apk" / "release" / "app-release.apk",
    ]
    local_apk = _find_release_file(candidates)
    if local_apk:
        return FileResponse(
            local_apk,
            media_type="application/vnd.android.package-archive",
            filename="Athena-Android.apk",
            headers={"Content-Disposition": 'attachment; filename="Athena-Android.apk"'},
        )

    github_repo = os.environ.get("GITHUB_REPO", GITHUB_REPO_DEFAULT)
    gh_url = f"https://github.com/{github_repo}/releases/latest/download/Athena-Android.apk"
    return RedirectResponse(
        url=gh_url,
        status_code=302,
        headers={"Content-Disposition": 'attachment; filename="Athena-Android.apk"'},
    )


@router.get("/api/download/ios")
def download_ios_ipa():
    """Redirects to GitHub release asset if available."""
    github_repo = os.environ.get("GITHUB_REPO", GITHUB_REPO_DEFAULT)
    gh_url = f"https://github.com/{github_repo}/releases/latest/download/Athena-iOS.ipa"
    return RedirectResponse(
        url=gh_url,
        status_code=302,
        headers={"Content-Disposition": 'attachment; filename="Athena-iOS.ipa"'},
    )




