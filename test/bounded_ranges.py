#!/usr/bin/env python3
"""Count real HTTP response bodies, including bytes discarded by the client.

Loopback only: no provider traffic or external downloads. Successful server
writes include socket buffering, so they are not provider billing counters.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
DATA = os.urandom(32 * 1024 * 1024)
ROWS = []
LOCK = threading.Lock()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = False

    def handle_error(self, *args):
        pass  # A rejected full response may be closed before its first write.


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        if self.path == '/no-head':
            self.send_response(405)
            self.send_header('Content-Length', '0')
        else:
            self.send_response(200)
            if self.path != '/head-no-size':
                self.send_header('Content-Length', str(len(DATA)))
        if self.path == '/close':
            self.send_header('Connection', 'close')
        self.end_headers()

    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/file')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        requested = self.headers.get('Range')
        value = requested if self.path != '/no-range' else None
        start, end = 0, len(DATA) - 1
        if value:
            first, last = value.removeprefix('bytes=').split('-', 1)
            start = int(first)
            if last:
                end = min(int(last), end)
        row = dict(requested=requested, start=start, end=end, sent=0)
        with LOCK:
            ROWS.append(row)
        self.send_response(206 if value else 200)
        # Deliberately omit Accept-Ranges: an actual 206 is the proof.
        self.send_header('Content-Length', str(end - start + 1))
        if value:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(DATA)}')
        if self.path == '/close':
            self.send_header('Connection', 'close')
        self.end_headers()
        try:
            for offset in range(start, end + 1, 16384):
                block = DATA[offset:min(offset + 16384, end + 1)]
                self.wfile.write(block)
                row['sent'] += len(block)
        except (BrokenPipeError, ConnectionResetError):
            pass


def check(path, *, protocol='HTTP/1.1', resume=0, native=True):
    ROWS.clear()
    Handler.protocol_version = protocol
    server = Server(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / ('a' * 64 + '--file.incomplete')
            if resume:
                output.write_bytes(DATA[:resume])
            env = {k: v for k, v in os.environ.items() if k.lower() not in
                   ('http_proxy', 'https_proxy', 'all_proxy')}
            env.update(no_proxy='127.0.0.1', HOMEBREW_DOWNLOAD_CONCURRENCY='2',
                       HOMEBREW_BREW_CURL_ARIA2_CONNECTIONS='8',
                       HOMEBREW_BREW_CURL_ARIA2_NATIVE_PROGRESS=str(int(native)),
                       HOMEBREW_BREW_CURL_ARIA2_DEBUG='1')
            args = [str(ROOT / 'libexec/curl-aria2'), '--silent', '--location',
                    '--output', str(output)]
            if resume:
                args += ['--continue-at', '-']
            result = subprocess.run(args + [f'http://127.0.0.1:{server.server_port}{path}'],
                                    env=env, capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stdout + result.stderr
            assert hashlib.sha256(output.read_bytes()).digest() == hashlib.sha256(DATA).digest()
    finally:
        server.shutdown()
        server.server_close()  # Join handlers before inspecting counters.
    total = sum(row['sent'] for row in ROWS)
    if path in ('/no-head', '/head-no-size', '/no-range'):
        # Failed capability checks must never fan out full-file GETs.
        full = [row for row in ROWS if row['end'] - row['start'] + 1 == len(DATA)]
        assert len(full) <= (2 if path == '/no-range' else 1), ROWS
        if path == '/no-range':
            assert 'range-unverified -> single aria2c stream' in result.stderr
    else:
        assert 'range-mode=bounded-pieces' in result.stderr
        assert total == len(DATA) - resume + 1, (total, ROWS, result.stderr)
        # One capability byte, followed by disjoint ranges consumed in full.
        pieces = sorted([row for row in ROWS if row['end'] != 0], key=lambda row: row['start'])
        offset = resume
        for row in pieces:
            assert row['requested'] == f"bytes={row['start']}-{row['end']}", row
            assert row['start'] == offset, ROWS
            assert row['sent'] == row['end'] - row['start'] + 1, row
            offset = row['end'] + 1
        assert offset == len(DATA), ROWS
    print(json.dumps(dict(path=path, protocol=protocol, resume=resume, native=native,
                          file_bytes=len(DATA), server_body_bytes=total, requests=len(ROWS))), flush=True)


if __name__ == '__main__':
    check('/file')
    check('/file', native=False)
    check('/file', protocol='HTTP/1.0')
    check('/close')
    check('/redirect')
    check('/file', resume=3 * 1024 * 1024)
    check('/no-head')
    check('/head-no-size')
    check('/no-range')
