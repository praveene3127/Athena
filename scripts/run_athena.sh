#!/usr/bin/env bash
# Athena Unified Launcher for Linux & macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "================================================================="
echo "               ATHENA COMPANION ENGINE LAUNCHER                  "
echo "================================================================="

cd "${ROOT_DIR}"

# 1. Check Python version (>= 3.10 required)
PYTHON_BIN=""
if command -v python3 &>/dev/null; then
    PYTHON_BIN="python3"
elif command -v python &>/dev/null; then
    PYTHON_BIN="python"
else
    echo "[-] Error: Python is not installed or not in PATH."
    exit 1
fi

PY_VER="$(${PYTHON_BIN} -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_MAJOR="$(echo "${PY_VER}" | cut -d. -f1)"
PY_MINOR="$(echo "${PY_VER}" | cut -d. -f2)"

if [ "${PY_MAJOR}" -lt 3 ] || ([ "${PY_MAJOR}" -eq 3 ] && [ "${PY_MINOR}" -lt 10 ]); then
    echo "[-] Error: Athena requires Python 3.10+ (found ${PY_VER})."
    exit 1
fi

# 2. Setup virtual environment if missing
if [ ! -d ".venv" ]; then
    echo "[+] Creating Python virtual environment in .venv..."
    "${PYTHON_BIN}" -m venv .venv
fi

VENV_PY="${ROOT_DIR}/.venv/bin/python"
VENV_PIP="${ROOT_DIR}/.venv/bin/pip"

# 3. Install/upgrade backend requirements if needed
if [ -f "backend/requirements.txt" ]; then
    echo "[+] Verifying backend dependencies..."
    "${VENV_PIP}" install -q --upgrade pip
    "${VENV_PIP}" install -q -r backend/requirements.txt
fi

# 4. Launch unified supervisor
echo "[+] Starting Athena pipeline supervisor..."
exec "${VENV_PY}" scripts/run_athena.py "$@"

