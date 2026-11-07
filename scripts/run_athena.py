import os
import ipaddress
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND_DIR = os.path.join(ROOT_DIR, "backend")
APP_DIR = os.path.join(ROOT_DIR, "app")
VENV_PYTHON = str(Path(ROOT_DIR) / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python"))
if not os.path.isfile(VENV_PYTHON):
    VENV_PYTHON = sys.executable


def get_lan_ip() -> str:
    """Discovers the laptop's Wi-Fi / LAN IP for wireless phone connection."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            address = s.getsockname()[0]
            if address and not address.startswith("127."):
                return address
    except Exception:
        pass
    try:
        local_addresses = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
        for info in local_addresses:
            address = info[4][0]
            if ipaddress.ip_address(address).is_private and not address.startswith("169.254."):
                return address
    except Exception:
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"


def try_adb_reverse():
    """Automatically configures USB reverse tunneling if an Android device is attached."""
    try:
        res = subprocess.run(
            ["adb", "devices"], capture_output=True, text=True, timeout=3
        )
        lines = [line for line in res.stdout.splitlines()[1:] if "\tdevice" in line]
        if lines:
            subprocess.run(["adb", "reverse", "tcp:8000", "tcp:8000"], capture_output=True, timeout=3)
            print("[Athena] USB Android device connected -> adb reverse tcp:8000 configured.")
    except FileNotFoundError:
        pass
    except Exception:
        pass


def is_healthy(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            return resp.status == 200
    except Exception:
        return False


def main():
    lan_ip = get_lan_ip()
    bind_lan = "--lan" in sys.argv or os.environ.get("ATHENA_BIND_LAN", "").lower() in {"1", "true"}
    host = "0.0.0.0" if bind_lan else "127.0.0.1"

    pairing_token = os.environ.get("ATHENA_PAIRING_TOKEN", "").strip()
    if not pairing_token and bind_lan:
        import secrets
        pairing_token = secrets.token_hex(16)
        os.environ["ATHENA_PAIRING_TOKEN"] = pairing_token

    print("=" * 68)
    print("           ATHENA UNIFIED PIPELINE SUPERVISOR")
    print(f"  Local API   : http://127.0.0.1:8000/api/health")
    if bind_lan:
        print(f"  Wi-Fi LAN   : http://{lan_ip}:8000  (Connect phone wirelessly)")
        print(f"  Pair Token  : {pairing_token}  (Enter in App -> Server Settings)")
    else:
        print(f"  Host Mode   : Localhost (127.0.0.1) — pass --lan to expose on Wi-Fi")
    print(f"  Web Reader  : http://127.0.0.1:8080")
    print(f"  Pair Info   : http://127.0.0.1:8000/api/pair-info")
    print("=" * 68)

    try_adb_reverse()

    backend_env = os.environ.copy()
    if pairing_token:
        backend_env["ATHENA_PAIRING_TOKEN"] = pairing_token
    if bind_lan:
        backend_env["ATHENA_BIND_LAN"] = "1"

    # Default to 127.0.0.1 unless --lan is passed
    backend_cmd = [
        VENV_PYTHON,
        "-m",
        "uvicorn",
        "app.main:app",
        "--host",
        host,
        "--port",
        "8000",
    ]
    print(f"[Athena] Starting FastAPI backend on {host}:8000...")
    backend_proc = subprocess.Popen(backend_cmd, cwd=BACKEND_DIR, env=backend_env)

    proxy_cmd = [VENV_PYTHON, os.path.join(ROOT_DIR, "scripts", "port_8080_forwarder.py")]
    print("[Athena] Starting Web Reader bridge on 0.0.0.0:8080...")
    proxy_proc = subprocess.Popen(proxy_cmd, cwd=ROOT_DIR)

    try:
        while True:
            if backend_proc.poll() is not None:
                print("[Athena] Backend exited unexpectedly. Restarting in 2s...")
                time.sleep(2)
                backend_proc = subprocess.Popen(backend_cmd, cwd=BACKEND_DIR, env=backend_env)

            if proxy_proc.poll() is not None:
                proxy_proc = subprocess.Popen(proxy_cmd, cwd=ROOT_DIR)

            try_adb_reverse()
            time.sleep(10)
    except KeyboardInterrupt:
        print("\n[Athena] Shutting down supervisor cleanly...")
        backend_proc.terminate()
        proxy_proc.terminate()
        try:
            backend_proc.wait(timeout=5)
            proxy_proc.wait(timeout=5)
        except Exception:
            backend_proc.kill()
            proxy_proc.kill()
        sys.exit(0)


if __name__ == "__main__":
    main()
