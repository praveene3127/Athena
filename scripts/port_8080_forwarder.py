#!/usr/bin/env python3
"""
Lightweight port 8080 bridge for Athena.
Transparently proxies http://127.0.0.1:8080 to the Athena backend on http://127.0.0.1:8000.
Allows start_athena.bat and browser bookmarks targeting 8080 to connect seamlessly.
"""

import http.server
import socketserver
import urllib.request
import urllib.error

TARGET = "http://127.0.0.1:8000"


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_PUT(self):
        self._proxy("PUT")

    def do_DELETE(self):
        self._proxy("DELETE")

    def do_OPTIONS(self):
        self._proxy("OPTIONS")

    def do_HEAD(self):
        self._proxy("HEAD")

    def _proxy(self, method):
        url = f"{TARGET}{self.path}"
        content_len = int(self.headers.get("Content-Length", 0))
        data = self.rfile.read(content_len) if content_len > 0 else None
        headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in ("transfer-encoding", "content-length"):
                        self.send_header(k, v)
                resp_data = resp.read()
                self.send_header("Content-Length", str(len(resp_data)))
                self.end_headers()
                self.wfile.write(resp_data)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for k, v in e.headers.items():
                if k.lower() not in ("transfer-encoding", "content-length"):
                    self.send_header(k, v)
            err_data = e.read()
            self.send_header("Content-Length", str(len(err_data)))
            self.end_headers()
            self.wfile.write(err_data)
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(f"Bad Gateway: {e}".encode())

    def log_message(self, format, *args):
        pass


def main():
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("0.0.0.0", 8080), ProxyHandler) as httpd:
        print("[Athena] Port 8080 forwarder running -> 127.0.0.1:8000")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
