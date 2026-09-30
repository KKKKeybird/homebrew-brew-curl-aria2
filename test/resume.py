#!/usr/bin/env python3
"""Exercise actual aria2 range requests, saved pieces, and file publication."""
import hashlib
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
ARIA2 = shutil.which('aria2c')
assert ARIA2, 'aria2c is required'
DATA = os.urandom(8 * 1024 * 1024)
DIGEST = hashlib.sha256(DATA).digest()
RANGES = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        start, end = 0, len(DATA) - 1
        value = self.headers.get('Range')
        if self.path == '/no-range':
            value = None
        if value:
            first, last = value.removeprefix('bytes=').split('-', 1)
            start = int(first)
            if last:
                end = min(int(last), end)
            RANGES.append(start)
        self.send_response(206 if value else 200)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if value:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(DATA)}')
        self.end_headers()
        try:
            for offset in range(start, end + 1, 16384):
                self.wfile.write(DATA[offset:min(offset + 16384, end + 1)])
                time.sleep(0.015)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory() as directory:
        fixture = Path(directory)
        prefix = fixture / 'prefix'
        (prefix / 'bin').mkdir(parents=True)
        (prefix / 'opt/curl/bin').mkdir(parents=True)
        aria = prefix / 'bin/aria2c'
        aria.write_text('#!/bin/bash\n[ "${TEST_ARIA2_FAIL:-0}" = 0 ] || exit 1\nif [ "${TEST_STOP:-0}" = 1 ]; then\n'
                        f'  exec "{ARIA2}" --stop=1 "$@"\nfi\nexec "{ARIA2}" "$@"\n')
        curl = prefix / 'opt/curl/bin/curl'
        curl.write_text('#!/bin/bash\n[ "${TEST_CURL_FAIL:-0}" = 0 ] || exit 22\nexec /usr/bin/curl "$@"\n')
        aria.chmod(0o755)
        curl.chmod(0o755)
        env = os.environ.copy()
        env.update(HOMEBREW_PREFIX=str(prefix),
                   HOMEBREW_BREW_CURL_ARIA2_DEBUG='1',
                   HOMEBREW_BREW_CURL_ARIA2_CONNECTIONS='4')
        for key in ('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
            env.pop(key, None)
        env['no_proxy'] = '127.0.0.1'
        url = f'http://127.0.0.1:{server.server_port}/file'
        output = fixture / 'download.incomplete'
        stage = Path(str(output) + '.aria2-work')

        def run(resume=True, **variables):
            args = [str(ROOT / 'libexec/curl-aria2'), '--location', '--output', str(output)]
            if resume:
                args += ['--continue-at', '-']
            result = subprocess.run(args + [url], env=env | variables, capture_output=True, text=True, timeout=30)
            assert 'backend=aria2c ' in result.stderr, result.stderr
            return result

        def complete(result):
            assert result.returncode == 0, result.stdout + result.stderr
            assert hashlib.sha256(output.read_bytes()).digest() == DIGEST
            assert not stage.exists(), 'successful download left staged pieces'
            output.unlink()

        prefix_bytes = DATA[:1024 * 1024]
        output.write_bytes(prefix_bytes)
        complete(run())
        assert any(offset >= len(prefix_bytes) for offset in RANGES), 'resume did not issue ranged requests'

        output.write_bytes(prefix_bytes)
        complete(run(TEST_ARIA2_FAIL='1'))

        previous_url = url
        url = f'http://127.0.0.1:{server.server_port}/no-range'
        output.write_bytes(prefix_bytes)
        complete(run())
        url = previous_url

        # A resumed aria2 download is interrupted and curl fails. The original
        # curl partial stays contiguous, while sparse pieces are saved privately.
        output.write_bytes(prefix_bytes)
        failed = run(TEST_STOP='1', TEST_CURL_FAIL='1')
        assert failed.returncode != 0, failed.stderr
        assert output.read_bytes() == prefix_bytes, 'original partial changed on failure'
        assert (stage / 'data.aria2').is_file(), 'interrupted download lost control file'
        complete(run())

        # Fresh interrupted downloads must not expose a full-size sparse file
        # at the path Homebrew checks before deciding whether to continue.
        failed = run(False, TEST_STOP='1', TEST_CURL_FAIL='1')
        assert failed.returncode != 0, failed.stderr
        assert not output.exists(), 'sparse partial exposed to Homebrew'
        assert (stage / 'data.aria2').is_file()
        complete(run(False))

        # Accept control files written directly beside output by old versions.
        output.write_bytes(prefix_bytes)
        failed = run(TEST_STOP='1', TEST_CURL_FAIL='1')
        assert failed.returncode != 0
        shutil.copyfile(stage / 'data', output)
        shutil.copyfile(stage / 'data.aria2', Path(str(output) + '.aria2'))
        shutil.rmtree(stage)
        complete(run())
        assert not Path(str(output) + '.aria2').exists()
        print('PASS: real curl partial resume, interrupted aria2 resume, sparse isolation, curl fallback, no-range restart, and legacy state; all SHA-256 checks passed')
finally:
    server.shutdown()
    server.server_close()
