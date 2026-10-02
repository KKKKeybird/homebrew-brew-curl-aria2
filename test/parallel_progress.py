#!/usr/bin/env python3
"""Verify native Homebrew parallel progress via HOMEBREW_CURL_PATH alone."""
import fcntl
import hashlib
import http.server
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
DATA = os.urandom(12 * 1024 * 1024)
RANGES = []

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(DATA)))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()

    def do_GET(self):
        start, end = 0, len(DATA) - 1
        value = self.headers.get('Range')
        if value:
            first, last = value.removeprefix('bytes=').split('-', 1)
            start = int(first)
            if last:
                end = min(int(last), end)
            RANGES.append(start)
        self.send_response(206 if value else 200)
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        if value:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(DATA)}')
        self.end_headers()
        try:
            for offset in range(start, end + 1, 16384):
                self.wfile.write(DATA[offset:min(offset + 16384, end + 1)])
                time.sleep(.012)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory() as directory:
        cache = Path(directory)
        config = cache/'config/homebrew'
        config.mkdir(parents=True)
        (config/'brew.env').write_text(f'HOMEBREW_CURL_PATH={ROOT}/libexec/curl-aria2\n')
        env = os.environ.copy()
        env.update(HOMEBREW_PROGRESS_TEST_URL=f'http://127.0.0.1:{server.server_port}/file',
                   HOMEBREW_CACHE=directory, XDG_CONFIG_HOME=str(cache/'config'),
                   HOMEBREW_DOWNLOAD_CONCURRENCY='2', HOMEBREW_NO_AUTO_UPDATE='1',
                   HOMEBREW_NO_INSTALL_FROM_API='1', TERM='xterm-256color', COLUMNS='80', LINES='30',
                   HOMEBREW_BREW_CURL_ARIA2_CONNECTIONS='4',
                   HOMEBREW_PROGRESS_TEST_SHA=hashlib.sha256(DATA).hexdigest())
        for key in ('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
            env.pop(key, None)
        env['no_proxy'] = '127.0.0.1'
        hashes = [hashlib.sha256((env['HOMEBREW_PROGRESS_TEST_URL'] + str(i)).encode()).hexdigest() for i in range(2)]
        # Real native queue: no preload, renderer override, or shell integration.
        ruby = '''require "download_queue"; require "resource";
q=Homebrew::DownloadQueue.new;
resources=2.times.map do |i|
  r=Resource.new("aria2-native-#{i}"); r.url ENV.fetch("HOMEBREW_PROGRESS_TEST_URL")+i.to_s;
  r.version "1.0"; r.sha256 ENV.fetch("HOMEBREW_PROGRESS_TEST_SHA"); q.enqueue(r); r
end;
q.fetch;
resources.each { |r| abort "checksum failure" unless Digest::SHA256.file(r.cached_download).hexdigest == ENV.fetch("HOMEBREW_PROGRESS_TEST_SHA") }
'''
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 80, 0, 0))
        process = subprocess.Popen([shutil.which('brew'), 'ruby', '-e', ruby], env=env, stdout=slave, stderr=slave)
        os.close(slave)
        captured = bytearray()
        overlap = False
        live_meter = False
        checked_prefixes = 0
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            stages = list(cache.glob('downloads/.brew-curl-aria2/*/data'))
            partials = [path for digest in hashes for path in cache.glob(f'downloads/{digest}--*.incomplete')]
            if len(stages) == 2:
                overlap = True
            for partial in partials:
                try:
                    payload = partial.read_bytes()
                except FileNotFoundError:
                    continue
                if not payload:
                    continue  # file creation can precede the first write
                assert len(payload) <= len(DATA), 'oversized partial'
                state = cache/'downloads/.brew-curl-aria2'/partial.name/'data.aria2'
                assert len(payload) < len(DATA) or not state.exists(), 'full size exposed while aria2 remains incomplete'
                assert payload == DATA[:len(payload)], 'partial contains gaps or invalid bytes'
                if len(payload) < len(DATA):
                    checked_prefixes += 1
            if select.select([master], [], [], .1)[0]:
                try:
                    block = os.read(master, 65536)
                except OSError:
                    break
                if not block:
                    break
                captured.extend(block)
                if b'Downloading' in block and b'MB/' in block and partials and process.poll() is None:
                    live_meter = True
            if process.poll() is not None and not select.select([master], [], [], .1)[0]:
                break
        if process.poll() is None:
            process.kill()
        result = process.wait()
        os.close(master)
        text = captured.decode(errors='replace')
        assert result == 0, text
        assert overlap, 'packages did not overlap: '+text
        assert checked_prefixes > 0, 'no confirmed prefix was exposed'
        assert live_meter, 'native progress was not live: '+text
        assert any(offset > 0 for offset in RANGES), 'aria2 did not split range requests'
        assert not list(cache.glob('downloads/.brew-curl-aria2/*/data')), 'staging not cleaned'
        print('PASS: native Homebrew parallel meter, multiple packages and ranges, safe contiguous partials, both SHA-256 checks; no shell or Ruby hooks')
        print('\n'.join([line for line in text.replace('\r', '\n').splitlines() if 'Downloading' in line][:3]))
finally:
    server.shutdown()
    server.server_close()
