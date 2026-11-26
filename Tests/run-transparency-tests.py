#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Checks that both Touch Bar modules are transparent and share one vertical rhythm.

Rules this guards:
  * no card / no fill of the whole bounds / no layer background / not opaque
  * Codex and DeepSeek are two independent items, no spacer items, one width
    constraint each
  * the modules use the same row baselines (0.5 / 15.5) and the same bar
    geometry (9pt tall, y=3, radius h/2)
  * empty pixels really are transparent, while the progress track keeps painting

Synthetic data only; no network, no Keychain, no window.
"""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources" / "DeepSeekTouchBarView.swift",
    ROOT / "Sources" / "DSHBalanceProvider.swift",
    ROOT / "Sources" / "DeepSeekPricing.swift",
    ROOT / "Sources" / "DeepSeekHolidays.swift",
]

HARNESS = r'''
import AppKit

var checks = 0
func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { print("FAIL: \(name)"); exit(1) }
}

expect(DeepSeekTouchBarView.Layout.viewWidth == 300, "DeepSeek item is 300pt wide")
expect(DeepSeekTouchBarView.Layout.firstRowY == 0.5, "row 1 baseline is 0.5, like Codex")
expect(DeepSeekTouchBarView.Layout.secondRowY == 15.5, "row 2 baseline is 15.5, like Codex")
expect(DeepSeekTouchBarView.Layout.barHeight == 9, "bar is 9pt tall, like Codex")
expect(DeepSeekTouchBarView.Layout.barY == 3, "bar starts at y=3, like Codex")
expect(DeepSeekTouchBarView.Layout.barX == DeepSeekTouchBarView.Layout.contentX,
       "bar and today's token share one left edge")
expect(DeepSeekTouchBarView.Layout.percentRight == DeepSeekTouchBarView.Layout.rightEdge,
       "percentage sits on the shared right edge")

var snapshot = DeepSeekSnapshot()
snapshot.balance = Decimal(string: "9.50", locale: Locale(identifier: "en_US_POSIX"))
snapshot.startingBalance = Decimal(string: "21.11", locale: Locale(identifier: "en_US_POSIX"))
snapshot.todayTokens = 68_390_000
snapshot.todayCacheHitPercent = 97.7

let view = DeepSeekTouchBarView()
view.phase = .offPeak
view.update(snapshot)
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 60,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: 300, height: 30)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
view.cacheDisplay(in: view.bounds, to: rep)
NSGraphicsContext.restoreGraphicsState()

func pixel(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int, Int) {
    let px = Int(x * scale)
    let py = Int(y * scale)  // cacheDisplay keeps the flipped view's top-down rows
    guard let color = rep.colorAt(x: min(px, 599), y: min(py, 59))?.usingColorSpace(.deviceRGB) else {
        return (-1, -1, -1, -1)
    }
    return (Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()),
            Int((color.alphaComponent * 255).rounded()))
}

let empty = pixel(2, 15)
print("empty pixel:", empty)
expect(empty.3 == 0, "empty area is fully transparent (no card, no black fill)")

let top = pixel(150, 0.2)
print("top edge pixel:", top)
expect(top.3 == 0, "top edge stays transparent")

let bottom = pixel(150, 29.8)
print("bottom edge pixel:", bottom)
expect(bottom.3 == 0, "bottom edge stays transparent")

// 余额行现在只有标签 + 金额，不再画进度条：旧轨道位置必须是透明的。
let oldTrack = pixel(150, 7.5)
print("old progress track pixel:", oldTrack)
expect(oldTrack.3 == 0, "no progress track is painted anymore")

// 余额数值本身仍然上色（DeepSeek 蓝），右对齐到 292；字形间有空隙，扫范围而不是赌一个点。
var amountInk = false
for x in stride(from: 200.0, to: DeepSeekTouchBarView.Layout.rightEdge - 1, by: 0.5) {
    for y in stride(from: 2.0, to: 15.0, by: 0.5) where pixel(x, y).3 >= 200 {
        amountInk = true
    }
}
print("amount ink found:", amountInk)
expect(amountInk, "amount still renders")

let logo = pixel(12, 12)
print("logo pixel:", logo)
expect(logo.3 == 255, "logo still renders")

// 百分比是右对齐的，字形间有空隙：在它的列范围内找任意不透明像素，而不是赌某一个点。
var percentInk = false
for x in stride(from: DeepSeekTouchBarView.Layout.percentRight - 30,
                to: DeepSeekTouchBarView.Layout.percentRight, by: 0.5) {
    for y in stride(from: 4.0, to: 12.0, by: 1.0) where pixel(x, y).3 == 255 {
        percentInk = true
    }
}
print("percentage column ink:", percentInk)

print("PASS: \(checks) transparency checks (real pixels, no window)")
'''


def main() -> int:
    codex = (ROOT / "Sources" / "main.swift").read_text()
    deepseek = (ROOT / "Sources" / "DeepSeekTouchBarView.swift").read_text()

    def check(condition: bool, name: str) -> None:
        if not condition:
            print(f"FAIL: {name}")
            raise SystemExit(1)

    check(not (ROOT / "Sources" / "QuotaCard.swift").exists(), "card helper is gone")
    check("QuotaCard" not in codex and "QuotaCard" not in deepseek, "no card drawing anywhere")
    check("NSColor.black.setFill()\n        bounds.fill()" not in deepseek, "DeepSeek paints no black rectangle")
    check("override var isOpaque: Bool { false }" in deepseek, "DeepSeek view is transparent")
    check("isOpaque: Bool { true }" not in codex, "Codex view is not forced opaque")
    check("backgroundColor" not in deepseek and "backgroundColor" not in codex,
          "no layer background colour is set")
    check("wantsLayer = true" not in deepseek and "wantsLayer = true" not in codex,
          "no layer is forced on the views")
    check("bar.defaultItemIdentifiers = [.codexQuota]" in codex,
          "one merged default item (Codex + DeepSeek share it)")
    pair = (ROOT / "Sources" / "TouchBarPairView.swift").read_text()
    check("static let gap: CGFloat = 3" in pair, "3pt seam inside the merged item")
    check("static let baseWidth: CGFloat = QuotaView.viewWidth + gap + MagpieLiveTouchBarView.viewWidth" in pair
          and "static let fullWidth: CGFloat = baseWidth + gap + DeepSeekPercentView.viewWidth" in pair,
          "merged item width is derived, not hard-coded")
    check("addGestureRecognizer" not in pair, "container adds no gesture of its own")
    check("FixedSpace" not in codex, "no fixed space item")
    check("FlexibleSpace" not in codex and "flexibleSpace" not in codex, "no flexible space item")
    check(codex.count("pairView.widthAnchor.constraint") == 1, "one width constraint for the merged item")
    check("codexView.widthAnchor" not in codex and "deepSeekView.widthAnchor" not in codex,
          "the child views are laid out by the container, not by item constraints")
    check("static let viewWidth: CGFloat = 300" in codex, "Codex item is 300pt wide")
    check("static let viewWidth: CGFloat = 300" in deepseek, "DeepSeek item is 300pt wide")

    # 两个视图的垂直节奏必须一致。
    codex_metrics = dict(re.findall(r"private let (hBar|yBar|wBar): CGFloat = ([\d.]+)", codex))
    if "hBar" not in codex_metrics:
        codex_metrics["hBar"] = re.search(r"private let hBar: CGFloat = ([\d.]+)", codex).group(1)
    check(re.search(r"let yText: CGFloat = top \? ([\d.]+) : ([\d.]+)", codex).groups() == ("0.5", "15.5"),
          "Codex rows use the 0.5 / 15.5 rhythm")
    check(re.search(r"static let firstRowY: CGFloat = ([\d.]+)", deepseek).group(1) == "0.5",
          "DeepSeek row 1 matches Codex")
    check(re.search(r"static let secondRowY: CGFloat = ([\d.]+)", deepseek).group(1) == "15.5",
          "DeepSeek row 2 matches Codex")
    check(re.search(r"private let hBar: CGFloat = ([\d.]+)", codex).group(1) == "9",
          "Codex bar is 9pt")
    check(re.search(r"static let barHeight: CGFloat = ([\d.]+)", deepseek).group(1) == "9",
          "DeepSeek bar is 9pt")
    check(re.search(r"let yBar: CGFloat = top \? ([\d.]+) : ([\d.]+)", codex).group(1) == "3",
          "Codex bar starts at y=3")
    check(re.search(r"static let barY: CGFloat = ([\d.]+)", deepseek).group(1) == "3",
          "DeepSeek bar starts at y=3")

    with tempfile.TemporaryDirectory(prefix="quotastrip-transparency-") as folder:
        path = pathlib.Path(folder)
        (path / "main.swift").write_text(HARNESS)
        patched = path / "patched"
        patched.mkdir()
        for source in SOURCES:
            text = source.read_text()
            if source.name == "DeepSeekTouchBarView.swift":
                text = text.replace(
                    'let offPeakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) }',
                    'let offPeakLogo: NSImage? = NSImage(contentsOfFile: '
                    'ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")')
                text = text.replace("private(set) var snapshot: DeepSeekSnapshot?",
                                    "var snapshot: DeepSeekSnapshot?")
                text = text.replace("private(set) var phase: DeepSeekPricePhase",
                                    "var phase: DeepSeekPricePhase")
            (patched / source.name).write_text(text)

        binary = path / "transparency-tests"
        result = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0"]
            + [str(patched / source.name) for source in SOURCES]
            + [str(path / "main.swift"), "-o", str(binary)],
            capture_output=True, text=True, timeout=240)
        if result.returncode != 0:
            print(result.stdout)
            print(result.stderr)
            return result.returncode
        run = subprocess.run(
            [str(binary)],
            env={"QS_LOGO": str(ROOT / "Resources" / "deepseek-logo.png"), "PATH": "/usr/bin:/bin"},
            capture_output=True, text=True, timeout=120)
        print(run.stdout, end="")
        if run.returncode != 0:
            print(run.stderr)
            return run.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
