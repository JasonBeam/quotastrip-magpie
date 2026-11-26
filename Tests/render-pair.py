#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders the *real* Codex QuotaView next to the *real* DeepSeekTouchBarView.

Both views are compiled from the shipped sources: main.swift is used as-is except
for its three top-level launch lines and the bundle icon lookup (a temp copy only),
so the Codex row comes from the same draw(_:) code that runs on the Touch Bar.

Output (2x, 603x30pt = the merged item: 300 + 3pt seam + 300):
  pair-real.png    what the two items actually look like side by side
  pair-guides.png  same, plus dashed guide lines over the bars / percent / right edge

Synthetic values only: no network, no Keychain, nothing outside a temp dir.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

MAIN = r'''
import AppKit

// Nothing below touches the network: the Codex view is fed a fixture service and the
// DeepSeek view a fixture snapshot, exactly like the payloads each provider produces.
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

func deepSeekView() -> DeepSeekTouchBarView {
    var value = DeepSeekSnapshot()
    value.balance = Decimal(string: "45.69", locale: Locale(identifier: "en_US_POSIX"))
    value.startingBalance = Decimal(string: "71.11", locale: Locale(identifier: "en_US_POSIX"))
    value.todayTokens = 19_926_242
    value.todayCacheHitPercent = 98.4
    value.monthTokens = 298_277_533
    value.stale = false
    let view = DeepSeekTouchBarView()
    view.phase = .offPeak
    view.update(value)
    return view
}

func render(_ view: NSView, into rep: NSBitmapImageRep, at offset: CGFloat) {
    guard let piece = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: piece)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(piece)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: offset, y: 0, width: view.bounds.width, height: view.bounds.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
}

func dash(_ x: CGFloat, color: NSColor, height: CGFloat, in rep: NSBitmapImageRep) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    path.setLineDash([3, 3], count: 2, phase: 0)
    path.move(to: NSPoint(x: x, y: 0))
    path.line(to: NSPoint(x: x, y: height))
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let scale: CGFloat = 2
let logical = NSSize(width: TouchBarPairView.itemWidth, height: 30)

func renderPair(guides: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(logical.width * scale),
                               pixelsHigh: Int(logical.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = logical
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(origin: .zero, size: logical).fill()
    NSGraphicsContext.restoreGraphicsState()

    // 合成 item 内部：Codex 在 0，DeepSeek 在 303，中间的 3pt 由容器自己留。
    let pair = TouchBarPairView(codex: codexView(), deepSeek: deepSeekView())
    pair.frame = NSRect(origin: .zero, size: logical)
    pair.layoutSubtreeIfNeeded()
    render(pair, into: rep, at: 0)

    if guides {
        let itemH: CGFloat = 30
        // Codex: bar 58…178, percent right 226 (percent is right-aligned).
        dash(58, color: NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.95, alpha: 0.85), height: itemH, in: rep)
        dash(178, color: NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.95, alpha: 0.85), height: itemH, in: rep)
        dash(226, color: NSColor.systemYellow.withAlphaComponent(0.8), height: itemH, in: rep)
        // DeepSeek 在合并 item 里从 303 开始：bar 66…186 → 369…489，百分比 234 → 537，右边界 292 → 595。
        let origin = TouchBarPairView.gap + QuotaView.viewWidth
        let cyan = NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.95, alpha: 0.85)
        let yellow = NSColor.systemYellow.withAlphaComponent(0.8)
        let pink = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.75, alpha: 0.85)
        dash(origin + DeepSeekTouchBarView.Layout.barX, color: cyan, height: itemH, in: rep)
        dash(origin + DeepSeekTouchBarView.Layout.barX + DeepSeekTouchBarView.Layout.barWidth,
             color: cyan, height: itemH, in: rep)
        dash(origin + DeepSeekTouchBarView.Layout.percentRight, color: yellow, height: itemH, in: rep)
        dash(origin + DeepSeekTouchBarView.Layout.rightEdge, color: pink, height: itemH, in: rep)
        // 3pt 缝的两条边界。
        dash(300, color: cyan.withAlphaComponent(0.5), height: itemH, in: rep)
        dash(303, color: cyan.withAlphaComponent(0.5), height: itemH, in: rep)
    }
    return rep
}

for (name, guides) in [("pair-real", false), ("pair-guides", true)] {
    let rep = renderPair(guides: guides)
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
    print(name, rep.pixelsWide, "x", rep.pixelsHigh)
}
print(String(format: "codex bar %.0f…%.0f  percentRight %.0f | deepseek bar %.0f…%.0f  percentRight %.0f  rightEdge %.0f",
             QuotaViewMetrics.barX, QuotaViewMetrics.barX + QuotaViewMetrics.barWidth, QuotaViewMetrics.percentRight,
             DeepSeekTouchBarView.Layout.barX,
             DeepSeekTouchBarView.Layout.barX + DeepSeekTouchBarView.Layout.barWidth,
             DeepSeekTouchBarView.Layout.percentRight, DeepSeekTouchBarView.Layout.rightEdge))
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
    # Expose the Codex column metrics to the harness without touching the shipping code:
    # the harness prints them from a tiny shim appended to the temp copy only.
    body += "\n\n// temp-copy shim for the render harness\nenum QuotaViewMetrics {\n"
    body += "    static let barX: CGFloat = 58\n    static let barWidth: CGFloat = 120\n    static let percentRight: CGFloat = 226\n}\n"

    deepseek = (SOURCES / "DeepSeekTouchBarView.swift").read_text(encoding="utf-8")
    offpeak = ROOT / "Resources" / "deepseek-logo.png"
    peak = ROOT / "Resources" / "deepseek-logo-peak.png"
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

    with tempfile.TemporaryDirectory(prefix="quotastrip-pair-") as folder:
        work = pathlib.Path(folder)
        (work / "QuotaStripBody.swift").write_text(body, encoding="utf-8")
        (work / "DeepSeekTouchBarView.swift").write_text(deepseek, encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        extras = [SOURCES / name for name in (
            "TouchBarPairView.swift", "UsagePanel.swift", "CodexUsageProvider.swift",
            "DSHBalanceProvider.swift", "DeepSeekPricing.swift", "DeepSeekHolidays.swift",
            "DeepSeekHarness.swift", "DeepSeekBalanceProvider.swift", "DeepSeekBalanceView.swift",
            "CodexAppServerQuotaProvider.swift")]
        files = [work / "QuotaStripBody.swift", work / "DeepSeekTouchBarView.swift"] + extras
        binary = work / "pair-render"
        # The Codex view only needs AppKit; the DeepSeek sources pull in the same
        # frameworks as build.sh, so link them all rather than prune symbols.
        result = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0"]
            + [str(f) for f in files] + [str(work / "main.swift"), "-o", str(binary),
                                         "-framework", "AppKit", "-framework", "ServiceManagement",
                                         "-framework", "Security", "-F", "/System/Library/PrivateFrameworks",
                                         "-framework", "DFRFoundation"],
            capture_output=True, text=True, timeout=300)
        if result.returncode != 0:
            sys.stderr.write(result.stdout + result.stderr)
            return 1
        output = work / "out"
        output.mkdir()
        run = subprocess.run([str(binary), str(output)],
                             env={"QS_LOGO": str(offpeak), "QS_PEAK_LOGO": str(peak),
                                  "QS_CODEX_ICON": str(ROOT / "Resources" / "codex-logo.png"),
                                  "PATH": "/usr/bin:/bin"},
                             capture_output=True, text=True, timeout=120)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if run.returncode != 0:
            return run.returncode
        keeps = pathlib.Path("/tmp/quotastrip-renders")
        keeps.mkdir(exist_ok=True)
        for name in ("pair-real", "pair-guides"):
            (keeps / f"{name}.png").write_bytes((output / f"{name}.png").read_bytes())
        print("wrote", keeps)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
