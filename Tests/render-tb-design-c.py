#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders the shipped DeepSeek Touch Bar module next to the three "ambient light"
variants in Tests/designs/TBDesignC.swift.

Everything is compiled from the real sources: the left half is the shipped QuotaView
(only its launch lines and the bundle icon lookup are patched in a temp copy), the
right half of row 0 is the real DeepSeekTouchBarView, and rows 1-3 come from the
design-only file. Nothing is written outside a temp dir and /tmp/quotastrip-renders.

The design file also carries its own layout self-check (bounds / overlap / fixed
columns / digit + state stability); this script runs it first and refuses to render
if it reports anything. Synthetic values only: no network, no Keychain.

Output (2x):
  design-c-0.png      shipped module next to the real Codex view
  design-c-1..3.png   the three variants
  design-c-sheet.png  all four rows, labelled
  design-c-states.png peak / off-peak / stale / no-data x three variants
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
DESIGNS = ROOT / "Tests" / "designs"
KEEP = pathlib.Path("/tmp/quotastrip-renders")

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

func money(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

/// 真实账号数据：余额 50.95，本轮初始 71.11（已花 20.16），今日 3.57M tok，命中 78.6%。
func shippedSnapshot() -> DeepSeekSnapshot {
    var value = DeepSeekSnapshot()
    value.balance = money("50.95")
    value.startingBalance = money("71.11")
    value.todayTokens = 3_570_277
    value.todayCacheHitPercent = 78.6
    value.stale = false
    return value
}

/// 近 7 日（11-12…11-18，旧→新）；11-17/18 还没发生，是 0。
let weekTokens: [Int64] = [8_969_898, 106_515_375, 103_088_154, 6_774_405, 3_570_277, 0, 0]

func fixture(phase: DeepSeekPricePhase = .offPeak, stale: Bool = false,
             empty: Bool = false) -> TBCData {
    var data = TBCData()
    if !empty {
        data.balance = money("50.95")
        data.startingBalance = money("71.11")
        data.todayTokens = 3_570_277
        data.todayCache = 78.6
        data.week = weekTokens
        data.todayIndex = 4
    } else {
        data.week = []
        data.todayIndex = 6
    }
    data.phase = phase
    data.stale = stale
    return data
}

func shippedView(phase: DeepSeekPricePhase = .offPeak) -> DeepSeekTouchBarView {
    let view = DeepSeekTouchBarView()
    view.phase = phase
    view.update(shippedSnapshot())
    return view
}

func designView(_ style: TBCStyle, _ data: TBCData) -> TBCView {
    let view = TBCView()
    view.style = style
    view.data = data
    return view
}

/// 合并 item 的真实几何：Codex 0–300，3pt 黑缝，DeepSeek 303–603。
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

func drawText(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight,
              color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
}

/// 评审表：左侧是 603pt 的真实合并条，右侧是标注列（不属于 Touch Bar）。
final class TBCTable: NSView {
    struct Row {
        var image: NSImage?
        var title: String
        var note: String
        var caption: String?
    }

    var rows: [Row] = []
    var headerHeight: CGFloat = 0
    var canvasWidth: CGFloat = 713

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat {
        var height: CGFloat = 0
        var needsHeader = false
        for row in rows {
            if row.caption != nil {
                height += headerHeight
                needsHeader = true
            }
            height += 31
        }
        _ = needsHeader
        return max(0, height - 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        // 标注列与条之间一条极淡的分隔线，避免把标注误读成 Touch Bar 的一部分。
        NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
        NSRect(x: 604, y: 0, width: 0.5, height: bounds.height).fill()

        var y: CGFloat = 0
        for row in rows {
            if let caption = row.caption {
                drawText(caption, x: 6, y: y + 4, size: 10, weight: .semibold,
                         color: NSColor(calibratedWhite: 0.80, alpha: 1))
                y += headerHeight
            }
            if let image = row.image {
                image.draw(in: NSRect(x: 0, y: y, width: 603, height: 30), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if !row.title.isEmpty {
                drawText(row.title, x: 613, y: y + 5.5, size: 9.5, weight: .medium,
                         color: NSColor(calibratedWhite: 0.74, alpha: 1))
            }
            if !row.note.isEmpty {
                drawText(row.note, x: 613, y: y + 17, size: 8, weight: .regular,
                         color: NSColor(calibratedWhite: 0.44, alpha: 1))
            }
            // 1pt 纯黑分隔，和真实 Touch Bar 的黑底一致。
            y += 31
        }
    }
}

func image(_ rep: NSBitmapImageRep) -> NSImage {
    let image = NSImage(size: NSSize(width: 603, height: 30))
    image.addRepresentation(rep)
    return image
}

func write(_ rep: NSBitmapImageRep, _ url: URL) {
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    try! png.write(to: url)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

// ---- 1. 布局自检（不通过就不渲染）----
let check = TBCSelfCheck.run()
print("CHECK layouts=\(check.layouts) issues=\(check.issues.count)")
for entry in check.rows {
    print(String(format: "CASE %@ gap=%.2f balance=%@@%.1f", entry.0, entry.1, entry.2, entry.3))
}
for line in check.digits { print("DIGITS " + line) }
for issue in check.issues { print("ISSUE \(issue)") }
if !check.issues.isEmpty {
    print("FAIL: design C layout check")
    exit(9)
}
let minGap = check.rows.map { $0.1 }.min() ?? 0
print(String(format: "CHECK minGap=%.2f", minGap))

// ---- 2. 单行 ----
var rows: [(String, NSBitmapImageRep)] = [("design-c-0", row(shippedView()))]
for style in TBCStyle.allCases {
    rows.append(("design-c-" + String(style.rawValue), row(designView(style, fixture()))))
}
for (name, rep) in rows {
    write(rep, folder.appendingPathComponent(name + ".png"))
    print(name, rep.pixelsWide, "x", rep.pixelsHigh)
}

// ---- 3. 对照表：现役 + 三个变体 ----
let sheet = TBCTable(frame: NSRect(x: 0, y: 0, width: 713, height: 0))
sheet.rows = [
    TBCTable.Row(image: image(rows[0].1), title: "现役 shipped", note: "余额 + 一行小字", caption: nil),
    TBCTable.Row(image: image(rows[1].1), title: TBCStyle.afterglow.title, note: TBCStyle.afterglow.note, caption: nil),
    TBCTable.Row(image: image(rows[2].1), title: TBCStyle.quiet.title, note: TBCStyle.quiet.note, caption: nil),
    TBCTable.Row(image: image(rows[3].1), title: TBCStyle.whisper.title, note: TBCStyle.whisper.note, caption: nil),
]
let sheetHeight = sheet.contentHeight
sheet.frame = NSRect(x: 0, y: 0, width: 713, height: sheetHeight)
guard let sheetRep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { exit(4) }
sheet.cacheDisplay(in: sheet.bounds, to: sheetRep)
write(sheetRep, folder.appendingPathComponent("design-c-sheet.png"))
print("design-c-sheet", sheetRep.pixelsWide, "x", sheetRep.pixelsHigh)

// ---- 4. 状态表：peak / offPeak / stale / 无数据 ----
let states = TBCTable(frame: NSRect(x: 0, y: 0, width: 713, height: 0))
states.headerHeight = 18
func stateRows(_ caption: String, _ data: TBCData) -> [TBCTable.Row] {
    var list: [TBCTable.Row] = []
    for (index, style) in TBCStyle.allCases.enumerated() {
        let rep = row(designView(style, data))
        list.append(TBCTable.Row(image: image(rep),
                                 title: style.title, note: "",
                                 caption: index == 0 ? caption : nil))
    }
    return list
}
states.rows = stateRows("PEAK 高峰时段 · 09–12 / 14–18", fixture(phase: .peak))
states.rows += stateRows("OFF-PEAK 闲时", fixture(phase: .offPeak))
states.rows += stateRows("STALE 数据过期 · 数值整体压暗 + 明说「过期」", fixture(phase: .offPeak, stale: true))
states.rows += stateRows("NO DATA 无数据 · 全部破折号 + 显式说明", fixture(empty: true))
let statesHeight = states.contentHeight
states.frame = NSRect(x: 0, y: 0, width: 713, height: statesHeight)
guard let statesRep = states.bitmapImageRepForCachingDisplay(in: states.bounds) else { exit(5) }
states.cacheDisplay(in: states.bounds, to: statesRep)
write(statesRep, folder.appendingPathComponent("design-c-states.png"))
print("design-c-states", statesRep.pixelsWide, "x", statesRep.pixelsHigh)
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
    patches = [
        ('let offPeakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) }',
         'let offPeakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")'),
        ('private lazy var peakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo-peak", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) } ?? Self.loadDSHDockIcon()',
         'private lazy var peakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")'),
        ("private(set) var snapshot: DeepSeekSnapshot?", "var snapshot: DeepSeekSnapshot?"),
        ("private(set) var phase: DeepSeekPricePhase", "var phase: DeepSeekPricePhase"),
    ]
    for old, new in patches:
        if old not in deepseek:
            print("FAIL: could not patch DeepSeekTouchBarView.swift for:", old.splitlines()[0][:60])
            return 1
        deepseek = deepseek.replace(old, new)

    with tempfile.TemporaryDirectory(prefix="quotastrip-design-c-") as folder:
        work = pathlib.Path(folder)
        (work / "QuotaStripBody.swift").write_text(body, encoding="utf-8")
        (work / "DeepSeekTouchBarView.swift").write_text(deepseek, encoding="utf-8")
        (work / "TBDesignC.swift").write_text(
            (DESIGNS / "TBDesignC.swift").read_text(encoding="utf-8"), encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        extras = [SOURCES / name for name in (
            "TouchBarPairView.swift", "UsagePanel.swift", "CodexUsageProvider.swift",
            "DSHBalanceProvider.swift", "DeepSeekPricing.swift", "DeepSeekHolidays.swift",
            "DeepSeekHarness.swift", "DeepSeekBalanceProvider.swift", "DeepSeekBalanceView.swift",
            "CodexAppServerQuotaProvider.swift")]
        files = [work / "QuotaStripBody.swift", work / "DeepSeekTouchBarView.swift",
                 work / "TBDesignC.swift"] + extras
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
            print("FAIL: renderer exited", run.returncode)
            return run.returncode

        names = ["design-c-0", "design-c-1", "design-c-2", "design-c-3",
                 "design-c-sheet", "design-c-states"]
        missing = [name for name in names if not (output / (name + ".png")).exists()]
        if missing:
            print("FAIL: missing renders", missing)
            return 2
        expected = {"design-c-0": (1206, 60), "design-c-1": (1206, 60),
                    "design-c-2": (1206, 60), "design-c-3": (1206, 60),
                    "design-c-sheet": (1426, 246), "design-c-states": (1426, 886)}
        for name, (width, height) in expected.items():
            png = (output / (name + ".png")).read_bytes()
            got = (int.from_bytes(png[16:20], "big"), int.from_bytes(png[20:24], "big"))
            if got != (width, height):
                print("FAIL:", name, "size", got, "expected", (width, height))
                return 3
            if len(png) < 2000:
                print("FAIL:", name, "suspiciously small png")
                return 4
        if "issues=0" not in run.stdout:
            print("FAIL: layout check did not report 0 issues")
            return 5

        KEEP.mkdir(exist_ok=True)
        for name in names:
            (KEEP / (name + ".png")).write_bytes((output / (name + ".png")).read_bytes())
        print("wrote", KEEP)
        print("PASS: design C renders + layout check")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
