#!/usr/bin/env python3
"""Isolated synthetic Qwen Token Plan tests. Never touches Chrome/network/credentials."""
from pathlib import Path
import subprocess
from swiftenv import SWIFTC_CMD
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="quotastrip-plan-tests-") as temporary:
    executable = Path(temporary) / "plan-tests"
    subprocess.run([
        *SWIFTC_CMD, "-swift-version", "5",
        str(root / "Sources" / "JimmyCloudPlanProvider.swift"),
        str(root / "Tests" / "test-plan-provider.swift"), "-o", str(executable),
        "-framework", "AppKit",
        "-framework", "Security",
    ], check=True)
    subprocess.run([str(executable)], check=True)
