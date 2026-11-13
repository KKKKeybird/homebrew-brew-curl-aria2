#!/usr/bin/env python3
"""Real Homebrew install/update/upgrade in disposable checkouts and prefix.

Uses installed Homebrew's Ruby/dependencies, a local Git upstream and HTTP range
server. Never patches the installed Homebrew or changes real shell config.
"""
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
BREW = shutil.which("brew")
assert BREW, "Homebrew is required"
BASE = Path(subprocess.check_output([BREW, "--repository"], text=True).strip())
PREFIX = Path(subprocess.check_output([BREW, "--prefix"], text=True).strip())
PAYLOADS = {}
REQUESTS = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        data = PAYLOADS.get(self.path)
        if data is None:
            self.send_error(404)
            return
        start, end = 0, len(data) - 1
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
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        REQUESTS.append((self.command, self.path, value))
        if body:
            self.wfile.write(data[start:end + 1])


def run(*args, env=None, cwd=None):
    result = subprocess.run(args, env=env, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180)
    if result.returncode:
        raise AssertionError(f"{args[:3]} exit {result.returncode}\n{result.stdout}")
    return result.stdout


def git(path, *args):
    return run("git", "-C", str(path), "-c", "core.fsmonitor=false", "-c",
               "user.name=Compatibility test", "-c", "user.email=compatibility@localhost", *args)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="aria2-real-homebrew-", dir=ROOT.parent) as temporary:
        tmp = Path(temporary)
        upstream, prefix, core_upstream = tmp / "upstream", tmp / "prefix", tmp / "core-upstream"
        run("git", "clone", "--shared", str(BASE), str(upstream))
        run("git", "clone", "--shared", str(BASE), str(prefix))
        git(prefix, "remote", "set-url", "origin", str(upstream))
        # Copy installed runtime gems; never let test bootstrap write through a
        # symlink into the user's bundle. Portable Ruby itself is only executed.
        shutil.copytree(BASE / "Library/Homebrew/vendor/bundle", prefix / "Library/Homebrew/vendor/bundle", dirs_exist_ok=True)
        (prefix / "Library/Homebrew/vendor/portable-ruby").symlink_to(BASE / "Library/Homebrew/vendor/portable-ruby", target_is_directory=True)
        (prefix / "opt").mkdir(exist_ok=True)
        if (PREFIX / "opt/curl").exists():
            (prefix / "opt/curl").symlink_to(PREFIX / "opt/curl", target_is_directory=True)
        aria2 = shutil.which("aria2c") or str(PREFIX / "bin/aria2c")
        (prefix / "bin/aria2c").symlink_to(aria2)
        home, config, cache = tmp / "home", tmp / "config", tmp / "cache"
        for path in (home, config, cache):
            path.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("HOMEBREW_", "BREW_CURL_ARIA2_"))}
        env.update(HOME=str(home), XDG_CONFIG_HOME=str(config), XDG_CACHE_HOME=str(cache),
                   HOMEBREW_PREFIX=str(prefix), HOMEBREW_CACHE=str(cache),
                   HOMEBREW_BREW_GIT_REMOTE=str(upstream), HOMEBREW_CORE_GIT_REMOTE=str(core_upstream),
                   HOMEBREW_NO_INSTALL_FROM_API="1", HOMEBREW_NO_ANALYTICS="1", HOMEBREW_DEVELOPER="1",
                   HOMEBREW_NO_INSTALL_CLEANUP="1", HOMEBREW_NO_AUTO_UPDATE="1",
                   HOMEBREW_BREW_CURL_ARIA2_LOG=str(tmp / "backend.log"),
                   HOMEBREW_BREW_CURL_ARIA2_PROGRESS="0", HOMEBREW_DOWNLOAD_CONCURRENCY="1",
                   PATH=f"{prefix}/bin:{env.get('PATH', '/usr/bin:/bin')}", no_proxy="127.0.0.1,localhost",
                   NO_PROXY="127.0.0.1,localhost")
        ctl = str(ROOT / "bin/brew-curl-aria2")

        def formula(version):
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode="w:gz") as archive:
                script = f"#!/bin/sh\necho {version}\n".encode()
                entry = tarfile.TarInfo("fixture/aria2-compat-fixture")
                entry.mode, entry.size = 0o755, len(script)
                archive.addfile(entry, io.BytesIO(script))
            data = payload.getvalue()
            url_path = f"/fixture-{version}.tar.gz"
            PAYLOADS[url_path] = data
            text = f'''class Aria2CompatFixture < Formula
  desc "Isolated aria2 compatibility acceptance fixture"
  homepage "https://example.com"
  url "http://127.0.0.1:{server.server_port}{url_path}"
  version "{version}"
  sha256 "{hashlib.sha256(data).hexdigest()}"
  license "MIT"
  def install
    bin.install "aria2-compat-fixture"
  end
end
'''
            path = core_upstream / "Formula/a/aria2-compat-fixture.rb"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            git(core_upstream, "add", ".")
            git(core_upstream, "commit", "-m", f"Fixture {version}")

        core_upstream.mkdir()
        git(core_upstream, "init", "-b", "main")
        formula("1.0")
        core = prefix / "Library/Taps/homebrew/homebrew-core"
        core.parent.mkdir(parents=True)
        run("git", "clone", str(core_upstream), str(core))
        pristine = git(prefix, "status", "--porcelain", "--untracked-files=no")
        assert not pristine, pristine
        stash_before = git(prefix, "stash", "list")
        run(ctl, "enable", env=env)
        run(ctl, "enable", env=env)
        assert "aria2 selected  : yes" in run(ctl, "status", env=env)

        def shell(*args, environment=None):
            # Exercise the installed loader and user-facing brew function.
            return run("/bin/bash", "--noprofile", "--norc", "-c", 'source "$1"; shift; brew "$@"',
                       "test-shell", str(home / ".bashrc"), *args, env=environment or env)

        print(shell("install", "aria2-compat-fixture"), flush=True)
        assert run(str(prefix / "bin/aria2-compat-fixture"), env=env).strip() == "1.0"
        before = git(prefix, "rev-parse", "HEAD").strip()
        curl_upstream = upstream / "Library/Homebrew/utils/curl.sh"
        curl_upstream.write_text(curl_upstream.read_text() + "\n# isolated upstream update\n")
        git(upstream, "add", "Library/Homebrew/utils/curl.sh")
        git(upstream, "commit", "-m", "Change curl source in isolated upstream")
        formula("1.1")
        update_env = env.copy()
        update_env.pop("HOMEBREW_NO_AUTO_UPDATE")
        update_env["HOMEBREW_AUTO_UPDATE_SECS"] = "0"
        print(shell("upgrade", "aria2-compat-fixture", environment=update_env), flush=True)
        after = git(prefix, "rev-parse", "HEAD").strip()
        assert before != after
        assert run(str(prefix / "bin/aria2-compat-fixture"), env=env).strip() == "1.1"
        text = (prefix / "Library/Homebrew/utils/curl.sh").read_text()
        assert "# isolated upstream update" in text
        assert text.count("BEGIN brew-curl-aria2 selection") == 1
        assert git(prefix, "stash", "list") == stash_before
        log = (tmp / "backend.log").read_text()
        assert log.count("backend=aria2c") >= 2, log
        assert any(method == "GET" and path == "/fixture-1.1.tar.gz" for method, path, _ in REQUESTS)
        test_url = f"http://127.0.0.1:{server.server_port}/fixture-1.1.tar.gz"
        print(run(ctl, "test", test_url, env=env), flush=True)
        print(shell("update", environment=update_env), flush=True)
        assert git(prefix, "stash", "list") == stash_before
        progress_env = env.copy()
        progress_env["BREW_CURL_ARIA2_TEST_BREW"] = str(prefix / "bin/brew")
        print(run("python3", str(ROOT / "test/parallel_progress.py"), env=progress_env), flush=True)
        print(shell("update-reset", str(prefix), environment=update_env), flush=True)
        assert "BEGIN brew-curl-aria2 selection" in (prefix / "Library/Homebrew/utils/curl.sh").read_text()
        assert git(prefix, "stash", "list") == stash_before
        run(ctl, "disable", env=env)
        assert not git(prefix, "diff", "--", "Library/Homebrew/utils/curl.sh")
        assert "BEGIN brew-curl-aria2" not in (home / ".bashrc").read_text()
        print(json.dumps({"result": "PASS", "before": before, "after": after,
                          "installed": "1.0", "upgraded": "1.1", "new_stashes": 0,
                          "aria2_downloads": log.count("backend=aria2c"), "http_requests": len(REQUESTS)}), flush=True)
finally:
    server.shutdown()
