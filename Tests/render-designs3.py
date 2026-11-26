#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Round 3: Touch Bar (5 layouts) + menu-bar status item (5 layouts), real data shape.

Touch Bar rows: real Codex QuotaView (compiled from main.swift, only launch lines and
icon lookup patched) + design view, laid out 300 + 3 + 300 like the shipped item.
Menu-bar rows: synthetic menu-bar strip, dark and light, neighbours drawn as dots.
Fixture mirrors the live account (balance 52.09 of 71.11 held, 19.02 spent).
No network, no Keychain; everything lives in a temp dir except /tmp/quotastrip-renders.
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
let posix = Locale(identifier: "en_US_POSIX")

func codexView() -> QuotaView {
    let view = QuotaView(iconFile: "codex-logo", bundleID: "com.openai.codex", appName: "Codex.app",
                         flagName: "codex_attention", fallbackURL: "https://chatgpt.com/codex")
    let now = Date().timeIntervalSince1970
    view.service = QuotaService(ok: true, stale: false,
                                five: QuotaWindow(pct: 100, reset: now + 3 * 3600),
                                week: QuotaWindow(pct: 4, reset: now + 4 * 86400),
                                attention: false, source: "fixture")
    return view
}

func fixture(balance: String = "52.09") -> DeepSeekSnapshot {
    var v = DeepSeekSnapshot()
    v.balance = Decimal(string: balance, locale: posix)
    v.startingBalance = Decimal(string: "71.11", locale: posix)
    v.todayTokens = 68_390_000
    v.todayCacheHitPercent = 97.7
    v.stale = false
    return v
}

func shipped(_ phase: DeepSeekPricePhase) -> DeepSeekTouchBarView {
    let v = DeepSeekTouchBarView(); v.phase = phase; v.update(fixture()); return v
}

func tb(_ style: TBStyle, _ phase: DeepSeekPricePhase, balance: String = "52.09") -> TBDesignView {
    let v = TBDesignView(); v.style = style; v.phase = phase; v.update(fixture(balance: balance)); return v
}

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
        let image = NSImage(size: view.bounds.size); image.addRepresentation(piece)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: x, y: 0, width: 300, height: 30), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

var geometryProblems = 0
/// 检查视图记录下来的每段文字：必须在边界内，且互不相交（图标左侧 36pt 之后才允许文字）。
func audit(_ name: String, drawn: [(String, NSRect)], bounds: NSRect, minX: CGFloat) {
    print("audit", name, "runs:", drawn.count)
    for (text, rect) in drawn {
        if rect.minX < minX - 0.5 || rect.maxX > bounds.maxX + 0.5 || rect.minY < -3 || rect.maxY > bounds.maxY + 3 {
            print("GEOMETRY \(name): '\(text)' outside bounds \(rect)"); geometryProblems += 1
        }
    }
    for i in 0..<drawn.count {
        for j in (i + 1)..<drawn.count {
            let a = drawn[i].1.insetBy(dx: 0, dy: 1.5), b = drawn[j].1.insetBy(dx: 0, dy: 1.5)
            if a.intersects(b) {
                print("GEOMETRY \(name): '\(drawn[i].0)' overlaps '\(drawn[j].0)'"); geometryProblems += 1
            }
        }
    }
}

func tbRow(_ right: NSView) -> NSBitmapImageRep {
    if let v = right as? TBDesignView {
        v.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        let probe = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: probe)
        audit("TB-\(v.style)-\(v.phase)", drawn: v.drawn, bounds: v.bounds, minX: 34)
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1206, pixelsHigh: 60, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 603, height: 30)
    compose(right, into: rep)
    return rep
}

func mb(_ style: MBStyle, dark: Bool, phase: DeepSeekPricePhase = .offPeak, balance: String = "52.09",
        label: String = "") -> NSBitmapImageRep {
    let v = MBDesignView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    v.style = style; v.dark = dark; v.phase = phase; v.label = label
    v.update(fixture(balance: balance))
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    audit("MB-\(style)-\(dark ? "dark" : "light")-\(balance)",
          drawn: v.drawn.filter { $0.0 != label || label.isEmpty },
          bounds: v.bounds, minX: 0)
    return rep
}

final class SheetView: NSView {
    var images: [(NSImage, NSSize)] = []
    var gap: CGFloat = 1
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        var y: CGFloat = 0
        for (image, size) in images {
            image.draw(in: NSRect(x: 0, y: y, width: size.width, height: size.height), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            y += size.height + gap
        }
    }
}

func save(_ rep: NSBitmapImageRep, _ url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func sheet(_ reps: [NSBitmapImageRep], size: NSSize, gap: CGFloat, to url: URL) {
    let height = CGFloat(reps.count) * (size.height + gap) - gap
    let view = SheetView(frame: NSRect(x: 0, y: 0, width: size.width, height: height))
    view.gap = gap
    view.images = reps.map { rep in
        let image = NSImage(size: size); image.addRepresentation(rep); return (image, size)
    }
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    save(rep, url)
    print(url.lastPathComponent, rep.pixelsWide, "x", rep.pixelsHigh)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])

// Touch Bar: shipped + T1..T5 (off-peak) and shipped + T3 (peak) and low-balance T1
var tbRows: [NSBitmapImageRep] = [tbRow(shipped(.offPeak))]
for style in TBStyle.allCases { tbRows.append(tbRow(tb(style, .offPeak))) }
sheet(tbRows, size: NSSize(width: 603, height: 30), gap: 1, to: out.appendingPathComponent("r3-touchbar.png"))
for (i, rep) in tbRows.enumerated() { save(rep, out.appendingPathComponent("r3-tb-\(i).png")) }

let tbPeak = [tbRow(shipped(.peak)), tbRow(tb(.phase, .peak)), tbRow(tb(.runway, .peak, balance: "6.20")),
              tbRow(tb(.single, .offPeak, balance: "2.10"))]
sheet(tbPeak, size: NSSize(width: 603, height: 30), gap: 1, to: out.appendingPathComponent("r3-touchbar-states.png"))

print("TB geometry problems so far:", geometryProblems)
// Menu bar: dark + light, normal balance, then a low balance row
for (dark, tag) in [(true, "dark"), (false, "light")] {
    var reps: [NSBitmapImageRep] = []
    for style in MBStyle.allCases {
        reps.append(mb(style, dark: dark, label: "\(["A","B","C","D","E"][style.rawValue])"))
    }
    reps.append(mb(.balance, dark: dark, balance: "6.20", label: "A 低"))
    reps.append(mb(.dualText, dark: dark, balance: "6.20", label: "D 低"))
    sheet(reps, size: NSSize(width: 300, height: 24), gap: 1, to: out.appendingPathComponent("r3-menubar-\(tag).png"))
}
print("TOTAL geometry problems:", geometryProblems)
if geometryProblems > 0 { exit(9) }
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

    ds = (SOURCES / "DeepSeekTouchBarView.swift").read_text(encoding="utf-8")
    ds = ds.replace(
        'let offPeakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) }',
        'let offPeakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")')
    ds = ds.replace(
        'private lazy var peakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo-peak", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) } ?? Self.loadDSHDockIcon()',
        'private lazy var peakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")')
    ds = ds.replace("private(set) var snapshot: DeepSeekSnapshot?", "var snapshot: DeepSeekSnapshot?")
    ds = ds.replace("private(set) var phase: DeepSeekPricePhase", "var phase: DeepSeekPricePhase")

    with tempfile.TemporaryDirectory(prefix="quotastrip-r3-") as folder:
        work = pathlib.Path(folder)
        (work / "QuotaStripBody.swift").write_text(body, encoding="utf-8")
        (work / "DeepSeekTouchBarView.swift").write_text(ds, encoding="utf-8")
        (work / "QuotaDesigns3.swift").write_text((DESIGNS / "QuotaDesigns3.swift").read_text(encoding="utf-8"),
                                                  encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        extras = [SOURCES / n for n in (
            "TouchBarPairView.swift", "UsagePanel.swift", "CodexUsageProvider.swift", "DSHBalanceProvider.swift",
            "DeepSeekPricing.swift", "DeepSeekHolidays.swift", "DeepSeekHarness.swift",
            "DeepSeekBalanceProvider.swift", "DeepSeekBalanceView.swift", "CodexAppServerQuotaProvider.swift")]
        files = [work / "QuotaStripBody.swift", work / "DeepSeekTouchBarView.swift",
                 work / "QuotaDesigns3.swift"] + extras
        binary = work / "r3-render"
        build = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0"]
            + [str(f) for f in files] + [str(work / "main.swift"), "-o", str(binary),
               "-framework", "AppKit", "-framework", "ServiceManagement", "-framework", "Security",
               "-framework", "SwiftUI", "-F", "/System/Library/PrivateFrameworks", "-framework", "DFRFoundation"],
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
    print("PASS: round-3 renders")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
