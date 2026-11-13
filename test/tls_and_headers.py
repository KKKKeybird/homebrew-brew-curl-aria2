#!/usr/bin/env python3
"""Verify real TLS trust and unconsumed stdin authentication during fallback."""
import hashlib
import http.server
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
DATA = os.urandom(3 * 1024 * 1024)


class Handler(http.server.BaseHTTPRequestHandler):
    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        if self.path == "/authenticated" and self.headers.get("Authorization") != "Bearer acceptance-secret":
            self.send_error(401)
            return
        start, end = 0, len(DATA) - 1
        value = self.headers.get("Range")
        if value:
            first, last = value.removeprefix("bytes=").split("-", 1)
            start = int(first)
            if last:
                end = min(int(last), end)
        self.send_response(206 if value else 200)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if value:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(DATA)}")
        self.end_headers()
        if body:
            try:
                self.wfile.write(DATA[start:end + 1])
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass


with tempfile.TemporaryDirectory(prefix="aria2-trust-") as temporary:
    tmp = Path(temporary)
    for name in ("server", "other"):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", f"/CN={name}", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-keyout", str(tmp / f"{name}.key"), "-out", str(tmp / f"{name}.pem")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(tmp / "server.pem", tmp / "server.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HOMEBREW_", "BREW_CURL_ARIA2_"))}
    if shutil.which("brew"):
        env["HOMEBREW_PREFIX"] = subprocess.check_output(["brew", "--prefix"], text=True).strip()
    env.update(HOMEBREW_BREW_CURL_ARIA2_LOG=str(tmp / "decisions.log"),
               HOMEBREW_BREW_CURL_ARIA2_PROGRESS="0", no_proxy="127.0.0.1", NO_PROXY="127.0.0.1")

    def download(name, ca, extra=(), path="/file", headers=None):
        output = tmp / name
        command = [str(ROOT / "libexec/curl-aria2"), "--disable", "--fail", "--location", "--silent",
                   "--show-error", "--cacert", str(ca), *extra, "--output", str(output),
                   f"https://127.0.0.1:{server.server_port}{path}"]
        result = subprocess.run(command, input=headers, env=env, capture_output=True, timeout=60)
        return result, output

    try:
        result, output = download("valid", tmp / "server.pem", ("--capath", str(tmp)))
        assert result.returncode == 0, result.stderr.decode()
        assert hashlib.sha256(output.read_bytes()).digest() == hashlib.sha256(DATA).digest()
        assert "backend=aria2c" in (tmp / "decisions.log").read_text()

        result, output = download("invalid", tmp / "other.pem", ("--capath", str(tmp)))
        assert result.returncode != 0, "untrusted server certificate was accepted"

        result, output = download("authenticated", tmp / "server.pem", ("--header", "@-"),
                                  path="/authenticated", headers=b"Authorization: Bearer acceptance-secret\n")
        assert result.returncode == 0, result.stderr.decode()
        assert output.read_bytes() == DATA
        log = (tmp / "decisions.log").read_text()
        assert "reason=header-file" in log
        assert "acceptance-secret" not in log

        cert_hash = subprocess.check_output(["openssl", "x509", "-hash", "-noout", "-in", str(tmp / "server.pem")], text=True).strip()
        (tmp / f"{cert_hash}.0").symlink_to(tmp / "server.pem")
        result, output = download("directory-trust", tmp / "other.pem", ("--capath", str(tmp)))
        assert result.returncode == 0, result.stderr.decode()
        assert output.read_bytes() == DATA
        assert "reason=hashed-ca-directory" in (tmp / "decisions.log").read_text()
        print("PASS: aria2 TLS bundle trust, rejection of untrusted TLS, authenticated stdin fallback, hashed CA-directory trust, SHA-256 and secret-free decisions")
    finally:
        server.shutdown()
