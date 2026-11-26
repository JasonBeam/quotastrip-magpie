#!/usr/bin/env python3
"""Checks the DeepSeek Touch Bar tap wiring and the app-wake helper.

No window is opened and no app is activated: the harness only resolves the installed
bundle, exercises the duplicate-launch guard with synthetic dates, and greps the
shipped sources for the required wiring.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"


def check(condition: bool, name: str) -> None:
    if not condition:
        print(f"FAIL: {name}")
        raise SystemExit(1)


def main() -> int:
    view = (SOURCES / "DeepSeekTouchBarView.swift").read_text()
    main_swift = (SOURCES / "main.swift").read_text()
    helper = (SOURCES / "DeepSeekHarness.swift").read_text()

    check("NSClickGestureRecognizer(target: self, action: #selector(tapped))" in view,
          "view installs a click recogniser")
    check("click.allowedTouchTypes = [.direct]" in view, "direct touch types only")
    check("func tapped()" in view, "tapped handler exists")
    check("deepSeekView.onTap" in main_swift, "onTap is bound in main")
    check("activateDeepSeekHarness()" in main_swift, "tap wakes DeepSeek Harness")
    check('"com.deepseek.dsh"' not in helper, "bundle id is read, not hard-coded")
    check("NSWorkspace.OpenConfiguration()" in helper, "uses OpenConfiguration")
    check("config.activates = true" in helper, "activation requested")
    check("openApplication(at:" in helper, "launches through NSWorkspace")

    swift = r'''
import AppKit

var checks = 0
func expect(_ condition: Bool, _ name: String) {
    checks += 1
    guard condition else { fatalError("FAIL: \(name)") }
}

guard let resolved = DeepSeekHarnessApp.resolve() else { fatalError("FAIL: installed app not found") }
expect(FileManager.default.fileExists(atPath: resolved.url.path), "resolved url exists")
expect(!resolved.bundleIdentifier.isEmpty, "bundle id is not empty")
expect(deepSeekIdentifierReadFromBundle(resolved.url) == resolved.bundleIdentifier,
       "bundle id comes from the installed Info.plist")
expect(DeepSeekHarnessApp.isInstalled(), "isInstalled")
expect(DeepSeekHarnessApp.resolve()?.url.path == resolved.url.path, "resolution is cached")

let now = Date()
expect(DeepSeekHarnessApp.launchAllowed(at: now), "first tap may launch")
DeepSeekHarnessApp.noteLaunchStarted(at: now)
expect(!DeepSeekHarnessApp.launchAllowed(at: now.addingTimeInterval(2.9)), "burst taps are coalesced")
expect(DeepSeekHarnessApp.launchAllowed(at: now.addingTimeInterval(3.1)), "guard expires")
print("bundle:", resolved.bundleIdentifier)
print("path:", resolved.url.path)
print("PASS: \(checks) activation checks (no app launched, no window opened)")

func deepSeekIdentifierReadFromBundle(_ url: URL) -> String? {
    Bundle(url: url)?.bundleIdentifier
}
'''
    with tempfile.TemporaryDirectory(prefix="quotastrip-activation-") as folder:
        folder_path = pathlib.Path(folder)
        harness = folder_path / "main.swift"
        harness.write_text(swift)
        binary = folder_path / "activation-tests"
        compile_args = [
            "swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx11.0",
            str(SOURCES / "DeepSeekHarness.swift"), str(harness), "-o", str(binary),
            "-framework", "AppKit",
        ]
        result = subprocess.run(compile_args, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout)
            print(result.stderr)
            return result.returncode
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        sys.stdout.write(run.stdout)
        if run.returncode != 0:
            sys.stderr.write(run.stderr)
            return run.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
