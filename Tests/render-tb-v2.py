#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders real Codex QuotaView next to three new DeepSeek Touch Bar layouts.

The Codex half is the shipped QuotaView.draw(_:) compiled from main.swift (only the
three launch lines and the bundle icon lookup are patched in a temp copy), so the
comparison keeps the real Font/colour rhythm. The DeepSeek half comes from
Tests/designs/TouchBarV2.swift, which is design-only and never shipped.

Output (2x): design-<n>-<name>.png per row plus tbv2-sheet.png with every row.
Synthetic values only: no network, no Keychain, nothing outside a temp dir.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
DESIGNS = ROOT / "Tests" / "designs"

MAIN = r'''
import AppKit

let app = NSApplication.shared

func codexView() -> QuotaView {
    let view = QuotaView(iconFile: "codex-logo",
                         bundleID: "com.openai.codex",
                         appName: "Codex.app",
                         flagName: "codex_attention",
                         fallbackURL: "https://chatgpt.com/codex")
    let now = Date().timeIntervalSince1970
    view.service = QuotaService(ok: true, stale: false,
                                five: QuotaWindow(pct: 100, reset: now + 3 * 3600),
                                week: QuotaWindow(pct: 4, reset: now + 4 * 86400),
                                attention: false, source: "fixture")
    return view
}

var fixture: DeepSeekSnapshot {
    var value = DeepSeekSnapshot()
    value.balance = Decimal(string: "50.95", locale: Locale(identifier: "en_US_POSIX"))
    value.startingBalance = Decimal(string: "71.11", locale: Locale(identifier: "en_US_POSIX"))
    value.todayTokens = 3_570_277
    value.todayCacheHitPercent = 78.6
    value.stale = false
    return value
}

func shippedView() -> DeepSeekTouchBarView {
    let view = DeepSeekTouchBarView()
    view.phase = .offPeak
    view.update(fixture)
    return view
}

func tbView(_ style: TBV2Style) -> TBV2View {
    let view = TBV2View()
    view.style = style
    view.phase = .offPeak
    view.update(fixture)
    return view
}

/// 把真实 QuotaView 与右半部分视图按合并 item 的几何摆在一起：300 + 3 + 300。
func compose(_ right: NSView, into rep: NSBitmapImageRep) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: 603, height: 30).fill()
    NSGraphicsContext.restoreGraphicsState()

    for (view, x) in [(codexView() as NSView, CGFloat(0)), (right, CGFloat(303))] {
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        guard let piece = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
        view.cacheDisplay(in: view.bounds, to: piece)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(piece)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: x, y: 0, width: 300, height: 30),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

func row(_ right: NSView) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1206, pixelsHigh: 60,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 603, height: 30)
    compose(right, into: rep)
    return rep
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
var rows: [(String, NSBitmapImageRep)] = [("tbv2-0-shipped", row(shippedView()))]
for style in TBV2Style.allCases {
    rows.append(("tbv2-" + String(style.rawValue + 1) + "-" + String(describing: style),
                 row(tbView(style))))
}

for (name, rep) in rows {
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
    print(name, rep.pixelsWide, "x", rep.pixelsHigh)
}

// 拼成一张对照表：每行 30pt，中间 1pt 纯黑分隔，用 flipped 容器按从上到下摆。
final class SheetView: NSView {
    var images: [NSImage] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        for (index, image) in images.enumerated() {
            image.draw(in: NSRect(x: 0, y: CGFloat(index) * 31, width: 603, height: 30),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

let sheetHeight = CGFloat(rows.count) * 31 - 1
let sheetView = SheetView(frame: NSRect(x: 0, y: 0, width: 603, height: sheetHeight))
sheetView.images = rows.map { entry in
    let image = NSImage(size: NSSize(width: 603, height: 30))
    image.addRepresentation(entry.1)
    return image
}
guard let sheet = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) else { exit(4) }
sheetView.cacheDisplay(in: sheetView.bounds, to: sheet)
try! sheet.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("tbv2-sheet.png"))
print("tbv2-sheet", sheet.pixelsWide, "x", sheet.pixelsHigh)
'''


def main() -> int:
    body = (SOURCES / "main.swift").read_text(encoding="utf-8")
    cutoff = body.index("let app = NSApplication.shared")
    body = body[:cutoff]
    icon_line = 'self.icon = Bundle.main.path(forResource: iconFile, ofType: "png").flatMap { NSImage(contentsOfFile: $0) }'
    if icon_line not in body:
        print("FAIL: could not find the icon lookup in main.swift")
        return 1
    body = body.replace(
        icon_line,
        'self.icon = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_CODEX_ICON"] ?? "")')

    deepseek = (SOURCES / "DeepSeekTouchBarView.swift").read_text(encoding="utf-8")
    deepseek = deepseek.replace(
        'let offPeakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) }',
        'let offPeakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")')
    deepseek = deepseek.replace(
        'private lazy var peakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo-peak", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) } ?? Self.loadDSHDockIcon()',
        'private lazy var peakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")')
    deepseek = deepseek.replace("private(set) var snapshot: DeepSeekSnapshot?",
                                "var snapshot: DeepSeekSnapshot?")
    deepseek = deepseek.replace("private(set) var phase: DeepSeekPricePhase",
                                "var phase: DeepSeekPricePhase")

    with tempfile.TemporaryDirectory(prefix="quotastrip-tbv2-") as folder:
        work = pathlib.Path(folder)
        (work / "QuotaStripBody.swift").write_text(body, encoding="utf-8")
        (work / "DeepSeekTouchBarView.swift").write_text(deepseek, encoding="utf-8")
        (work / "TouchBarV2.swift").write_text(
            (DESIGNS / "TouchBarV2.swift").read_text(encoding="utf-8"), encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        extras = [SOURCES / name for name in (
            "TouchBarPairView.swift", "UsagePanel.swift", "CodexUsageProvider.swift",
            "DSHBalanceProvider.swift", "DeepSeekPricing.swift", "DeepSeekHolidays.swift",
            "DeepSeekHarness.swift", "DeepSeekBalanceProvider.swift", "DeepSeekBalanceView.swift",
            "CodexAppServerQuotaProvider.swift")]
        files = [work / "QuotaStripBody.swift", work / "DeepSeekTouchBarView.swift",
                 work / "TouchBarV2.swift"] + extras
        binary = work / "design-render"
        build = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0"]
            + [str(f) for f in files] + [str(work / "main.swift"), "-o", str(binary),
                                         "-framework", "AppKit", "-framework", "ServiceManagement",
                                         "-framework", "Security", "-framework", "SwiftUI",
                                         "-F", "/System/Library/PrivateFrameworks",
                                         "-framework", "DFRFoundation"],
            capture_output=True, text=True, timeout=420)
        if build.returncode != 0:
            sys.stderr.write(build.stdout + build.stderr)
            return 1
        output = work / "out"
        output.mkdir()
        run = subprocess.run([str(binary), str(output)],
                             env={"QS_LOGO": str(ROOT / "Resources" / "deepseek-logo.png"),
                                  "QS_PEAK_LOGO": str(ROOT / "Resources" / "deepseek-logo-peak.png"),
                                  "QS_CODEX_ICON": str(ROOT / "Resources" / "codex-logo.png"),
                                  "PATH": "/usr/bin:/bin"},
                             capture_output=True, text=True, timeout=180)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if run.returncode != 0:
            return run.returncode
        keeps = pathlib.Path("/tmp/quotastrip-renders")
        keeps.mkdir(exist_ok=True)
        for png in output.glob("*.png"):
            (keeps / png.name).write_bytes(png.read_bytes())
        print("wrote", keeps)
    print("PASS: touch bar v2 renders")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
