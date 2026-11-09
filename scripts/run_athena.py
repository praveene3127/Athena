#!/usr/bin/env python3
"""
Athena Unified Pipeline Supervisor (scripts/run_athena.py).
Launches FastAPI backend companion engine and Web Reader forwarder,
manages local/LAN IP resolution, pairing tokens, adb reverse, and crash supervision.
"""

import argparse
import ipaddress
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

# Python version enforcement (P0-5)
if sys.version_info < (3, 10):
    sys.stderr.write(
        f"Error: Athena requires Python 3.10 or higher. Found {sys.version.split()[0]}.\n"
    )
    sys.exit(1)

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND_DIR = os.path.join(ROOT_DIR, "backend")
APP_DIR = os.path.join(ROOT_DIR, "app")
VENV_PYTHON = str(
    Path(ROOT_DIR) / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
)
if not os.path.isfile(VENV_PYTHON):
    VENV_PYTHON = sys.executable


def get_lan_ip() -> str:
    """Discovers the host's Wi-Fi / LAN IP for wireless phone connection."""
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


def try_adb_reverse(port: int = 8000):
    """Automatically configures USB reverse tunneling if an Android device is attached."""
    try:
        res = subprocess.run(
            ["adb", "devices"], capture_output=True, text=True, timeout=3
        )
        lines = [line for line in res.stdout.splitlines()[1:] if "\tdevice" in line]
        if lines:
            subprocess.run(
                ["adb", "reverse", f"tcp:{port}", f"tcp:{port}"],
                capture_output=True,
                timeout=3,
            )
            print(f"[Athena] USB Android device connected -> adb reverse tcp:{port} configured.")
    except (FileNotFoundError, Exception):
        pass


def is_healthy(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            return resp.status == 200
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(description="Athena Unified Pipeline Supervisor")
    parser.add_argument(
        "--lan",
        action="store_true",
        default=os.environ.get("ATHENA_BIND_LAN", "").lower() in {"1", "true"},
        help="Bind to 0.0.0.0 and expose on local Wi-Fi/LAN for phone pairing",
    )
    parser.add_argument(
        "--host",
        type=str,
        default=None,
        help="Host address to bind (default: 0.0.0.0 if --lan, else 127.0.0.1)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("ATHENA_PORT", 8000)),
        help="Port to run FastAPI on (default: 8000)",
    )
    parser.add_argument(
        "--web-port",
        type=int,
        default=int(os.environ.get("ATHENA_WEB_PORT", 8080)),
        help="Port for Web Reader forwarder (default: 8080)",
    )

    args = parser.parse_args()
    bind_lan = args.lan
    port = args.port
    web_port = args.web_port
    lan_ip = get_lan_ip()

    if args.host:
        host = args.host
    else:
        host = "0.0.0.0" if bind_lan else "127.0.0.1"

    pairing_token = os.environ.get("ATHENA_PAIRING_TOKEN", "").strip()
    if not pairing_token and bind_lan:
        pairing_token = secrets.token_hex(16)
        os.environ["ATHENA_PAIRING_TOKEN"] = pairing_token

    print("=" * 68)
    print("           ATHENA UNIFIED PIPELINE SUPERVISOR")
    print(f"  Local API   : http://127.0.0.1:{port}/api/health")
    if bind_lan:
        print(f"  Wi-Fi LAN   : http://{lan_ip}:{port}  (Connect phone wirelessly)")
        print(f"  Pair Token  : {pairing_token}  (Enter in App -> Server Settings)")
    else:
        print(f"  Host Mode   : Localhost ({host}) — pass --lan to expose on Wi-Fi")
    print(f"  Web Reader  : http://127.0.0.1:{web_port}")
    print(f"  Pair Info   : http://127.0.0.1:{port}/api/pair-info")
    print("=" * 68)

    if bind_lan:
        print("\n" + "=" * 68)
        print(" [!] ATHENA WI-FI PAIRING INSTRUCTIONS")
        print("=" * 68)
        print(f"  Server URL   : http://{lan_ip}:{port}")
        print(f"  Pairing Token: {pairing_token}")
        print("-" * 68)
        print("  In the Athena Android/iOS App:")
        print("    1. Open Settings -> Server Host")
        print(f"    2. Enter Server URL : http://{lan_ip}:{port}")
        print(f"    3. Enter Token      : {pairing_token}")
        print("    4. Tap 'Test Server Connection'")
        print("=" * 68)
        try:
            import io
            import qrcode
            qr = qrcode.QRCode(border=1)
            qr.add_data(f"athena://pair?server=http://{lan_ip}:{port}&token={pairing_token}")
            f = io.StringIO()
            qr.print_ascii(out=f, invert=True)
            print("\nScan to Pair:")
            print(f.getvalue())
        except Exception:
            pass

    try_adb_reverse(port)

    backend_env = os.environ.copy()
    backend_env["ATHENA_HOST"] = host
    backend_env["ATHENA_PORT"] = str(port)
    backend_env["ATHENA_WEB_PORT"] = str(web_port)
    backend_env["ATHENA_BIND_LAN"] = "1" if bind_lan else "0"
    if pairing_token:
        backend_env["ATHENA_PAIRING_TOKEN"] = pairing_token

    backend_cmd = [
        VENV_PYTHON,
        "-m",
        "uvicorn",
        "app.main:app",
        "--host",
        host,
        "--port",
        str(port),
    ]
    print(f"[Athena] Starting FastAPI backend on {host}:{port}...")
    backend_proc = subprocess.Popen(backend_cmd, cwd=BACKEND_DIR, env=backend_env)

    proxy_cmd = [VENV_PYTHON, os.path.join(ROOT_DIR, "scripts", "port_8080_forwarder.py")]
    print(f"[Athena] Starting Web Reader bridge on 0.0.0.0:{web_port}...")
    proxy_proc = subprocess.Popen(proxy_cmd, cwd=ROOT_DIR)

    crash_count = 0
    backoff_seconds = 2
    max_crashes = 5

    try:
        while True:
            time.sleep(2)
            if backend_proc.poll() is not None:
                crash_count += 1
                exit_code = backend_proc.poll()
                print(
                    f"[Athena] Backend exited unexpectedly with code {exit_code} "
                    f"({crash_count}/{max_crashes})."
                )
                if crash_count >= max_crashes:
                    print(
                        f"[Athena] Backend crashed {max_crashes} consecutive times. "
                        "Aborting supervisor loop to avoid tight spinning."
                    )
                    proxy_proc.terminate()
                    sys.exit(1)

                print(f"[Athena] Restarting backend in {backoff_seconds}s...")
                time.sleep(backoff_seconds)
                backoff_seconds = min(backoff_seconds * 2, 16)
                backend_proc = subprocess.Popen(backend_cmd, cwd=BACKEND_DIR, env=backend_env)
            else:
                # Backend running normally; reset crash count after 30s of stability
                crash_count = 0
                backoff_seconds = 2

            if proxy_proc.poll() is not None:
                proxy_proc = subprocess.Popen(proxy_cmd, cwd=ROOT_DIR)

            try_adb_reverse(port)
            time.sleep(8)
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
