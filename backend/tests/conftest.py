"""Ensure repo-root pytest imports the backend package, never Flutter's app directory."""
from pathlib import Path
import sys

BACKEND_ROOT = str(Path(__file__).resolve().parents[1])
if BACKEND_ROOT in sys.path:
    sys.path.remove(BACKEND_ROOT)
sys.path.insert(0, BACKEND_ROOT)
