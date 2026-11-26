#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders the shipped DeepSeekTouchBarView offscreen so the 300x30 layout can be
inspected without a physical Touch Bar. Uses the real source files; only the bundle
logo lookups are given real paths and the pricing phase is made settable, and nothing
is written outside a temp dir. Synthetic data only: no network, no Keychain, no
user records read.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources" / "DeepSeekTouchBarView.swift",
    ROOT / "Sources" / "DSHBalanceProvider.swift",
    ROOT / "Sources" / "DeepSeekPricing.swift",
    ROOT / "Sources" / "DeepSeekHolidays.swift",
]

MAIN = r'''
import AppKit

func snapshot(_ balance: String?, start: String?, tokens: Int64?, cache: Double?, stale: Bool,
              month: Int64? = 257_200_000,
              currentModel: String? = nil, currentModelTokens: Int64? = nil) -> DeepSeekSnapshot {
    var value = DeepSeekSnapshot()
    value.balance = balance.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    value.startingBalance = start.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    value.todayTokens = tokens
    value.todayCacheHitPercent = cache
    value.monthTokens = month
    value.stale = stale
    value.currentModel = currentModel
    value.currentModelTokens = currentModelTokens
    return value
}
let cases: [(String, DeepSeekPhaseCase)] = [
    ("offpeak-50", DeepSeekPhaseCase(.offPeak, snapshot("10.00", start: "20", tokens: 68_200, cache: 95.5, stale: false))),
    ("peak-50", DeepSeekPhaseCase(.peak, snapshot("10.00", start: "20", tokens: 68_200, cache: 95.5, stale: false))),
    ("unknown", DeepSeekPhaseCase(.unknown, snapshot("10.00", start: nil, tokens: nil, cache: nil, stale: false, month: nil))),
    ("waiting", DeepSeekPhaseCase(.offPeak, snapshot("25.00", start: "20", tokens: 1_200_000, cache: 0, stale: false))),
    ("stale", DeepSeekPhaseCase(.peak, snapshot("3.20", start: "20", tokens: 42_653_097, cache: 99.0, stale: true))),
    ("large", DeepSeekPhaseCase(.offPeak, snapshot("1234567.89", start: "2000000", tokens: 999_999_999, cache: 100, stale: false))),
    // Real account data: balance + official cumulative spend = 21.11 CNY held, 9.79 left.
    ("account-46", DeepSeekPhaseCase(.offPeak, snapshot("9.78647576", start: "21.11007616", tokens: 66_373_267, cache: 97.7, stale: false))),
    // Spec sample: 9.50 of 21.11 = 45%, 68.39M tokens.
    ("spec-45", DeepSeekPhaseCase(.offPeak, snapshot("9.50", start: "21.11", tokens: 68_390_000, cache: 97.7, stale: false))),
    ("money-1000", DeepSeekPhaseCase(.offPeak, snapshot("1000.00", start: "2000", tokens: 68_390_000, cache: 97.7, stale: false))),
    ("token-999m", DeepSeekPhaseCase(.offPeak, snapshot("9.50", start: "21.11", tokens: 999_990_000, cache: 97.7, stale: false))),
    ("token-1b", DeepSeekPhaseCase(.offPeak, snapshot("9.50", start: "21.11", tokens: 1_000_000_000, cache: 97.7, stale: false))),
    // Current-model follow: second row shows the active model's today tokens + short tag.
    ("model-qwen", DeepSeekPhaseCase(.offPeak, snapshot("16.92", start: "71.11", tokens: 10_660_000, cache: 95.2, stale: false,
        currentModel: "qwen/qwen4-max-preview", currentModelTokens: 8_770_000))),
    ("model-glm", DeepSeekPhaseCase(.offPeak, snapshot("16.92", start: "71.11", tokens: 10_660_000, cache: 95.2, stale: false,
        currentModel: "qwen/glm-5.3", currentModelTokens: 1_140_000))),
    ("model-long", DeepSeekPhaseCase(.offPeak, snapshot("16.92", start: "71.11", tokens: 10_660_000, cache: 95.2, stale: false,
        currentModel: "qwen/deepseek-v4.1-flash-1017", currentModelTokens: 750_000))),
]
struct DeepSeekPhaseCase { let phase: DeepSeekPricePhase; let value: DeepSeekSnapshot
    init(_ phase: DeepSeekPricePhase, _ value: DeepSeekSnapshot) { self.phase = phase; self.value = value } }
// Two items side by side with the real 8pt gap measured from the live Touch Bar
// (NSTouchBarItemContainerView x=0 and x=308): nothing draws a divider, the seam is
// simply the Touch Bar's black background showing between the transparent views.
func pairImage(_ item: DeepSeekPhaseCase) -> NSBitmapImageRep {
    let logical = NSSize(width: 608, height: 30)
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(logical.width * scale),
                               pixelsHigh: Int(logical.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = logical
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.black.setFill()
    NSRect(origin: .zero, size: logical).fill()
    for offset in [0.0, 308.0] {
        let view = DeepSeekTouchBarView()
        view.phase = item.phase
        view.update(item.value)
        guard let viewRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: viewRep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(viewRep)
        image.draw(in: NSRect(x: offset, y: 0, width: 300, height: 30), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, item) in cases {
    let view = DeepSeekTouchBarView()
    view.phase = item.phase
    view.update(item.value)
    guard let rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: rendered)
    // 视图本身是透明的，预览时铺一层 Touch Bar 黑底，才能看出实际观感。
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rendered.pixelsWide,
                               pixelsHigh: rendered.pixelsHigh, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    view.bounds.fill()
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(rendered)
    image.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    try! png.write(to: folder.appendingPathComponent(name + ".png"))
    print(name, "round:", view.round(), "phase:", view.phase, "size:", rep.pixelsWide, "x", rep.pixelsHigh)
}

let pair = pairImage(DeepSeekPhaseCase(.offPeak, snapshot("9.50", start: "21.11", tokens: 68_390_000, cache: 97.7, stale: false)))
try! pair.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("pair.png"))
print("pair size:", pair.pixelsWide, "x", pair.pixelsHigh)
'''


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="quotastrip-render-") as folder:
        path = pathlib.Path(folder) / "main.swift"
        path.write_text(MAIN, encoding="utf-8")
        offpeak = ROOT / "Resources" / "deepseek-logo.png"
        peak = ROOT / "Resources" / "deepseek-logo-peak.png"
        patch = pathlib.Path(folder) / "patched"
        patch.mkdir()
        for source in SOURCES:
            text = source.read_text(encoding="utf-8")
            if source.name == "DeepSeekTouchBarView.swift":
                text = text.replace(
                    'let offPeakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) }',
                    'let offPeakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")')
                assert "QS_LOGO" in text, "off-peak logo substitution failed"
                text = text.replace(
                    'private lazy var peakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo-peak", ofType: "png")\n        .flatMap { NSImage(contentsOfFile: $0) } ?? Self.loadDSHDockIcon()',
                    'private lazy var peakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")')
                assert "QS_PEAK_LOGO" in text, "peak logo substitution failed"
                text = text.replace("private(set) var snapshot: DeepSeekSnapshot?",
                                    "var snapshot: DeepSeekSnapshot?")
                text = text.replace("private(set) var phase: DeepSeekPricePhase",
                                    "var phase: DeepSeekPricePhase")
            (patch / source.name).write_text(text, encoding="utf-8")
        binary = pathlib.Path(folder) / "render"
        compile_result = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5"] + [str(patch / s.name) for s in SOURCES] + [str(path), "-o", str(binary)],
            capture_output=True, text=True, timeout=240)
        if compile_result.returncode != 0:
            sys.stderr.write(compile_result.stderr)
            return 1
        output = pathlib.Path(folder) / "out"
        output.mkdir()
        run = subprocess.run([str(binary), str(output)],
                             env={"QS_LOGO": str(offpeak), "QS_PEAK_LOGO": str(peak), "PATH": "/usr/bin:/bin"},
                             capture_output=True, text=True, timeout=60)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if run.returncode != 0:
            return run.returncode
        keeps = pathlib.Path("/tmp/quotastrip-renders")
        keeps.mkdir(exist_ok=True)
        for name in ("offpeak-50", "peak-50", "unknown", "waiting", "stale", "large", "account-46", "spec-45", "money-1000", "token-999m", "token-1b", "model-qwen", "model-glm", "model-long", "pair"):
            (keeps / f"{name}.png").write_bytes((output / f"{name}.png").read_bytes())
        print("wrote", keeps)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
