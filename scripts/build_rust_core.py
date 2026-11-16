#!/usr/bin/env python3
"""
Athena Rust Core Cross-Platform Build Helper.
Builds:
  1. Python C-extension wheel / module via `maturin`
  2. Android jniLibs (.so) via `cargo ndk` (if NDK is configured)
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
RUST_CORE_DIR = ROOT_DIR / "backend" / "rust_core"
CARGO_TOML = RUST_CORE_DIR / "Cargo.toml"
ANDROID_JNI_DIR = ROOT_DIR / "app" / "android" / "app" / "src" / "main" / "jniLibs"


def check_tool(name: str) -> bool:
    return shutil.which(name) is not None


def build_python_module():
    print("=" * 60)
    print("  BUILDING ATHENA RUST CORE (PYTHON MODULE)")
    print("=" * 60)

    # Check maturin in PATH or Python env
    maturin_cmd = None
    if check_tool("maturin"):
        maturin_cmd = ["maturin"]
    else:
        # Check python -m maturin
        try:
            res = subprocess.run(
                [sys.executable, "-m", "maturin", "--version"],
                capture_output=True,
                text=True,
            )
            if res.returncode == 0:
                maturin_cmd = [sys.executable, "-m", "maturin"]
        except Exception:
            pass

    if not maturin_cmd:
        print("[NOTICE] 'maturin' is not installed in the current environment.")
        print("         Pure Python fallbacks (FNV-1a SimHash, FTS5, PyMuPDF) will be used.")
        print("         To enable native acceleration: pip install maturin && pip install -e backend/rust_core")
        return False

    if not check_tool("cargo") and not check_tool("rustc"):
        print("[NOTICE] 'cargo' / 'rustc' not found in PATH.")
        print("         Pure Python fallbacks remain 100% functional.")
        return False

    cmd = maturin_cmd + ["develop", "--release", "--manifest-path", str(CARGO_TOML)]
    print(f"Running: {' '.join(cmd)}")
    try:
        res = subprocess.run(cmd, cwd=str(ROOT_DIR))
        if res.returncode == 0:
            print("[SUCCESS] athena_rust_core compiled and installed successfully.")
            return True
        else:
            print(f"[WARNING] maturin develop returned exit code {res.returncode}.")
            return False
    except Exception as e:
        print(f"[ERROR] Failed to run maturin: {e}")
        return False


def build_android_libraries():
    print("\n" + "=" * 60)
    print("  BUILDING ATHENA RUST CORE (ANDROID NATIVE LIBS)")
    print("=" * 60)

    ndk_home = os.environ.get("ANDROID_NDK_HOME") or os.environ.get("NDK_HOME")
    if not ndk_home or not Path(ndk_home).exists():
        print("[NOTICE] ANDROID_NDK_HOME is not set or directory not found.")
        print("         Skipping Android .so compilation; Dart pure fallbacks will be used.")
        return False

    if not check_tool("cargo-ndk"):
        print("[NOTICE] 'cargo-ndk' is not installed.")
        print("         Install with: cargo install cargo-ndk")
        return False

    targets = [
        ("aarch64-linux-android", "arm64-v8a"),
        ("armv7-linux-androideabi", "armeabi-v7a"),
        ("x86_64-linux-android", "x86_64"),
    ]

    for rust_target, android_abi in targets:
        out_dir = ANDROID_JNI_DIR / android_abi
        out_dir.mkdir(parents=True, exist_ok=True)
        cmd = [
            "cargo", "ndk",
            "-t", android_abi,
            "-o", str(ANDROID_JNI_DIR),
            "build", "--release",
            "--manifest-path", str(CARGO_TOML),
        ]
        print(f"Building for {android_abi}...")
        try:
            res = subprocess.run(cmd, cwd=str(RUST_CORE_DIR))
            if res.returncode != 0:
                print(f"[WARNING] Failed building for {android_abi}")
        except Exception as e:
            print(f"[ERROR] Error running cargo-ndk for {android_abi}: {e}")

    print("[DONE] Android native library build step completed.")
    return True


def verify_availability():
    print("\n" + "=" * 60)
    print("  VERIFYING RUNTIME AVAILABILITY")
    print("=" * 60)
    try:
        import athena_rust_core
        print(f"[OK] athena_rust_core is importable: {athena_rust_core}")
        return True
    except ImportError:
        print("[INFO] athena_rust_core not loaded; running with pure Python/Dart engine.")
        return False


def main():
    build_python_module()
    build_android_libraries()
    verify_availability()


if __name__ == "__main__":
    main()
