#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Checks the merged 603pt Touch Bar item: two untouched 300pt views, a 3pt seam,
independent hit areas, and no gesture on the container.

The Codex view is the shipping `QuotaView` compiled from main.swift (only the app
launch lines and the bundle icon lookup are rewritten in a temp copy). Synthetic
data only: no network, no Keychain, nothing outside a temp dir.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

MAIN = r'''
import AppKit

let app = NSApplication.shared

var checks = 0
func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { print("FAIL: \(name)"); exit(1) }
}

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

func deepSeekPercent() -> DeepSeekPercentView {
    let view = DeepSeekPercentView()
    view.remainingPercent = 45
    return view
}

func magpieLive() -> MagpieLiveTouchBarView {
    let view = MagpieLiveTouchBarView()
    var value = MagpieLiveTouchBarView.Data()
    value.remainingPercent = 69.6
    value.todayTokens = 47_186_249
    value.model = "qwen4-max"
    value.sessionTokens = 74_967
    value.sessionCacheHit = 0
    value.tokensPerSecond = 67.5
    value.requestAt = Date()
    view.data = value
    return view
}

expect(TouchBarPairView.baseWidth == 300 + 3 + MagpieLiveTouchBarView.viewWidth, "default = codex + magpie")
expect(TouchBarPairView.fullWidth == TouchBarPairView.baseWidth + 3 + DeepSeekPercentView.viewWidth, "full adds optional deepseek")
expect(TouchBarPairView.gap == 3, "seam is 3pt")

let codex = codexView()
let deep = deepSeekPercent()
let magpie = magpieLive()
let pair = TouchBarPairView(codex: codex, deepSeek: deep, magpie: magpie)
expect(pair.gestureRecognizers.isEmpty, "container adds no gesture recognizer")
expect(!codex.gestureRecognizers.isEmpty, "Codex keeps its own click recognizer")
expect(!deep.gestureRecognizers.isEmpty, "DeepSeek keeps its own click recognizer")
expect(!magpie.gestureRecognizers.isEmpty, "Magpie keeps its own click recognizer")
expect(pair.isOpaque == false, "container stays transparent")

pair.frame = NSRect(x: 0, y: 0, width: TouchBarPairView.baseWidth, height: 30)
pair.layoutSubtreeIfNeeded()
expect(pair.intrinsicContentSize == NSSize(width: TouchBarPairView.baseWidth, height: 30), "intrinsic size matches default width")
expect(codex.frame == NSRect(x: 0, y: 0, width: 300, height: 30), "Codex sits at x=0")
expect(magpie.frame == NSRect(x: 303, y: 0, width: MagpieLiveTouchBarView.viewWidth, height: 30), "Magpie sits after codex")
expect(deep.isHidden, "DeepSeek hidden by default")
print("codex frame:", codex.frame, "magpie frame:", magpie.frame)

// 命中区必须和视觉区一对一：中间 3pt 只命中容器（没有手势），两侧各命中自己的视图。
expect(pair.hitTest(containerPoint: NSPoint(x: 150, y: 15)) === codex, "point in Codex hits Codex")
expect(pair.hitTest(containerPoint: NSPoint(x: 450, y: 15)) === magpie, "point in Magpie hits Magpie")
expect(pair.hitTest(containerPoint: NSPoint(x: 301.5, y: 15)) === pair, "seam hits the container, not a module")
expect(pair.hitTest(containerPoint: NSPoint(x: 0.5, y: 15)) === codex, "Codex left edge still Codex")

// 打开可选 DeepSeek：宽度增加、模块出现在 Magpie 之后。
pair.showsDeepSeek = true
pair.frame = NSRect(x: 0, y: 0, width: TouchBarPairView.fullWidth, height: 30)
pair.layoutSubtreeIfNeeded()
expect(!deep.isHidden, "DeepSeek shown when enabled")
expect(deep.frame == NSRect(x: TouchBarPairView.baseWidth + 3, y: 0, width: DeepSeekPercentView.viewWidth, height: 30), "DeepSeek after magpie")
expect(pair.hitTest(containerPoint: NSPoint(x: TouchBarPairView.baseWidth + 40, y: 15)) === deep, "point in DeepSeek hits DeepSeek")
pair.showsDeepSeek = false
pair.layoutSubtreeIfNeeded()
expect(deep.isHidden, "DeepSeek hidden again when disabled")

// 内部布局未被合并破坏：第一行是 [条 66…186] [金额 →234] [百分比 →292]。
expect(DeepSeekTouchBarView.Layout.contentX == 66, "contentX untouched at 66")
expect(DeepSeekTouchBarView.Layout.barWidth == 120, "bar width untouched at 120")
expect(DeepSeekTouchBarView.Layout.amountRight == 234, "amount column sits at 234")
expect(DeepSeekTouchBarView.Layout.percentRight == 292, "percent sits on the right edge at 292")
expect(DeepSeekTouchBarView.Layout.rightEdge == 292, "shared right edge untouched at 292")

// 渲染默认形态（Codex + Magpie）：开关测试结束后把 frame 收回 baseWidth。
pair.frame = NSRect(x: 0, y: 0, width: TouchBarPairView.baseWidth, height: 30)
pair.layoutSubtreeIfNeeded()

let scale: CGFloat = 2
let logical = NSSize(width: TouchBarPairView.itemWidth, height: 30)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(logical.width * scale),
                           pixelsHigh: Int(logical.height * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = logical
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.black.setFill()
NSRect(origin: .zero, size: logical).fill()
guard let rendered = pair.bitmapImageRepForCachingDisplay(in: pair.bounds) else { exit(2) }
NSGraphicsContext.restoreGraphicsState()
pair.cacheDisplay(in: pair.bounds, to: rendered)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let image = NSImage(size: pair.bounds.size)
image.addRepresentation(rendered)
image.draw(in: pair.bounds, from: .zero, operation: .sourceOver, fraction: 1,
           respectFlipped: true, hints: nil)
NSGraphicsContext.restoreGraphicsState()

func dashed(_ x: CGFloat, _ color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    path.setLineDash([3, 3], count: 2, phase: 0)
    path.move(to: NSPoint(x: x, y: 0))
    path.line(to: NSPoint(x: x, y: 30))
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
let cyan = NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.95, alpha: 0.85)
let yellow = NSColor.systemYellow.withAlphaComponent(0.85)
let pink = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.75, alpha: 0.85)
for x in [58.0, 178.0] { dashed(x, cyan) }
dashed(226, yellow)
// 3pt 缝的两条边界。
dashed(300, cyan.withAlphaComponent(0.5))
dashed(303, cyan.withAlphaComponent(0.5))
dashed(TouchBarPairView.baseWidth, pink.withAlphaComponent(0.5))

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!
    .write(to: folder.appendingPathComponent("composite-3pt.png"))
print("composite.png", rep.pixelsWide, "x", rep.pixelsHigh)
print("PASS: \(checks) merged-item checks (frames, hit testing, no container gesture)")
'''


def main() -> int:
    body = (SOURCES / "main.swift").read_text(encoding="utf-8")
    body = body[:body.index("let app = NSApplication.shared")]
    icon_line = 'self.icon = Bundle.main.path(forResource: iconFile, ofType: "png").flatMap { NSImage(contentsOfFile: $0) }'
    if icon_line not in body:
        print("FAIL: icon lookup not found in main.swift")
        return 1
    body = body.replace(icon_line,
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

    qwen = (SOURCES / "QwenTouchBarView.swift").read_text(encoding="utf-8")
    qwen = qwen.replace(
        'private let logo: NSImage? = Bundle.main.path(forResource: "magpie-logo", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) }',
        'private let logo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_MAGPIE_LOGO"] ?? "")')

    with tempfile.TemporaryDirectory(prefix="quotastrip-pair-check-") as folder:
        work = pathlib.Path(folder)
        (work / "QuotaStripBody.swift").write_text(body, encoding="utf-8")
        (work / "DeepSeekTouchBarView.swift").write_text(deepseek, encoding="utf-8")
        (work / "QwenTouchBarView.swift").write_text(qwen, encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        extras = [SOURCES / name for name in (
            "TouchBarPairView.swift", "UsagePanel.swift", "CodexUsageProvider.swift",
            "DSHBalanceProvider.swift", "DeepSeekPricing.swift",
            "DeepSeekHolidays.swift", "DeepSeekHarness.swift", "DeepSeekBalanceProvider.swift",
            "DeepSeekBalanceView.swift", "CodexAppServerQuotaProvider.swift",
            "DSHSessionProvider.swift", "DSHSessionTitles.swift",
            "JimmyCloudPlanProvider.swift", "MagpieProvider.swift",
            "DSHOpenSession.swift")]
        files = [work / "QuotaStripBody.swift", work / "DeepSeekTouchBarView.swift",
                 work / "QwenTouchBarView.swift"] + extras
        binary = work / "pair-check"
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
                             env={"QS_LOGO": str(ROOT / "Resources" / "deepseek-logo.png"),
                                  "QS_PEAK_LOGO": str(ROOT / "Resources" / "deepseek-logo-peak.png"),
                                  "QS_CODEX_ICON": str(ROOT / "Resources" / "codex-logo.png"),
                                  "QS_MAGPIE_LOGO": str(ROOT / "Resources" / "magpie-logo.png"),
                                  "PATH": "/usr/bin:/bin"},
                             capture_output=True, text=True, timeout=120)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if run.returncode != 0:
            return run.returncode
        keeps = pathlib.Path("/tmp/quotastrip-renders")
        keeps.mkdir(exist_ok=True)
        (keeps / "composite-3pt.png").write_bytes((output / "composite-3pt.png").read_bytes())
        print("wrote", keeps)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
