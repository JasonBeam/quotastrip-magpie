#!/usr/bin/env python3
"""Compile isolated provider tests; never read or modify the real Keychain.

Run on macOS with Xcode Command Line Tools:
    python3 Tests/run-deepseek-tests.py

The production source is copied into a temporary directory. Only that temporary
copy exposes private state, installs URLProtocol, and substitutes a synthetic key.
All actual transport requests are intercepted; no API key is required.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Sources" / "DeepSeekBalanceProvider.swift").read_text()
source = source.replace("private ", "")
configuration = "let configuration = URLSessionConfiguration.ephemeral"
assert source.count(configuration) == 1, "Provider configuration changed; review mock injection"
source = source.replace(configuration, configuration + "\n        configuration.protocolClasses = [MockDeepSeekProtocol.self]")
start_marker = "    func readAPIKey() throws -> String? {"
end_marker = "    func invalidate(message:"
assert source.count(start_marker) == source.count(end_marker) == 1, "Provider storage changed; review key isolation"
start = source.index(start_marker)
end = source.index(end_marker, start)
source = source[:start] + '    func readAPIKey() throws -> String? { "sk-test-only" }\n' + source[end:]

# Tests never invoke saveAPIKey/removeAPIKey. Fail closed if that changes.
tests = root / "Tests" / "DeepSeekBalanceProviderTests.swift"
test_text = tests.read_text()
assert "saveAPIKey(" not in test_text and "removeAPIKey(" not in test_text, "Tests must not access real Keychain"
with tempfile.TemporaryDirectory(prefix="quotastrip-deepseek-tests-") as temporary:
    directory = Path(temporary)
    testable = directory / "DeepSeekBalanceProvider.swift"
    executable = directory / "deepseek-tests"
    testable.write_text(source)
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", str(testable), str(tests),
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
