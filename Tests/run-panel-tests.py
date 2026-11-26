#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Checks the menu-bar panel's shared data layer, formatter and wiring.

Real AppKit/SwiftUI code is compiled for the formatting assertions; the wiring
assertions read the shipping sources. No window is shown, no data is fetched.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

HARNESS = r'''
import AppKit
import SwiftUI

func L(_ en: String, _ zh: String) -> String { zh }

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition { print("ok:", label) } else { print("FAIL:", label); failures += 1 }
}

let f = UsageFormat.self
expect(f.tokens(nil) == "—", "nil tokens show a dash")
expect(f.tokens(0) == "0", "zero tokens stay plain")
expect(f.tokens(999) == "999", "sub-thousand stays plain")
expect(f.tokens(1_000) == "1.0K", "1000 → 1.0K")
expect(f.tokens(1_801) == "1.8K", "today output 1,801 → 1.8K")
expect(f.tokens(94_883_648) == "94.88M", "94,883,648 → 94.88M")
expect(f.tokens(999_994) == "1.00M", "999,994 promotes to 1.00M instead of 1000.0K")
expect(f.tokens(999_995) == "1.00M", "999,995 → 1.00M")
expect(f.tokens(999_999_999) == "1.00B", "999,999,999 → 1.00B")
expect(f.tokens(-5) == "—", "negative tokens are refused")

expect(f.percent(98.155) == "98.2%", "cache hit rounds to one decimal")
expect(f.percent(nil) == "—", "missing cache hit shows a dash")
expect(f.percent(150) == "100.0%", "percent is clamped above")
expect(f.percent(-5) == "0.0%", "percent is clamped below")
expect(f.remaining(46) == "46%", "remaining percent")
expect(f.remaining(nil) == "—", "missing remaining shows a dash")

expect(f.clock(nil) == "", "no reset time → empty")
expect(f.clock(Date(timeIntervalSinceNow: -60)) == "", "past reset time → empty")

// 趋势条只标日：ISO 日期 → 日，非法输入不猜。
expect(f.dayLabel("2026-11-13") == "13", "trend label keeps the day of month")
expect(f.dayLabel("2026-11-03") == "3", "trend label drops a leading zero")
expect(f.dayLabel("2026-11") == "", "short date has no trend label")
expect(f.dayLabel("26-11-13") == "", "non-4-digit year has no trend label")
expect(f.dayLabel("2026-13-01") == "", "month 13 has no trend label")
expect(f.dayLabel("2026-11-32") == "", "day 32 has no trend label")
expect(f.dayLabel("2026-11-xx") == "", "non-numeric day has no trend label")

// 5h 是“剩余百分比”，面板只做整数显示，不能把已用值当剩余。
let row = UsageQuotaRow(label: "5h", remainingPercent: 100, resetText: "↻01:26")
expect(row.remainingPercent == 100, "5h row carries the remaining share")

// 没有颜色 API 依赖 macOS 12；这里只确认常量存在且是蓝色系。
expect(usageDeepSeekBlue != Color.clear, "DeepSeek blue is not the clear colour")

// 新增的 7 日与“累计已花”字段默认必须是空的，不能编造数据。
let emptySnapshot = UsageSnapshot()
expect(emptySnapshot.recentDayLabels.isEmpty && emptySnapshot.recentDayTokens.isEmpty,
       "DeepSeek trend defaults to empty")
expect(emptySnapshot.codexRecentDayLabels.isEmpty && emptySnapshot.codexRecentDayTokens.isEmpty,
       "Codex trend defaults to empty")
expect(emptySnapshot.deepSeekSpentText == nil, "spent defaults to nil until real fields arrive")
expect(emptySnapshot.qwenPlan == nil, "qwen plan defaults to nil so the card stays hidden")
expect(emptySnapshot.qwenPlanStale == false, "qwen plan stale defaults to false")

exit(failures == 0 ? 0 : 1)
'''


def swift_checks() -> bool:
    with tempfile.TemporaryDirectory(prefix="quotastrip-panel-tests-") as folder:
        work = pathlib.Path(folder)
        (work / "main.swift").write_text(HARNESS, encoding="utf-8")
        binary = work / "panel-tests"
        compile_result = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0",
             str(SOURCES / "UsagePanel.swift"), str(SOURCES / "DSHSessionProvider.swift"),
             str(SOURCES / "DSHBalanceProvider.swift"), str(SOURCES / "JimmyCloudPlanProvider.swift"),
             str(SOURCES / "MagpieProvider.swift"),
             str(work / "main.swift"),
             "-o", str(binary), "-framework", "AppKit", "-framework", "SwiftUI"],
            capture_output=True, text=True, timeout=300)
        if compile_result.returncode != 0:
            sys.stderr.write(compile_result.stdout + compile_result.stderr)
            return False
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        return run.returncode == 0


def source_checks() -> bool:
    panel = (SOURCES / "UsagePanel.swift").read_text(encoding="utf-8")
    main = (SOURCES / "main.swift").read_text(encoding="utf-8")
    failures = []

    def check(condition: bool, label: str) -> None:
        if condition:
            print("ok:", label)
        else:
            print("FAIL:", label)
            failures.append(label)

    check("Color(nsColor:" not in panel, "panel avoids macOS 12-only Color(nsColor:)")
    check(".monospacedDigit()" not in panel, "panel avoids macOS 12-only monospacedDigit()")
    check(".foregroundStyle(" not in panel, "panel avoids macOS 12-only foregroundStyle()")
    check("overlay(alignment:" not in panel, "panel avoids macOS 12-only overlay(alignment:)")
    check("WebView" not in panel and "Electron" not in panel, "no WebView / Electron")
    check("static let width: CGFloat = 480" in panel
          and "static let laneWidth: CGFloat = (width - 2 * pad - boardGap) / 2" in panel
          and "frame(width: PanelStyle.width" in panel,
          "panel is 480pt (one third narrower than the 720pt Glance board) with lane widths derived from it")
    check("VisualEffectBackground" in panel and "PanelBackground" not in panel,
          "panel sits on one frosted surface instead of an opaque fill")
    check("cardFill" not in panel and "cardStroke" not in panel,
          "sections no longer paint their own card fills")
    check("qianfanCard" not in panel and "sourceModelRows" in panel,
          "Qianfan is folded into the DeepSeek card instead of a separate card")
    check("panelSessionsExpanded" in panel and "toggleSessions" in panel
          and "\n            sessionsCard\n" not in panel,
          "sessions card kept in code but no longer rendered (user asked to hide it)")
    check("Today · local" not in panel and "qwenLocalModelRows" not in panel,
          "Qwen card no longer draws the local-today row (Magpie covers it)")
    check("UsageWindowMeter(progress:" in panel, "quota meters read an optional progress")
    # 2026-11-24 新口径：面板与 Touch Bar 一致显示「剩余」，不能再出现 used = 100 - remaining。
    check("100 - $0" not in panel, "quota windows no longer derive a used share")
    check("let remaining = row.remainingPercent.map" in panel
          and "UsageWindowMeter(progress: remaining" in panel,
          "percent text and meter both read the remaining share")
    check("<= 1 - PanelStyle.hot" in panel, "hot warning fires when remaining is low")
    check("sessionTile(symbol:" in panel and "square.grid.2x2.fill" in panel
          and "sparkles" in panel and "codex-logo" in panel,
          "every session row gets a recognisable icon (logo / sparkles / multi-model tile)")
    check("UsageAreaChart(values:" in panel, "hero draws the 7-day area chart")
    check("static let meterRadius: CGFloat = 3" in panel and "static let radius: CGFloat = 24" in panel,
          "cards and meters use Glance's glass radii (24 / 3)")
    check("enum GlanceFormat" in panel and "static func resetClock(" in panel
          and 'formatter.dateFormat = short ? "HH:mm" : "MM-dd HH:mm"' in panel,
          "window reset copy is the actual clock point (5h HH:mm, long MM-dd HH:mm)")
    check('case "5h", "5 h": return "5h"' in panel and 'case "7d", "week", "weekly": return "7d"' in panel,
          "window labels use the short 5h / 7d tags")
    check("var elapsed: Double?" not in panel and "Rectangle()" not in panel.split("struct UsageWindowMeter")[1].split("struct VisualEffectBackground")[0],
          "the elapsed-time vertical tick is gone from the window meter")
    check(".padding(.bottom, index < items.count - 1 ? PanelStyle.rowGap : 0)" not in panel,
          "pairs rows share one line height so both columns' bottom rows align")
    check("static let figure: CGFloat = 36" in panel and "static let blockGap: CGFloat = 14" in panel,
          "type scale and block rhythm follow Glance (36pt figure at the narrower width, 14pt blocks)")
    check("statusItem.menu = menu" not in main,
          "the status item no longer opens the menu on left click")
    check("sendAction(on: [.leftMouseUp, .rightMouseUp])" in main,
          "status item receives both mouse buttons")
    check("panelController.show(relativeTo:" in main, "left click opens the overview panel")
    check("NSMenu.popUpContextMenu" in main, "right click keeps the old menu")
    check(main.count("syncPanel()") >= 3, "panel snapshot is refreshed from every data path")
    check("UsagePanelModel" in main and "panelModel.onRefresh" in main,
          "panel actions are wired to the app")
    check("onOpenCredits" in main and "codexView.fallbackURL" in main,
          "View credits opens the official Codex usage page")
    check("codexUsageProvider.refresh" in main, "Codex usage refresh is driven by the provider")
    check("struct UsageAreaChart: View" in panel, "the today card draws the 7-day area chart")
    check("codexRecentDayTokens" in panel, "Codex card reads its own 7-day series")
    check("recentDayTokens" in panel, "the today card reads the 7-day series")
    check("deepSeekSpentText" in panel, "DeepSeek card shows cumulative spend")
    check("totalHeld" not in panel, "the panel never derives spend from totalHeld itself")
    check("codexUsageSnapshot.recentDayTokens" in main and "deepSeekSnapshot.recentDayTokens" in main,
          "syncPanel fills both 7-day series")
    check("totalHeld:" in main and "spentText(balance:" in main,
          "spent comes from the account totalHeld minus balance")
    check("9.79" not in panel and "1336" not in panel and "94.88" not in panel
          and "106515375" not in panel and "8.97" not in panel,
          "no hard-coded usage numbers in the panel")
    check("qwenPlanCard" in panel and "if model.snapshot.qwenPlan != nil" in panel,
          "Qwen Token Plan card exists and hides entirely without data")
    check("symbol: \"sparkles\"" in panel and "remainingPercent" in panel,
          "Qwen card uses the sparkles symbol and shows the remaining share")
    check("refreshQwenPlan" in main and "jimmyCloudPlanProvider" in main,
          "Qwen plan provider is wired into the refresh cycle")
    check("snapshot.qwenPlan = qwenPlanSnapshot" in main,
          "syncPanel fills the qwen plan snapshot field")
    # 2026-11-26/27 面板扩展：折线 / 会话数换 Magpie 主源，新增千问消耗卡与今日热力图。
    check("magpieActivity.recentDayTokens" in main
          and "if !magpieActivity.recentDayTokens.isEmpty" in main,
          "7-day chart prefers the Magpie merged series, DSH only as fallback")
    check("magpieTodaySessions" in panel and "snapshot.magpieTodaySessions = magpieActivity.todaySessions" in main,
          "today session count comes from Magpie first")
    check("magpieRequestAt" in panel and "Date().timeIntervalSince(at) <= 120" in panel,
          "working row judges activity from the latest Magpie request (120s)")
    check("magpieQwenCard" in panel and "if model.snapshot.magpieQwenToday != nil" in panel,
          "Magpie Qwen provider card exists and hides without data")
    check("heatmapCard" in panel and "magpieHeatDayTokens" in panel
          and "magpieHeatDayTokens.contains(where: { $0 > 0 })" in panel,
          "daily heatmap card exists and hides when all days are zero")
    check("snapshot.magpieQwenToday = magpieActivity.qwenToday" in main
          and "snapshot.magpieHeatDayTokens = magpieActivity.heatDayTokens" in main,
          "syncPanel feeds the new Magpie cards")

    return not failures


def main() -> int:
    ok_swift = swift_checks()
    print()
    ok_source = source_checks()
    print()
    if ok_swift and ok_source:
        print("PASS: panel formatter and wiring checks")
        return 0
    print("FAILED")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
