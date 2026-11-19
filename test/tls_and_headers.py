#!/usr/bin/env python3
"""Verify TLS trust, authenticated redirects, and byte-for-byte curl fallback."""
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
SECRET = "acceptance-secret"
SIGNED_QUERY = "signature=temporary-credential"
DELIVERY_REQUESTS = []


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
        if self.server is delivery:
            DELIVERY_REQUESTS.append((self.headers.get("Authorization"), self.headers.get("Range")))
            if self.headers.get("Authorization") or not self.path.endswith("?" + SIGNED_QUERY):
                self.send_error(403)
                return
            if self.path.startswith("/broken?") and body and self.headers.get("Range") != "bytes=0-0":
                self.send_error(503)
                return
        elif self.path in ("/authenticated", "/digest", "/redirect", "/fallback-redirect"):
            allowed = ((f'Digest response="{SECRET}"',) if self.path == "/digest"
                       else (f"Bearer {SECRET}", f"token {SECRET}", "Basic ZmFrZTpwYXNz"))
            if self.headers.get("Authorization") not in allowed:
                self.send_error(401)
                return
            if self.path == "/redirect" or (self.path == "/fallback-redirect" and self.headers.get("Range")):
                target = "broken" if self.path == "/fallback-redirect" else "file"
                self.send_response(307)
                self.send_header("Location", f"https://127.0.0.1:{delivery.server_port}/{target}?{SIGNED_QUERY}")
                self.send_header("Content-Length", "0")
                self.end_headers()
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
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(tmp / "server.pem", tmp / "server.key")
    def start_server():
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server

    server, delivery = start_server(), start_server()
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
        assert "reason=auth-no-https-redirect" in log

        result, output = download("digest", tmp / "server.pem", ("--header", "@-"),
                                  path="/digest",
                                  headers=f'Authorization: Digest response="{SECRET}"\r\n'.encode())
        assert result.returncode == 0, result.stderr.decode()
        assert output.read_bytes() == DATA
        assert "reason=unsupported-auth-header" in (tmp / "decisions.log").read_text()

        for options, headers in (
            (("--header", "@-"), f"Authorization: Bearer {SECRET}\r\n".encode()),
            (("--header", "@-"), b"Authorization: Basic ZmFrZTpwYXNz\n"),
            (("--header", f"Authorization: token {SECRET}",
              "--header", "Accept: application/octet-stream"), None),
        ):
            DELIVERY_REQUESTS.clear()
            (tmp / "decisions.log").write_text("")
            result, output = download("redirect", tmp / "server.pem", options,
                                      path="/redirect", headers=headers)
            assert result.returncode == 0, result.stderr.decode()
            assert output.read_bytes() == DATA
            output.unlink()
            log = (tmp / "decisions.log").read_text()
            assert "backend=aria2c auth-redirect" in log and "backend=aria2c ok" in log, log
            assert all(auth is None for auth, _ in DELIVERY_REQUESTS)
            assert any(value not in (None, "bytes=0-0") for _, value in DELIVERY_REQUESTS)
            assert SECRET not in log and "ZmFrZTpwYXNz" not in log and SIGNED_QUERY not in log
            assert SIGNED_QUERY.encode() not in result.stdout + result.stderr

        (tmp / "decisions.log").write_text("")
        result, output = download("retry", tmp / "server.pem", ("--retry", "0", "--header", "@-"),
                                  path="/fallback-redirect", headers=f"Authorization: Bearer {SECRET}\n".encode())
        assert result.returncode == 0, result.stderr.decode()
        assert output.read_bytes() == DATA
        log = (tmp / "decisions.log").read_text()
        assert "backend=aria2c auth-redirect" in log and "falling back to curl" in log, log
        assert SECRET not in log and "ZmFrZTpwYXNz" not in log and SIGNED_QUERY not in log

        cert_hash = subprocess.check_output(["openssl", "x509", "-hash", "-noout", "-in", str(tmp / "server.pem")], text=True).strip()
        (tmp / f"{cert_hash}.0").symlink_to(tmp / "server.pem")
        result, output = download("directory-trust", tmp / "other.pem", ("--capath", str(tmp)))
        assert result.returncode == 0, result.stderr.decode()
        assert output.read_bytes() == DATA
        assert "reason=hashed-ca-directory" in (tmp / "decisions.log").read_text()
        print("PASS: TLS trust, authenticated parallel redirects, original-header fallback, and credential-free diagnostics")
    finally:
        server.shutdown()
        delivery.shutdown()
