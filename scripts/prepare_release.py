#!/usr/bin/env python3
"""Prepare a versioned release archive and update the Homebrew formula."""

import gzip
import hashlib
import io
import re
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_FILES = (
    "LICENSE",
    "README.md",
    "README.zh-CN.md",
    "bin/brew-curl-aria2",
    "libexec/curl-aria2",
    "libexec/contiguous-progress.rb",
)
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def replace_once(text: str, pattern: str, replacement: str) -> str:
    result, count = re.subn(pattern, lambda _: replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"expected one match for {pattern!r}, found {count}")
    return result


def archive_bytes(version: str) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for relative in PACKAGE_FILES:
                path = ROOT / relative
                data = path.read_bytes()
                entry = tarfile.TarInfo(f"brew-curl-aria2-{version}/{relative}")
                entry.size = len(data)
                entry.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                entry.uid = entry.gid = entry.mtime = 0
                entry.uname = entry.gname = ""
                archive.addfile(entry, io.BytesIO(data))
    return output.getvalue()


def main() -> None:
    if len(sys.argv) != 3 or not VERSION_RE.fullmatch(sys.argv[1]):
        raise SystemExit("usage: prepare_release.py MAJOR.MINOR.PATCH OUTPUT_DIRECTORY")
    version = sys.argv[1]
    output_dir = Path(sys.argv[2])
    cli = ROOT / "bin/brew-curl-aria2"
    formula = ROOT / "Formula/brew-curl-aria2.rb"

    cli_text = cli.read_text()
    match = re.search(r'^VERSION="(\d+\.\d+\.\d+)"$', cli_text, re.MULTILINE)
    if not match:
        raise ValueError("could not find CLI version")
    current = match.group(1)
    if tuple(map(int, version.split("."))) < tuple(map(int, current.split("."))):
        raise ValueError(f"release version {version} is older than {current}")
    cli.write_text(replace_once(cli_text, r'^VERSION="\d+\.\d+\.\d+"$', f'VERSION="{version}"'))

    name = f"brew-curl-aria2-{version}.tar.gz"
    archive = archive_bytes(version)
    checksum = hashlib.sha256(archive).hexdigest()
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / name).write_bytes(archive)

    url = f"https://github.com/KKKKeybird/homebrew-brew-curl-aria2/releases/download/v{version}/{name}"
    formula_text = formula.read_text()
    formula_text = replace_once(formula_text, r'^  url "[^"]+"$', f'  url "{url}"')
    formula_text = replace_once(formula_text, r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{checksum}"')
    formula.write_text(formula_text)
    print(f"{name} sha256={checksum}")


if __name__ == "__main__":
    main()
