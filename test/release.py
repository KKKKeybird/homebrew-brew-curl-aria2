#!/usr/bin/env python3
"""Check release packaging without modifying the working checkout."""

import hashlib
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
files = (
    "scripts/prepare_release.py",
    "Formula/brew-curl-aria2.rb",
    "bin/brew-curl-aria2",
    "libexec/curl-aria2",
    "libexec/contiguous-progress.rb",
    "LICENSE",
    "README.md",
    "README.zh-CN.md",
)

current = re.search(r'^VERSION="(\d+\.\d+\.\d+)"$', (root / "bin/brew-curl-aria2").read_text(), re.MULTILINE)
assert current, "CLI version missing"
major, minor, patch = map(int, current.group(1).split("."))
version = f"{major}.{minor}.{patch + 1}"

with tempfile.TemporaryDirectory() as temporary:
    checkout = Path(temporary) / "checkout"
    for relative in files:
        target = checkout / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target)
    output = Path(temporary) / "output"
    command = ["python3", str(checkout / "scripts/prepare_release.py"), version, str(output)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    archive = output / f"brew-curl-aria2-{version}.tar.gz"
    first = archive.read_bytes()
    checksum = hashlib.sha256(first).hexdigest()
    formula = (checkout / "Formula/brew-curl-aria2.rb").read_text()
    assert f'  sha256 "{checksum}"' in formula
    assert f"/releases/download/v{version}/brew-curl-aria2-{version}.tar.gz" in formula
    with tarfile.open(archive, "r:gz") as contents:
        cli = contents.extractfile(f"brew-curl-aria2-{version}/bin/brew-curl-aria2")
        assert cli is not None and f'VERSION="{version}"'.encode() in cli.read()
        assert contents.getmember(f"brew-curl-aria2-{version}/bin/brew-curl-aria2").mode & 0o111
    subprocess.run(command, check=True, capture_output=True, text=True)
    assert archive.read_bytes() == first, "release archive changed on a repeated build"
    older = subprocess.run(
        ["python3", str(checkout / "scripts/prepare_release.py"), "0.1.0", str(output)],
        capture_output=True,
    )
    assert older.returncode != 0, "older release version was accepted"

print("PASS: reproducible release archive and Formula checksum")
