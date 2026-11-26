#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders the menu-bar panel with real SwiftUI/AppKit in both appearances.

Synthetic snapshot only: no network, no Keychain, no user data. Output goes to
/tmp/quotastrip-renders/panel-dark.png and panel-light.png at 2x.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

MAIN = r'''
import AppKit
import SwiftUI

func L(_ en: String, _ zh: String) -> String { zh }

let model = UsagePanelModel()
var snapshot = UsageSnapshot()
let now = Date()
snapshot.codexRows = [
    UsageQuotaRow(label: "5h", remainingPercent: 82, resetText: "54m",
                  resetAt: now.addingTimeInterval(0.82 * 18000), windowSeconds: 18000),
    UsageQuotaRow(label: "7d", remainingPercent: 42, resetText: "4d16h",
                  resetAt: now.addingTimeInterval(0.42 * 604800), windowSeconds: 604800),
]
snapshot.todayOutputTokens = 1_801
snapshot.cacheHitPercent = 75.7
snapshot.creditsText = "1336.81"
snapshot.creditsNote = "最近记录 11-13 23:48"
snapshot.codexRecentDayLabels = ["2026-11-10", "2026-11-11", "2026-11-12",
                                "2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16"]
snapshot.codexRecentDayTokens = [1_204_000, 2_870_000, 1_640_000, 3_105_000,
                                 980_000, 0, 2_240_000]
snapshot.balanceText = "CNY 9.79"
snapshot.balancePercent = 46
snapshot.deepSeekSpentText = "¥20.49"
snapshot.recentDayLabels = ["2026-11-10", "2026-11-11", "2026-11-12",
                            "2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16"]
snapshot.recentDayTokens = [0, 0, 8_969_898, 106_515_375, 103_088_154,
                            6_774_405, 31_821_456]
snapshot.deepSeekTodayTokens = 31_821_456
snapshot.deepSeekCacheHitPercent = 98.2
snapshot.updatedAt = Date()

// 千问 Token Plan 夹具：正常态（刚观测、月度窗口、12-16 重置）。
var planResetComponents = DateComponents()
planResetComponents.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
planResetComponents.year = 2026
planResetComponents.month = 12
planResetComponents.day = 16
let planReset = Calendar(identifier: .gregorian).date(from: planResetComponents)!
let qwenWindow = QwenPlanWindow(key: "monthly", label: "月度 Credits", limit: 80000,
                                usedPercent: 6.36167092, resetAt: planReset, unit: "Credits")
let qwenPlanLive = QwenPlan(plan: "Standard", status: "partial", source: "千问官方 CLI",
                            note: "", observedAt: now, maxAge: 5400, windows: [qwenWindow])

let sessionUsage = DSHSessionUsage(
    sessionId: "session-8428a5de",
    title: "融合 Glance 面板与当前对话用量",
    providerId: "deepseek-account",
    providerFamily: "deepseek",
    model: "deepseek-flash",
    inputTokens: 1_200_000,
    outputTokens: 320_000,
    cacheReadTokens: 8_400_000,
    cacheWriteTokens: 0,
    totalTokens: 9_920_000,
    estimatedCost: Decimal(string: "0.31"),
    currency: "CNY",
    pricingSource: "deepseek-official",
    lastAt: Date(),
    models: ["deepseek-account/deepseek-flash"]
)
let mixedUsage = DSHSessionUsage(
    sessionId: "session-5f1c9d20",
    title: "混用模型的对话",
    providerId: "v-api",
    providerFamily: "v-api",
    model: "claude-sonnet-5-5",
    inputTokens: 210_000,
    outputTokens: 64_000,
    cacheReadTokens: 0,
    cacheWriteTokens: 12_000,
    totalTokens: 286_000,
    estimatedCost: nil,
    currency: nil,
    pricingSource: nil,
    lastAt: nil,
    models: ["v-api/claude-sonnet-5-5", "deepseek-account/deepseek-flash"]
)
let choices = [
    DSHSessionChoice(sessionId: "session-8428a5de", title: "融合 Glance 面板与当前对话用量",
                     models: ["deepseek-account/deepseek-flash"], lastAt: Date()),
    DSHSessionChoice(sessionId: "session-5f1c9d20", title: "混用模型的对话",
                     models: ["v-api/claude-sonnet-5-5"], lastAt: Date().addingTimeInterval(-600)),
]

/// 四套状态各渲染一遍：正常、多会话未选择、混用且无完整计价、未连接。
func snapshotFor(_ state: String) -> UsageSnapshot {
    var copy = snapshot
    copy.codexModelRows = [UsageModelRow(name: "openai/gpt-6.1-sol", tokens: 1_416_000),
                           UsageModelRow(name: "openai/gpt-5.5", tokens: 154_000)]
    copy.deepSeekMonthTokens = 334_523_742
    copy.deepSeekTotalHeldText = "CNY 71.11"
    copy.deepSeekModelRows = [UsageModelRow(name: "deepseek-flash", tokens: 30_520_000),
                              UsageModelRow(name: "deepseek-v4-flash", tokens: 1_300_000)]
    copy.todayAllTokens = 101_310_020
    copy.qianfanModelRows = [UsageModelRow(name: "qianfan-code-latest", tokens: 37_625_909)]
    copy.qianfanTodayTokens = 37_625_909
    copy.usageSessions = [
        UsageSessionRow(id: "8428a5de-53b1-4ef7-9d34-92641a4174ab",
                        title: "按你给的那张 Glance 图重做了面板 这次是逐项照它的度量实现…",
                        tokens: 316_582_000, models: ["baidu-pzt/qianfan-code-latest",
                                                      "deepseek-account/deepseek-flash"],
                        lastAt: Date()),
        UsageSessionRow(id: "300d40cf-1c22-4f80-9b71-5e2fa1c9a4de",
                        title: "额度条怎么是98 是不是获取不到我账号上充值的金额",
                        tokens: 88_120_000, models: ["deepseek-account/deepseek-flash"],
                        lastAt: Date().addingTimeInterval(-86_400)),
        UsageSessionRow(id: "e4bdf82e-2d31-4c19-b0ab-0e19c2a51f77",
                        title: "把面板做成 Glance 那种双列宽卡",
                        tokens: 12_540_000, models: ["openai/gpt-6.1-sol"],
                        lastAt: Date().addingTimeInterval(-39_600)),
        UsageSessionRow(id: "7afbbe21-91d2-4b8c-8a10-3f2d1e6c0b55",
                        title: "插件安装后看不到入口",
                        tokens: 6_240_000, models: ["deepseek-account/deepseek-flash"],
                        lastAt: Date().addingTimeInterval(-82_800)),
        // 单模型非 deepseek/openai：验证 ai 品牌行也有可辨识图标（sparkles），不是空方块。
        UsageSessionRow(id: "c0de0001-0000-0000-0000-000000000001",
                        title: "qwen 单模型会话",
                        tokens: 3_660_000, models: ["qwen/qwen4-max-preview"],
                        lastAt: Date().addingTimeInterval(-300)),
    ]
    copy.followSession = true
    copy.sessionChoices = choices
    copy.qwenPlan = qwenPlanLive
    switch state {
    case "live": copy.sessionStatus = .live(sessionUsage)
    case "mixed": copy.sessionStatus = .live(mixedUsage)
    case "pick": copy.sessionStatus = .needsSelection(choices)
    case "down": copy.sessionStatus = .unavailable("未连接：本机用量统计没有响应")
    case "plan-stale":
        copy.sessionStatus = .live(sessionUsage)
        copy.qwenPlan = QwenPlan(plan: "Standard", status: "partial", source: "千问官方 CLI",
                                 note: "", observedAt: now.addingTimeInterval(-7200),
                                 maxAge: 5400, windows: [qwenWindow])
        copy.qwenPlanStale = true
    case "plan-nil":
        copy.sessionStatus = .live(sessionUsage)
        copy.qwenPlan = nil
    case "off":
        copy.followSession = false
        copy.sessionStatus = .off
    default: copy.sessionStatus = .off
    }
    return copy
}

model.snapshot = snapshotFor("live")
model.icon = { name in
    let folder = ProcessInfo.processInfo.environment["QS_RES"] ?? ""
    return NSImage(contentsOfFile: folder + "/" + name + ".png")
}

func render(_ appearance: NSAppearance.Name, _ file: String, folder: URL) {
    let root = UsagePanelView(model: model)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    window.orderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    hosting.frame = NSRect(x: 0, y: 0, width: max(560, size.width), height: size.height)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    guard let rendered = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(2) }
    hosting.cacheDisplay(in: hosting.bounds, to: rendered)
    // SwiftUI 视图本身是透明的：铺上该外观下的窗口底色，才能看到真实观感。
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rendered.pixelsWide,
                               pixelsHigh: rendered.pixelsHigh, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = hosting.bounds.size
    NSGraphicsContext.saveGraphicsState()
    if let appearance = NSAppearance(named: appearance) {
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            hosting.bounds.fill()
            let image = NSImage(size: hosting.bounds.size)
            image.addRepresentation(rendered)
            image.draw(in: hosting.bounds, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    try! png.write(to: folder.appendingPathComponent(file))
    print(file, rep.pixelsWide, "x", rep.pixelsHigh, "fitting", size)
    window.orderOut(nil)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for appearance in [NSAppearance.Name.darkAqua, .aqua] {
    let suffix = appearance == .darkAqua ? "dark" : "light"
    for state in ["live", "mixed", "pick", "down", "off", "plan-stale", "plan-nil"] {
        model.snapshot = snapshotFor(state)
        render(appearance, "panel-session-" + state + "-" + suffix + ".png", folder: folder)
    }
    model.snapshot = snapshotFor("live")
    render(appearance, "panel-" + suffix + ".png", folder: folder)
}
print("PASS: panel renders (7 session states x 2 appearances)")
'''


def main() -> int:
    panel = (SOURCES / "UsagePanel.swift").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="quotastrip-panel-") as folder:
        work = pathlib.Path(folder)
        (work / "UsagePanel.swift").write_text(panel, encoding="utf-8")
        for extra in ("DSHSessionProvider.swift", "DSHBalanceProvider.swift", "JimmyCloudPlanProvider.swift"):
            (work / extra).write_text((SOURCES / extra).read_text(encoding="utf-8"), encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        binary = work / "panel"
        result = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0",
             str(work / "UsagePanel.swift"), str(work / "DSHSessionProvider.swift"),
             str(work / "DSHBalanceProvider.swift"), str(work / "JimmyCloudPlanProvider.swift"),
             str(work / "main.swift"), "-o", str(binary),
             "-framework", "AppKit", "-framework", "SwiftUI"],
            capture_output=True, text=True, timeout=300)
        if result.returncode != 0:
            sys.stderr.write(result.stdout + result.stderr)
            return 1
        output = work / "out"
        output.mkdir()
        run = subprocess.run([str(binary), str(output)],
                             env={"QS_RES": str(ROOT / "Resources"), "PATH": "/usr/bin:/bin"},
                             capture_output=True, text=True, timeout=180)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if run.returncode != 0:
            return run.returncode
        keeps = pathlib.Path("/tmp/quotastrip-renders")
        keeps.mkdir(exist_ok=True)
        for png in output.glob("panel*.png"):
            (keeps / png.name).write_bytes(png.read_bytes())
        print("wrote", keeps)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
