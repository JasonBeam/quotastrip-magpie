#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders the shipped DeepSeek Touch Bar item next to three typography-only designs.

The Codex half is the shipped QuotaView.draw(_:) compiled from main.swift (only the three
launch lines and the bundle icon lookup are patched in a temp copy), so the comparison keeps
the real Font/colour rhythm. The DeepSeek half comes from Tests/designs/TBDesignA.swift,
which is design-only and never shipped.

Beyond the PNGs this script *audits* every text run of every variant with real AppKit
metrics (NSString advance width + CTLine ink bounds): each run must sit inside 4..292,
stay inside the 30pt bar, keep clear of the logo, and no two runs may overlap (that is the
"两行压字" check). Rules must not cross text either. The audit JSON is produced by the same
Swift layout code that draws the pixels, so the numbers cannot drift from the render.

Output (2x): design-a-<n>-<slug>.png per row, design-a-sheet.png, design-a-sheet-annotated.png,
design-a-transparent.png (alpha proof: the module draws no background at all).

三档校验，都用同一份 Swift 布局结果：
  python3 Tests/render-tb-design-a.py                        # 真实数据（¥50.95 / 3.57M / 78.6%）
  QS_STRESS=1 QS_OUT=/tmp/qs-stress python3 Tests/render-tb-design-a.py   # 压力数据（¥1234.56 / 123.46M / 99.9%）
  QS_STALE=1  QS_OUT=/tmp/qs-stale  python3 Tests/render-tb-design-a.py   # 过期态（同色系降透明度）
压力档只放宽「主角 ≥15pt」这一条造型要求，其余（越界、重叠、压字、细线压字）一条都不放宽。

Synthetic values only: no network, no Keychain, nothing outside a temp dir.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent

EXTRA_SOURCES = ("TouchBarPairView.swift", "UsagePanel.swift", "CodexUsageProvider.swift",
                 "DSHBalanceProvider.swift", "DeepSeekPricing.swift", "DeepSeekHolidays.swift",
                 "DeepSeekHarness.swift", "DeepSeekBalanceProvider.swift", "DeepSeekBalanceView.swift",
                 "CodexAppServerQuotaProvider.swift")


def find_root() -> pathlib.Path:
    """定位 QuotaStrip 源码根目录：本脚本在项目内直接跑，复制到别处时退回项目路径。"""
    candidates = [pathlib.Path(os.environ["QS_ROOT"])] if os.environ.get("QS_ROOT") else []
    candidates += [pathlib.Path(__file__).resolve().parent.parent, PROJECT_ROOT]
    for candidate in candidates:
        sources = candidate / "Sources"
        needed = [sources / "main.swift", sources / "DeepSeekTouchBarView.swift"]
        needed += [sources / name for name in EXTRA_SOURCES]
        if all(path.exists() for path in needed) and (candidate / "Resources" / "deepseek-logo.png").exists():
            return candidate
    raise SystemExit("找不到 QuotaStrip 源码根目录，请用 QS_ROOT=<path> 指定")


ROOT = find_root()
SOURCES = ROOT / "Sources"
DESIGNS = ROOT / "Tests" / "designs"
KEEPS = pathlib.Path(os.environ.get("QS_OUT", "/tmp/quotastrip-renders"))

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

/// 与现役视图评审时用的同一组真实数据：余额 ¥50.95、账户累计 ¥71.11（所以已花 ¥20.16）、
/// 今日 3,570,277 token、缓存命中 78.6%。
var fixture: DeepSeekSnapshot {
    var value = DeepSeekSnapshot()
    value.balance = Decimal(string: "50.95", locale: Locale(identifier: "en_US_POSIX"))
    value.startingBalance = Decimal(string: "71.11", locale: Locale(identifier: "en_US_POSIX"))
    value.todayTokens = 3_570_277
    value.todayCacheHitPercent = 78.6
    // 压力测试（QS_STRESS=1）：金额变长、用量涨到三位数 M，检查排版是否还站得住。
    if ProcessInfo.processInfo.environment["QS_STRESS"] == "1" {
        value.balance = Decimal(string: "1234.56", locale: Locale(identifier: "en_US_POSIX"))
        value.startingBalance = Decimal(string: "5000.00", locale: Locale(identifier: "en_US_POSIX"))
        value.todayTokens = 123_456_789
        value.todayCacheHitPercent = 99.9
    }
    value.currency = "CNY"
    value.stale = ProcessInfo.processInfo.environment["QS_STALE"] == "1"
    return value
}

func shippedView() -> DeepSeekTouchBarView {
    let view = DeepSeekTouchBarView()
    view.phase = .offPeak
    view.update(fixture)
    return view
}

func tbView(_ style: TBAStyle) -> TBDesignAView {
    let view = TBDesignAView()
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

/// 透明底自证：合并 item 上模块必须完全没有底（没有卡片/渐变/阴影）。
/// 这里不铺黑底，只画视图，再回读三个必然属于背景的点，alpha 必须是 0。
func transparentRep(_ view: NSView) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 60,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 300, height: 30)
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
    guard let piece = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: piece)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 300, height: 30))
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(piece)
    image.draw(in: NSRect(x: 0, y: 0, width: 300, height: 30), from: .zero,
               operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    // 直接读位图字节：背景点整像素必须全 0（clear 之后没人再往上画东西）。
    let bytes = rep.bitmapData!
    let stride = rep.bytesPerRow
    for (px, py) in [(150.0, 2.0), (31.0, 15.0), (290.0, 28.0)] {
        let index = Int(py * 2) * stride + Int(px * 2) * 4
        let alpha = bytes[index + 3]
        print(String(format: "ALPHACHECK %.0f,%.0f %.2f", px, py, Double(alpha) / 255.0))
    }
    return rep
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

var rows: [(String, String, NSBitmapImageRep)] = [("design-a-0-shipped", "0 现役", row(shippedView()))]
for style in TBAStyle.allCases {
    rows.append(("design-a-" + String(style.rawValue + 1) + "-" + style.slug,
                 String(style.rawValue + 1) + " " + style.title, row(tbView(style))))
}

for (name, _, rep) in rows {
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
    print(name, rep.pixelsWide, "x", rep.pixelsHigh)
}

/// 拼成对照表：每行 30pt，中间 1pt 纯黑分隔，用 flipped 容器按从上到下摆。
final class SheetView: NSView {
    var images: [NSImage] = []
    var labels: [String] = []
    var gutter: CGFloat = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        for (index, image) in images.enumerated() {
            let y = CGFloat(index) * 31
            image.draw(in: NSRect(x: gutter, y: y, width: 603, height: 30),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            guard gutter > 0, index < labels.count else { continue }
            let label = labels[index] as NSString
            label.draw(at: NSPoint(x: 10, y: y + 9), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(white: 0.82, alpha: 1),
            ])
        }
    }
}

func sheet(gutter: CGFloat) -> SheetView {
    let view = SheetView(frame: NSRect(x: 0, y: 0, width: 603 + gutter, height: CGFloat(rows.count) * 31 - 1))
    view.images = rows.map { entry in
        let image = NSImage(size: NSSize(width: 603, height: 30))
        image.addRepresentation(entry.2)
        return image
    }
    view.labels = rows.map { $0.1 }
    view.gutter = gutter
    return view
}

for (name, gutter) in [("design-a-sheet", CGFloat(0)), ("design-a-sheet-annotated", CGFloat(104))] {
    let view = sheet(gutter: gutter)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(4) }
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
    print(name, rep.pixelsWide, "x", rep.pixelsHigh)
}

// MARK: - 几何自查数据（与绘制共用同一份 layout）

func inkRect(_ run: TBARun) -> [String: Any] {
    let metrics = TBDesignAView.metrics(run.text, size: run.size, weight: run.weight, kern: run.kern)
    return [
        "id": run.id,
        "text": run.text,
        "x": Double(run.x),
        "right": Double(run.x + metrics.advance),
        "width": Double(metrics.advance),
        "baseline": Double(run.baseline),
        "size": Double(run.size),
        "inkTop": Double(run.baseline + metrics.inkTop),
        "inkBottom": Double(run.baseline + metrics.inkBottom),
    ]
}

var styles: [[String: Any]] = []
for style in TBAStyle.allCases {
    let view = tbView(style)
    styles.append([
        "style": style.slug,
        "title": style.title,
        "runs": view.runs(for: fixture).map(inkRect),
        "rules": view.rules(for: fixture).map { entry in
            ["id": entry.id,
             "x": Double(entry.rect.minX),
             "right": Double(entry.rect.maxX),
             "y": Double(entry.rect.minY),
             "bottom": Double(entry.rect.maxY)] as [String: Any]
        },
    ])
}

let audit: [String: Any] = [
    "viewWidth": 300.0,
    "viewHeight": 30.0,
    "textZone": [4.0, 292.0],
    "logo": ["x": 4.0, "right": 30.0, "y": 2.0, "bottom": 28.0],
    "styles": styles,
]
try! transparentRep(tbView(.strip)).representation(using: .png, properties: [:])!
    .write(to: folder.appendingPathComponent("design-a-transparent.png"))

let data = try! JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: folder.appendingPathComponent("design-a-audit.json"))
print("design-a-audit.json", data.count, "bytes")
'''


ALPHA_LINES: list[str] = []


def build_and_run(work: pathlib.Path) -> int:
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

    (work / "QuotaStripBody.swift").write_text(body, encoding="utf-8")
    (work / "DeepSeekTouchBarView.swift").write_text(deepseek, encoding="utf-8")
    (work / "TBDesignA.swift").write_text(
        (DESIGNS / "TBDesignA.swift").read_text(encoding="utf-8"), encoding="utf-8")
    (work / "main.swift").write_text(MAIN, encoding="utf-8")
    # 快照到临时目录再编译：Sources/ 可能被别的会话同时改动，直接编译会报
    # "input file was modified during the build"。
    extras = []
    for name in EXTRA_SOURCES:
        shutil.copy2(SOURCES / name, work / name)
        extras.append(work / name)
    files = [work / "QuotaStripBody.swift", work / "DeepSeekTouchBarView.swift",
             work / "TBDesignA.swift"] + extras
    binary = work / "design-a-render"
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
                              "QS_STALE": os.environ.get("QS_STALE", "0"),
                              "QS_STRESS": os.environ.get("QS_STRESS", "0"),
                              "PATH": "/usr/bin:/bin"},
                         capture_output=True, text=True, timeout=180)
    sys.stdout.write(run.stdout)
    sys.stderr.write(run.stderr)
    ALPHA_LINES.extend(line for line in run.stdout.splitlines() if line.startswith("ALPHACHECK"))
    if run.returncode != 0:
        return run.returncode
    KEEPS.mkdir(exist_ok=True)
    for png in output.iterdir():
        (KEEPS / png.name).write_bytes(png.read_bytes())
    print("wrote", KEEPS)
    return 0


# MARK: - 自查

EPS = 0.01
MIN_GAP = 0.5


def audit(audit_path: pathlib.Path, min_hero: float = 15.0) -> int:
    payload = json.loads(audit_path.read_text())
    left, right = payload["textZone"]
    logo = payload["logo"]
    height = payload["viewHeight"]
    problems = []
    print("\n==== 几何自查（真实 NSString/CTLine 度量）====")
    for style in payload["styles"]:
        runs = sorted(style["runs"], key=lambda r: r["x"])
        print(f"\n[{style['style']}] {style['title']}  ({len(runs)} 段文字, {len(style['rules'])} 条细线)")
        print(f"  {'id':<14}{'text':<16}{'x':>7}{'w':>7}{'right':>8}{'base':>7}{'ink':>12}")
        for run in runs:
            print(f"  {run['id']:<14}{run['text']:<16}{run['x']:7.2f}{run['width']:7.2f}"
                  f"{run['right']:8.2f}{run['baseline']:7.2f}"
                  f"{run['inkTop']:6.2f}..{run['inkBottom']:.2f}")
        if not runs:
            problems.append(f"[{style['style']}] 没有文字")
        ids = [run["id"] for run in runs]
        if len(ids) != len(set(ids)):
            problems.append(f"[{style['style']}] run id 重复: {ids}")

        for run in runs:
            if not run["text"]:
                problems.append(f"[{style['style']}] {run['id']} 文本为空")
            if run["x"] < left - EPS:
                problems.append(f"[{style['style']}] {run['id']} 左越界 x={run['x']:.2f} < {left}")
            if run["right"] > right + EPS:
                problems.append(f"[{style['style']}] {run['id']} 右越界 right={run['right']:.2f} > {right}")
            if run["inkTop"] < 0 - EPS:
                problems.append(f"[{style['style']}] {run['id']} 上越界 inkTop={run['inkTop']:.2f} < 0")
            if run["inkBottom"] > height + EPS:
                problems.append(f"[{style['style']}] {run['id']} 下越界 inkBottom={run['inkBottom']:.2f} > {height}")
            if run["x"] < logo["right"] and run["right"] > logo["x"] \
                    and run["inkTop"] < logo["bottom"] and run["inkBottom"] > logo["y"]:
                problems.append(f"[{style['style']}] {run['id']} 压到图标")

        for index, first in enumerate(runs):
            for second in runs[index + 1:]:
                horizontal = min(first["right"], second["right"]) - max(first["x"], second["x"])
                vertical = min(first["inkBottom"], second["inkBottom"]) - max(first["inkTop"], second["inkTop"])
                if horizontal > EPS and vertical > EPS:
                    problems.append(f"[{style['style']}] 文字重叠: {first['id']} × {second['id']}"
                                    f" (横向 {horizontal:.2f}pt, 纵向 {vertical:.2f}pt)")
        # 同一行里相邻文字的净间距（只查 advance 宽度，不看墨迹）
        baselines = {}
        for run in runs:
            baselines.setdefault(round(run["baseline"], 2), []).append(run)
        for baseline, line in baselines.items():
            line.sort(key=lambda r: r["x"])
            for index in range(len(line) - 1):
                gap = line[index + 1]["x"] - line[index]["right"]
                if gap < MIN_GAP - EPS:
                    problems.append(f"[{style['style']}] 基线 {baseline} 上 {line[index]['id']} → "
                                    f"{line[index + 1]['id']} 间距只有 {gap:.2f}pt")
        # 细线：不越界、不压字
        for entry in style["rules"]:
            if entry["x"] < left - EPS or entry["right"] > right + EPS:
                problems.append(f"[{style['style']}] {entry['id']} 横向越界")
            if entry["y"] < 0 or entry["bottom"] > height:
                problems.append(f"[{style['style']}] {entry['id']} 纵向越界")
            for run in runs:
                horizontal = min(entry["right"], run["right"]) - max(entry["x"], run["x"])
                vertical = min(entry["bottom"], run["inkBottom"]) - max(entry["y"], run["inkTop"])
                if horizontal > EPS and vertical > EPS:
                    problems.append(f"[{style['style']}] {entry['id']} 压到文字 {run['id']}")
        # 层级：声明的主角必须处在最大字号档（允许货币符号同档并列），且必须够大
        hero_by_id = {run["id"]: run for run in runs}
        hero = {"strip": "heroValue", "ledger": "balanceValue", "today": "todayValue"}[style["style"]]
        biggest = max(runs, key=lambda r: r["size"])
        hero_run = hero_by_id.get(hero)
        if hero_run is None:
            problems.append(f"[{style['style']}] 找不到声明的主角 {hero}")
        else:
            if hero_run["size"] < biggest["size"]:
                problems.append(
                    f"[{style['style']}] 主角 {hero} 只有 {hero_run['size']}pt，被 {biggest['id']} "
                    f"的 {biggest['size']}pt 压过，层级不成立")
            if hero_run["size"] < min_hero:
                problems.append(f"[{style['style']}] 主角 {hero} 只有 {hero_run['size']}pt，"
                                f"撑不起 30pt 高的模块（门槛 {min_hero}pt）")
        sizes = sorted({run["size"] for run in runs}, reverse=True)
        hero_size = f"{hero_run['size']}pt" if hero_run else "?"
        print(f"  字号阶梯: {sizes}  主角: {hero} ({hero_size})"
              + (f" / 同档 {biggest['id']}" if biggest["id"] != hero else ""))

    print()
    if problems:
        print(f"AUDIT FAIL: {len(problems)} 个问题")
        for problem in problems:
            print("  -", problem)
        return 1
    print("AUDIT PASS: 所有文字块都在 4..292 内，无重叠、无压字，细线不压文字")
    return 0


def verify_pngs() -> int:
    problems = []
    expected = {
        "design-a-0-shipped.png": (1206, 60),
        "design-a-1-strip.png": (1206, 60),
        "design-a-2-ledger.png": (1206, 60),
        "design-a-3-today.png": (1206, 60),
        "design-a-sheet.png": (1206, 246),
        "design-a-sheet-annotated.png": (1414, 246),
        "design-a-transparent.png": (600, 60),
    }
    for name, size in expected.items():
        path = KEEPS / name
        if not path.exists():
            problems.append(f"缺少 {name}")
            continue
        header = path.read_bytes()[:24]
        width = int.from_bytes(header[16:20], "big")
        height = int.from_bytes(header[20:24], "big")
        if (width, height) != size:
            problems.append(f"{name} 尺寸 {width}x{height}，应为 {size[0]}x{size[1]}")
    # 透明底：三个背景点的 alpha 必须都是 0（视图本身不画底）
    if len(ALPHA_LINES) != 3:
        problems.append(f"透明底自证少了，只拿到 {len(ALPHA_LINES)} 个采样点")
    for line in ALPHA_LINES:
        if not line.endswith("0.00"):
            problems.append(f"透明底自证失败: {line}（该点不是全透明，说明视图铺了底色）")
    if problems:
        print("\nPNG FAIL")
        for problem in problems:
            print("  -", problem)
        return 1
    # 同时给出任务书里约定的 design-a-0..3.png 简名，两套命名指向同一批像素
    for index, source in enumerate(["design-a-0-shipped.png", "design-a-1-strip.png",
                                    "design-a-2-ledger.png", "design-a-3-today.png"]):
        shutil.copyfile(KEEPS / source, KEEPS / f"design-a-{index}.png")
    print("PNG PASS: 4 行 1206×60 + 两张对照表（另存 design-a-0..3.png 简名）")
    return 0


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="quotastrip-design-a-") as folder:
        work = pathlib.Path(folder)
        if build_and_run(work) != 0:
            return 1
    audit_path = KEEPS / "design-a-audit.json"
    if not audit_path.exists():
        print("FAIL: no audit json")
        return 1
    if verify_pngs() != 0:
        return 1
    # 压力档（QS_STRESS）只要求「不被别的字号压过、不撞字」；真实数据档要求主角 ≥15pt。
    stress = os.environ.get("QS_STRESS") == "1"
    if audit(audit_path, min_hero=13.0 if stress else 15.0) != 0:
        return 1
    print("\nPASS: design A renders + geometry audit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
