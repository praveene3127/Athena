import os
import socket
import subprocess
import sys
import time
import urllib.request

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.join(ROOT_DIR, "backend")
APP_DIR = os.path.join(ROOT_DIR, "app")
VENV_PYTHON = os.path.join(ROOT_DIR, ".venv", "Scripts", "python.exe")


def get_lan_ip() -> str:
    """Discovers the laptop's Wi-Fi / LAN IP for wireless phone connection."""
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
    print("=" * 68)
    print("           ATHENA UNIFIED PIPELINE SUPERVISOR")
    print(f"  Local API   : http://127.0.0.1:8000/api/health")
    print(f"  Wi-Fi LAN   : http://{lan_ip}:8000  (Connect phone wirelessly)")
    print(f"  Web Reader  : http://127.0.0.1:8080")
    print(f"  Pair Info   : http://127.0.0.1:8000/api/pair-info")
    print("=" * 68)

    try_adb_reverse()

    # Bind Uvicorn to 0.0.0.0 so both localhost and LAN phone can reach it
    backend_cmd = [
        VENV_PYTHON,
        "-m",
        "uvicorn",
        "app.main:app",
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
    ]
    print("[Athena] Starting FastAPI backend on 0.0.0.0:8000...")
    backend_proc = subprocess.Popen(backend_cmd, cwd=BACKEND_DIR)

    proxy_cmd = [VENV_PYTHON, os.path.join(ROOT_DIR, "tools", "port_8080_forwarder.py")]
    print("[Athena] Starting Web Reader bridge on 0.0.0.0:8080...")
    proxy_proc = subprocess.Popen(proxy_cmd, cwd=ROOT_DIR)

    try:
        while True:
            if backend_proc.poll() is not None:
                print("[Athena] Backend exited unexpectedly. Restarting in 2s...")
                time.sleep(2)
                backend_proc = subprocess.Popen(backend_cmd, cwd=BACKEND_DIR)

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
