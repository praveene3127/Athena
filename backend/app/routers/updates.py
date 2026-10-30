import os
import re
from pathlib import Path
from fastapi import APIRouter, Query
from fastapi.responses import FileResponse, RedirectResponse

router = APIRouter(tags=["updates"])

GITHUB_REPO_DEFAULT = "praveene3127/Athena"


def parse_semver(v: str) -> tuple:
    nums = [int(x) for x in re.findall(r"\d+", v)]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums[:3])


@router.get("/api/app-update")
def get_app_update(
    current_version: str = Query("1.1.0", description="Current client app version"),
    platform: str = Query("unknown", description="Client device platform (android, ios, desktop)"),
):
    """Checks for latest Athena client release across Android (.apk) and iOS (.ipa)."""
    latest_version = os.environ.get("ATHENA_LATEST_VERSION", "1.1.0")
    github_repo = os.environ.get("GITHUB_REPO", GITHUB_REPO_DEFAULT)

    curr_tuple = parse_semver(current_version)
    latest_tuple = parse_semver(latest_version)
    update_available = latest_tuple > curr_tuple

    release_notes = (
        "Improved Per-Page Document Bouncer, 4-Archetype Marginalia Cards, "
        "and Mobile Touch Ergonomics."
    )
    published_at = "2026-10-28"

    android_gh = f"https://github.com/{github_repo}/releases/latest/download/Athena-Android.apk"
    ios_gh = f"https://github.com/{github_repo}/releases/latest/download/Athena-iOS.ipa"

    return {
        "update_available": update_available,
        "current_version": current_version,
        "latest_version": latest_version,
        "release_notes": release_notes,
        "published_at": published_at,
        "android": {
            "filename": "Athena-Android.apk",
            "download_url": "/api/download/android",
            "github_release_url": android_gh,
        },
        "ios": {
            "filename": "Athena-iOS.ipa",
            "download_url": "/api/download/ios",
            "github_release_url": ios_gh,
            "altstore_url": f"altstore://install?url={ios_gh}",
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
    """Streams local compiled iOS IPA if present, or redirects to GitHub release asset."""
    base_dir = Path(__file__).resolve().parent.parent.parent
    candidates = [
        base_dir / "data" / "releases" / "Athena-iOS.ipa",
        base_dir.parent / "releases" / "Athena-iOS.ipa",
        base_dir.parent / "releases" / "athena-ios-release.ipa",
        base_dir.parent / "app" / "build" / "ios" / "ipa" / "Athena.ipa",
    ]
    local_ipa = _find_release_file(candidates)
    if local_ipa:
        return FileResponse(
            local_ipa,
            media_type="application/octet-stream",
            filename="Athena-iOS.ipa",
            headers={"Content-Disposition": 'attachment; filename="Athena-iOS.ipa"'},
        )

    github_repo = os.environ.get("GITHUB_REPO", GITHUB_REPO_DEFAULT)
    gh_url = f"https://github.com/{github_repo}/releases/latest/download/Athena-iOS.ipa"
    return RedirectResponse(
        url=gh_url,
        status_code=302,
        headers={"Content-Disposition": 'attachment; filename="Athena-iOS.ipa"'},
    )
