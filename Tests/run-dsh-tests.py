#!/usr/bin/env python3
"""Isolated synthetic DSH provider tests. Never accesses real keys/logs/network."""
from pathlib import Path
import subprocess
from swiftenv import SWIFTC_CMD
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="quotastrip-dsh-tests-") as temporary:
    executable = Path(temporary) / "dsh-tests"
    subprocess.run([
        *SWIFTC_CMD, "-swift-version", "5",
        str(root / "Sources" / "DSHBalanceProvider.swift"),
        str(root / "Sources" / "DSHSessionTitles.swift"),
        str(root / "Tests" / "test-dsh-provider.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
