#!/usr/bin/env python3
"""Isolated synthetic Magpie provider tests. Loopback mock only; no credentials."""
from pathlib import Path
import subprocess
from swiftenv import SWIFTC_CMD
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="quotastrip-magpie-tests-") as temporary:
    executable = Path(temporary) / "magpie-tests"
    subprocess.run([
        *SWIFTC_CMD, "-swift-version", "5",
        str(root / "Sources" / "MagpieProvider.swift"),
        str(root / "Tests" / "test-magpie-provider.swift"), "-o", str(executable),
        "-framework", "Foundation",
    ], check=True)
    subprocess.run([str(executable)], check=True)
