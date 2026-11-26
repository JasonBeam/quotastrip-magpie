#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Verifies the DeepSeek Touch Bar layout: shared columns, shared right edge and
real text widths (no silent overlap). Synthetic snapshots only; no network, no
Keychain, no window opened.
"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"


def check(condition: bool, name: str) -> None:
    if not condition:
        print(f"FAIL: {name}")
        raise SystemExit(1)


SWIFT = r'''
import AppKit

func snapshot(_ balance: String, start: String, tokens: Int64, cache: Double) -> DeepSeekSnapshot {
    var value = DeepSeekSnapshot()
    value.balance = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX"))
    value.startingBalance = Decimal(string: start, locale: Locale(identifier: "en_US_POSIX"))
    value.todayTokens = tokens
    value.todayCacheHitPercent = cache
    return value
}

var checks = 0
func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { print("FAIL: \(name)"); exit(1) }
}

// Columns the spec pins down.
// 新版排版：两行同字号，标签 36 / 数值 66 / 右侧指标右对齐 292。
expect(DeepSeekTouchBarView.Layout.valueX == DeepSeekTouchBarView.Layout.contentX, "values start at contentX")
expect(DeepSeekTouchBarView.Layout.valueSize >= 13, "values stay readable")
expect(DeepSeekTouchBarView.Layout.sideSize < DeepSeekTouchBarView.Layout.valueSize,
       "side metrics are smaller than the values")
expect(DeepSeekTouchBarView.Layout.rightEdge == 292, "side metrics share the right edge")
expect(DeepSeekTouchBarView.Layout.labelX == 36, "labels keep the Codex column")
expect(DeepSeekTouchBarView.Layout.viewWidth == 300 && DeepSeekTouchBarView.Layout.viewHeight == 30, "300x30")

let view = DeepSeekTouchBarView()
let spec = snapshot("9.50", start: "21.11", tokens: 68_390_000, cache: 97.7)
view.update(spec)
if case .known(let start, let percent) = view.round() {
    expect(start == Decimal(string: "21.11")!, "round keeps the starting balance")
    expect(percent == 45, "9.50 / 21.11 renders 45%")
} else {
    expect(false, "spec snapshot is a known round")
}

let cases: [(String, DeepSeekSnapshot)] = [
    ("spec 9.50 / 68.39M", spec),
    ("¥9.29", snapshot("9.29", start: "21.11", tokens: 68_390_000, cache: 97.7)),
    ("¥99.99", snapshot("99.99", start: "200", tokens: 68_390_000, cache: 97.7)),
    ("¥999.99", snapshot("999.99", start: "2000", tokens: 68_390_000, cache: 97.7)),
    ("0% remaining", snapshot("0.00", start: "21.11", tokens: 68_390_000, cache: 97.7)),
    ("¥100.00", snapshot("100.00", start: "200", tokens: 68_390_000, cache: 97.7)),
    ("¥1000.00", snapshot("1000.00", start: "2000", tokens: 68_390_000, cache: 97.7)),
    ("¥1234567.89 compact", snapshot("1234567.89", start: "2000000", tokens: 68_390_000, cache: 97.7)),
    ("999.99M tokens", snapshot("9.50", start: "21.11", tokens: 999_990_000, cache: 97.7)),
    ("1.00B tokens", snapshot("9.50", start: "21.11", tokens: 1_000_000_000, cache: 97.7)),
    ("no cache", snapshot("9.50", start: "21.11", tokens: 68_390_000, cache: 0)),
    ("100.0% cache", snapshot("9.50", start: "21.11", tokens: 68_390_000, cache: 100)),
]
for (name, value) in cases {
    let report = view.layoutReport(for: value)
    expect(report.fits, "\(name): no text collision (min gap \(report.minimumGap))")
    expect(report.labelToValue >= 4, "\(name): 余额 label clears the value")
    expect(report.labelToValue <= 9, "\(name): label→value stays close to Codex's 7.6pt")
    expect(report.valueToSide >= 4, "\(name): value clears the right-hand metric")
    if name == "spec 9.50 / 68.39M" {
        expect(report.valueToSide >= 8, "\(name): value keeps ~8pt breathing room")
    }

    print(String(format: "%-24@ label→value %.1f  value→side %.1f",
                 name as NSString, report.labelToValue, report.valueToSide))
}
print("PASS: \(checks) layout checks (real AppKit text metrics, no window)")
'''

def main() -> int:
    view = (SOURCES / "DeepSeekTouchBarView.swift").read_text()
    layout = (SOURCES / "main.swift").read_text()

    for legacy in ("xPctRight", "xTodayTokens", "private let xBar"):
        check(legacy not in view, f"legacy layout constant removed: {legacy}")
    check('drawLabel(label, row: row)' in view, "both rows draw their label through one column")
    check('label: "余额"' in view and 'label: "今日"' in view, "both labels are present")
    check("right: Layout.rightEdge" in view, "right edge is shared by the side metrics")
    check("NSFont.monospacedDigitSystemFont" in view, "real font metrics are used")
    check(".size(withAttributes:" in view, "widths measured with NSString.size")
    check("static let valueX: CGFloat = contentX" in view, "value column shares contentX")
    check(view.count("sizes: Self.valueSizes") >= 2, "both rows use the shared value sizes")

    with tempfile.TemporaryDirectory(prefix="quotastrip-layout-") as folder:
        path = pathlib.Path(folder)
        (path / "main.swift").write_text(SWIFT)
        files = [
            SOURCES / "DeepSeekTouchBarView.swift",
            SOURCES / "DSHBalanceProvider.swift",
            SOURCES / "DeepSeekPricing.swift",
            SOURCES / "DeepSeekHolidays.swift",
        ]
        binary = path / "layout-tests"
        result = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0"]
            + [str(f) for f in files] + [str(path / "main.swift"), "-o", str(binary),
                                         "-framework", "AppKit"],
            capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout)
            print(result.stderr)
            return result.returncode
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        print(run.stdout, end="")
        if run.returncode != 0:
            print(run.stderr)
            return run.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
