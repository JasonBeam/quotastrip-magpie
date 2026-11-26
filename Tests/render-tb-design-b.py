#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders the real Codex QuotaView beside the three "instrument / tick" DeepSeek
Touch Bar designs in Tests/designs/TBDesignB.swift.

Same compile recipe as render-tb-v2.py: the Codex half is the shipped QuotaView
compiled from main.swift (only the launch lines and the bundle icon lookup are
patched in a temp copy), the DeepSeek half is the shipped view plus the
design-only TBDesignBView. Everything is offscreen; no network, no Keychain.

Outputs (2x, 1206x60 each) into /tmp/quotastrip-renders:
  design-b-0.png            现役（余额 + 一行小字）
  design-b-1.png            B1 油表
  design-b-2.png            B2 电平梯
  design-b-3.png            B3 航空
  design-b-sheet.png        四行对照（第一行现役，后三行变体）
  design-b-states.png       边界值状态表（0 / 5 / 20 / 78.6 / 100 / 缺失 / peak）
  design-b-state-*.png      每个状态单独一张

Self-checks (any problem -> exit 9):
  * 每段文字、每根刻度是否越出 34...292 与 0...30；
  * 文字与文字、文字与图形是否相交；
  * 指针位置是否严格等于 ratio * scaleWidth、0% / 100% 的点亮数是否正确；
  * 像素级：3pt 黑缝、右边界外、左边界外、顶边、底边必须全黑。
"""
import pathlib
import subprocess
import sys
import tempfile
import time

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

func makeSnapshot(balance: String? = "50.95",
                  starting: String? = "71.11",
                  tokens: Int64? = 3_570_277,
                  cache: Double? = 78.6) -> DeepSeekSnapshot {
    var value = DeepSeekSnapshot()
    if let balance {
        value.balance = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX"))
    }
    if let starting {
        value.startingBalance = Decimal(string: starting, locale: Locale(identifier: "en_US_POSIX"))
    }
    if let tokens { value.todayTokens = tokens }
    if let cache { value.todayCacheHitPercent = cache }
    value.currency = "CNY"
    value.stale = false
    return value
}

func shippedView() -> DeepSeekTouchBarView {
    let view = DeepSeekTouchBarView()
    view.phase = .offPeak
    view.update(makeSnapshot())
    return view
}

func designView(_ style: TBStyleB,
                phase: DeepSeekPricePhase = .offPeak,
                balance: String? = "50.95",
                starting: String? = "71.11",
                tokens: Int64? = 3_570_277,
                cache: Double? = 78.6,
                fuelTail: TBDesignBView.TBFuelTail = .spent) -> TBDesignBView {
    let view = TBDesignBView()
    view.style = style
    view.phase = phase
    view.fuelTail = fuelTail
    view.update(makeSnapshot(balance: balance, starting: starting, tokens: tokens, cache: cache))
    return view
}

// MARK: - 审计

var problems: [String] = []

func isInk(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
    guard let color = rep.colorAt(x: x, y: y) else { return false }
    return color.redComponent + color.greenComponent + color.blueComponent > 0.03
}

func pixelAudit(_ name: String, _ rep: NSBitmapImageRep) {
    let height = rep.pixelsHigh
    // 合并 item 里 Codex 结束于 px 600，DeepSeek 从 px 606 开始：600..605 必须全黑。
    for x in 600..<606 {
        for y in 0..<height where isInk(rep, x, y) {
            problems.append("\(name): 3pt 黑缝 px(\(x),\(y)) 有内容")
            break
        }
    }
    // 设计右边界 292pt -> 合成 px 1190；1192 起必须全黑。
    for x in 1192..<1206 {
        for y in 0..<height where isInk(rep, x, y) {
            problems.append("\(name): 右边界外 px(\(x),\(y)) 有内容")
            break
        }
    }
    // 设计左边界 0..3.5pt（logo 从 4pt 起）：px 607..613 必须全黑。
    for x in 607..<614 {
        for y in 0..<height where isInk(rep, x, y) {
            problems.append("\(name): 左边界外 px(\(x),\(y)) 有内容")
            break
        }
    }
    for x in 606..<1206 {
        if isInk(rep, x, 0) {
            problems.append("\(name): 顶边 px(\(x),0) 有内容")
            break
        }
        if isInk(rep, x, height - 1) {
            problems.append("\(name): 底边 px(\(x),\(height - 1)) 有内容")
            break
        }
    }
}

func auditView(_ name: String, _ view: TBDesignBView) {
    for (string, rect) in view.textRuns {
        if rect.minX < 34.0 || rect.maxX > 292.6 || rect.minY < -0.01 || rect.maxY > 30.05 {
            problems.append("\(name): 文字 '\(string)' 越界 \(rect)")
        }
    }
    for (tag, rect) in view.marks {
        if rect.minX < 33.5 || rect.maxX > 292.6 || rect.minY < -0.01 || rect.maxY > 30.05 {
            problems.append("\(name): 图形 '\(tag)' 越界 \(rect)")
        }
    }

    let runs = view.textRuns
    if runs.count > 1 {
        for i in 0..<(runs.count - 1) {
            for j in (i + 1)..<runs.count {
                let a = runs[i].1.insetBy(dx: -0.2, dy: 1.2)
                let b = runs[j].1.insetBy(dx: -0.2, dy: 1.2)
                if a.intersects(b) {
                    problems.append("\(name): 文字 '\(runs[i].0)' 与 '\(runs[j].0)' 相交")
                }
            }
        }
    }
    for (string, rect) in runs {
        let a = rect.insetBy(dx: -0.2, dy: 1.2)
        for (tag, mark) in view.marks where a.intersects(mark) {
            problems.append("\(name): 文字 '\(string)' 与图形 '\(tag)' 相交")
        }
    }

    for report in view.reports {
        if report.lit < 0 || report.lit > report.total {
            problems.append("\(name): \(report.name) lit \(report.lit) 不在 0...\(report.total)")
        }
        guard let needle = report.needleX, let ratio = report.ratio else { continue }
        if needle < report.scaleX - 0.02 || needle > report.scaleX + report.scaleWidth + 0.02 {
            problems.append("\(name): \(report.name) 指针 \(needle) 跑出刻度")
        }
        let expected = report.scaleX + CGFloat(ratio) * report.scaleWidth
        if abs(needle - expected) > 0.002 {
            problems.append("\(name): \(report.name) 指针 \(needle) != 比例映射 \(expected)")
        }
        if abs(ratio) < 0.0001 {
            if report.name == "segments" {
                if report.lit != 0 {
                    problems.append("\(name): segments 在 0% 点亮了 \(report.lit) 格")
                }
            } else if report.lit > 1 {
                problems.append("\(name): \(report.name) 在 0% 点亮了 \(report.lit) 根刻度")
            }
        }
        if abs(ratio - 1) < 0.0001 && report.lit != report.total {
            problems.append("\(name): \(report.name) 在 100% 只点亮 \(report.lit)/\(report.total)")
        }
    }
}

// MARK: - 合成

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
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

func row(_ right: NSView, name: String) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1206, pixelsHigh: 60,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 603, height: 30)
    compose(right, into: rep)
    if let design = right as? TBDesignBView {
        auditView(name, design)
    }
    pixelAudit(name, rep)
    return rep
}

// MARK: - 输出

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

final class SheetView: NSView {
    var images: [NSImage] = []
    var labels: [String] = []
    var labelX: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        for (index, image) in images.enumerated() {
            image.draw(in: NSRect(x: 0, y: CGFloat(index) * 31, width: 603, height: 30),
                       from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            if index < labels.count && labelX > 0 {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor(white: 0.74, alpha: 1)
                ]
                (labels[index] as NSString).draw(
                    at: NSPoint(x: labelX, y: CGFloat(index) * 31 + 9),
                    withAttributes: attributes)
            }
        }
    }
}

func sheet(_ entries: [(String, NSBitmapImageRep)], name: String, labelled: Bool) {
    let width: CGFloat = labelled ? 780 : 603
    let height = CGFloat(entries.count) * 31 - 1
    let view = SheetView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    view.labels = entries.map { $0.0 }
    view.labelX = labelled ? 615 : 0
    view.images = entries.map { entry in
        let image = NSImage(size: NSSize(width: 603, height: 30))
        image.addRepresentation(entry.1)
        return image
    }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(4) }
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: folder.appendingPathComponent(name + ".png"))
    print("SHEET", name, rep.pixelsWide, "x", rep.pixelsHigh)
}

let shippedRow = row(shippedView(), name: "design-b-0")
var rows: [(String, NSBitmapImageRep)] = [("现役 · 余额/今日/缓存，无刻度", shippedRow)]
rows.append(("B1 油表 · 17 刻度 + 指针", row(designView(.fuel), name: "design-b-1")))
rows.append(("B2 电平梯 · 20 格 + 近 7 日", row(designView(.segments), name: "design-b-2")))
rows.append(("B3 航空 · 21 刻度 + 缓存表", row(designView(.aviation), name: "design-b-3")))

for (index, entry) in rows.enumerated() where index > 0 {
    let fileName = "design-b-" + String(index)
    try! entry.1.representation(using: .png, properties: [:])!
        .write(to: folder.appendingPathComponent(fileName + ".png"))
    print("ROW", fileName, entry.1.pixelsWide, "x", entry.1.pixelsHigh)
}
try! shippedRow.representation(using: .png, properties: [:])!
    .write(to: folder.appendingPathComponent("design-b-0.png"))
print("ROW design-b-0", shippedRow.pixelsWide, "x", shippedRow.pixelsHigh)

sheet(rows, name: "design-b-sheet", labelled: true)

// MARK: - 边界值状态

var states: [(String, NSBitmapImageRep)] = []
states.append(("现役 · 余额 ¥50.95", row(shippedView(), name: "state-shipped")))
states.append(("B1 油表 · 0%", row(designView(.fuel, balance: "0.00"), name: "state-a-0")))
states.append(("B1 油表 · 5%", row(designView(.fuel, balance: "3.56"), name: "state-a-5")))
states.append(("B1 油表 · 20%", row(designView(.fuel, balance: "14.22"), name: "state-a-20")))
states.append(("B1 油表 · 78.6%", row(designView(.fuel, balance: "55.89"), name: "state-a-786")))
states.append(("B1 油表 · 100%", row(designView(.fuel, balance: "71.11"), name: "state-a-100")))
states.append(("B1 油表 · 分母缺失", row(designView(.fuel, starting: nil), name: "state-a-nil-start")))
states.append(("B1 油表 · 余额缺失", row(designView(.fuel, balance: nil), name: "state-a-nil-balance")))
states.append(("B1 油表 · peak 图标", row(designView(.fuel, phase: .peak), name: "state-a-peak")))
states.append(("B1 油表 · 今日 0 token", row(designView(.fuel, tokens: 0), name: "state-a-token0")))
states.append(("B1 油表 · 大额 ¥1.23K", row(designView(.fuel, balance: "1234.56", starting: "2000.00"),
                                             name: "state-a-big")))
states.append(("B1 油表 · 行2 换成缓存", row(designView(.fuel, fuelTail: .cache),
                                          name: "state-a-cache-tail")))
states.append(("B2 电平梯 · 0%", row(designView(.segments, balance: "0.00"), name: "state-b-0")))
states.append(("B2 电平梯 · 78.6%", row(designView(.segments, balance: "55.89"), name: "state-b-786")))
states.append(("B2 电平梯 · 100%", row(designView(.segments, balance: "71.11"), name: "state-b-100")))
states.append(("B3 航空 · 0%", row(designView(.aviation, balance: "0.00"), name: "state-c-0")))
states.append(("B3 航空 · 78.6%", row(designView(.aviation, balance: "55.89"), name: "state-c-786")))
states.append(("B3 航空 · 100%", row(designView(.aviation, balance: "71.11"), name: "state-c-100")))
states.append(("B3 航空 · 缓存 0%", row(designView(.aviation, cache: 0), name: "state-c-cache0")))
states.append(("B3 航空 · 缓存 100%", row(designView(.aviation, cache: 100), name: "state-c-cache100")))
states.append(("B3 航空 · 缓存缺失", row(designView(.aviation, cache: nil), name: "state-c-cache-nil")))
states.append(("B3 航空 · 缓存 78.6%", row(designView(.aviation), name: "state-c-cache786")))

for (index, entry) in states.enumerated() where index > 0 {
    let fileName = "design-b-state-" + String(format: "%02d", index)
    try! entry.1.representation(using: .png, properties: [:])!
        .write(to: folder.appendingPathComponent(fileName + ".png"))
}
sheet(states, name: "design-b-states", labelled: true)

if problems.isEmpty {
    print("AUDIT OK: 0 problems")
} else {
    for problem in problems.prefix(80) {
        print("AUDIT", problem)
    }
    print("AUDIT FAIL:", problems.count, "problems")
    exit(9)
}
'''


def stable_read(path: pathlib.Path, tries: int = 12) -> bytes:
    """Sources are being edited by another session while we render; read only a
    file whose size and mtime agree before and after the read."""
    data = path.read_bytes()
    for _ in range(tries):
        before = path.stat()
        data = path.read_bytes()
        after = path.stat()
        if (before.st_mtime_ns == after.st_mtime_ns
                and before.st_size == after.st_size == len(data)):
            return data
        time.sleep(0.5)
    return data


def main() -> int:
    body = stable_read(SOURCES / "main.swift").decode("utf-8")
    cutoff = body.index("let app = NSApplication.shared")
    body = body[:cutoff]
    icon_line = 'self.icon = Bundle.main.path(forResource: iconFile, ofType: "png").flatMap { NSImage(contentsOfFile: $0) }'
    if icon_line not in body:
        print("FAIL: could not find the icon lookup in main.swift")
        return 1
    body = body.replace(
        icon_line,
        'self.icon = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_CODEX_ICON"] ?? "")')

    deepseek = stable_read(SOURCES / "DeepSeekTouchBarView.swift").decode("utf-8")
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

    design_b = stable_read(DESIGNS / "TBDesignB.swift").decode("utf-8")

    with tempfile.TemporaryDirectory(prefix="quotastrip-tbdesignb-") as folder:
        work = pathlib.Path(folder)
        (work / "QuotaStripBody.swift").write_text(body, encoding="utf-8")
        (work / "DeepSeekTouchBarView.swift").write_text(deepseek, encoding="utf-8")
        (work / "TBDesignB.swift").write_text(design_b, encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        extra_names = (
            "TouchBarPairView.swift", "UsagePanel.swift", "CodexUsageProvider.swift",
            "DSHBalanceProvider.swift", "DeepSeekPricing.swift", "DeepSeekHolidays.swift",
            "DeepSeekHarness.swift", "DeepSeekBalanceProvider.swift", "DeepSeekBalanceView.swift",
            "CodexAppServerQuotaProvider.swift")
        # compile from frozen copies so a concurrent edit cannot invalidate the build
        extras = []
        for name in extra_names:
            dest = work / name
            dest.write_bytes(stable_read(SOURCES / name))
            extras.append(dest)
        files = [work / "QuotaStripBody.swift", work / "DeepSeekTouchBarView.swift",
                 work / "TBDesignB.swift"] + extras
        binary = work / "design-b-render"
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
        run = subprocess.run(
            [str(binary), str(output)],
            env={"QS_LOGO": str(ROOT / "Resources" / "deepseek-logo.png"),
                 "QS_PEAK_LOGO": str(ROOT / "Resources" / "deepseek-logo-peak.png"),
                 "QS_CODEX_ICON": str(ROOT / "Resources" / "codex-logo.png"),
                 "PATH": "/usr/bin:/bin"},
            capture_output=True, text=True, timeout=240)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)

        keeps = pathlib.Path("/tmp/quotastrip-renders")
        keeps.mkdir(exist_ok=True)
        written = 0
        for png in sorted(output.glob("*.png")):
            (keeps / png.name).write_bytes(png.read_bytes())
            written += 1
        print("wrote", written, "png files to", keeps)
        if run.returncode != 0:
            return run.returncode
    print("PASS: touch bar design B renders, 0 audit problems")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
