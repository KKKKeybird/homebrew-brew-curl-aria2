#!/usr/bin/env python3
"""Check release packaging without modifying the working checkout."""

import hashlib
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
    "LICENSE",
    "README.md",
    "README.zh-CN.md",
)

with tempfile.TemporaryDirectory() as temporary:
    checkout = Path(temporary) / "checkout"
    for relative in files:
        target = checkout / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target)
    output = Path(temporary) / "output"
    command = ["python3", str(checkout / "scripts/prepare_release.py"), "0.2.0", str(output)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    archive = output / "brew-curl-aria2-0.2.0.tar.gz"
    first = archive.read_bytes()
    checksum = hashlib.sha256(first).hexdigest()
    formula = (checkout / "Formula/brew-curl-aria2.rb").read_text()
    assert f'  sha256 "{checksum}"' in formula
    assert "/releases/download/v0.2.0/brew-curl-aria2-0.2.0.tar.gz" in formula
    with tarfile.open(archive, "r:gz") as contents:
        cli = contents.extractfile("brew-curl-aria2-0.2.0/bin/brew-curl-aria2")
        assert cli is not None and b'VERSION="0.2.0"' in cli.read()
        assert contents.getmember("brew-curl-aria2-0.2.0/bin/brew-curl-aria2").mode & 0o111
    subprocess.run(command, check=True, capture_output=True, text=True)
    assert archive.read_bytes() == first, "release archive changed on a repeated build"
    older = subprocess.run(
        ["python3", str(checkout / "scripts/prepare_release.py"), "0.1.0", str(output)],
        capture_output=True,
    )
    assert older.returncode != 0, "older release version was accepted"

print("PASS: reproducible release archive and Formula checksum")
