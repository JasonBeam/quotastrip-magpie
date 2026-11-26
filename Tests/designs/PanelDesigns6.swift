import SwiftUI

/// 22/23：把 token-receipt skill 的小票语言搬到状态栏面板上。
/// 22 = 纸色热敏（暖白纸、深灰墨、块状像素标）
/// 23 = POS 深色屏（黑底、浅灰字、同一套字格）
/// 仅设计稿；由 Tests/render-panel6.py 用真实 NSHostingView 渲染；macOS 11 兼容。
enum Panel6Style: Int, CaseIterable {
    case paper    // 22
    case pos      // 23
}

struct Panel6Fixture {
    var stamp = "11-17 14:39"
    var receiptId = "A7F3"
    var codexFive = 96
    var codexWeek = 25
    var codexFiveReset = "↻19:23"
    var codexWeekReset = "3d11h"
    var codexTodayOutput = "16.1K tok"
    var codexCache = "91.9%"
    var balance = "¥43.25"
    var spent = "¥27.86"
    var today = "56.17M tok"
    var month = "334.52M tok"
    var cache = "98.8%"
}

struct Panel6View: View {
    let style: Panel6Style
    var data = Panel6Fixture()

    private let columns = 42
    private var ink: Color {
        style == .paper ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(white: 0.86)
    }
    private var inkSoft: Color { ink.opacity(0.55) }
    private var accent: Color {
        style == .paper ? Color(red: 0.09, green: 0.45, blue: 0.28) : Color(red: 0.36, green: 0.86, blue: 0.55)
    }
    private var paper: Color {
        style == .paper ? Color(red: 0.98, green: 0.97, blue: 0.94) : Color(red: 0.07, green: 0.07, blue: 0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line.text)
                    .font(.system(size: 11, weight: line.bold ? .bold : .regular, design: .monospaced))
                    .foregroundColor(line.tint == .accent ? accent : (line.tint == .soft ? inkSoft : ink))
                    .frame(height: 13, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(paper)
        .frame(width: 330)
    }

    // MARK: - 票面

    private enum Tone { case normal, soft, accent }
    private struct Line { let text: String; var bold = false; var tint: Tone = .normal }

    private var lines: [Line] {
        var out: [Line] = []
        out.append(Line(text: center("AI USAGE RECEIPT"), bold: true))
        out.append(Line(text: center("CODEX × DEEPSEEK"), tint: .soft))
        out.append(Line(text: center("NO." + data.receiptId + "  ·  " + data.stamp), tint: .soft))
        out.append(Line(text: rule("═")))
        out.append(Line(text: row("ITEM", "VALUE"), tint: .soft))

        out.append(Line(text: rule("─")))
        out.append(Line(text: sectionTitle("CODEX · OPENAI"), bold: true))
        out.append(Line(text: barRow(" 5h", percent: data.codexFive, reset: data.codexFiveReset)))
        out.append(Line(text: barRow(" 7d", percent: data.codexWeek, reset: data.codexWeekReset)))
        out.append(Line(text: row("  today output", data.codexTodayOutput)))
        out.append(Line(text: row("  input cache", data.codexCache), tint: .accent))

        out.append(Line(text: rule("─")))
        out.append(Line(text: sectionTitle("DEEPSEEK"), bold: true))
        out.append(Line(text: row("  balance", data.balance), bold: true))
        out.append(Line(text: row("  spent to date", data.spent)))
        out.append(Line(text: row("  today tokens", data.today)))
        out.append(Line(text: row("  month tokens", data.month)))
        out.append(Line(text: row("  cache hit", data.cache), tint: .accent))

        out.append(Line(text: rule("═")))
        out.append(Line(text: row("TOTAL SPENT", data.spent), bold: true))
        out.append(Line(text: barcode()))
        out.append(Line(text: center("0001 4532 0017 1117"), tint: .soft))
        out.append(Line(text: rule("─")))
        out.append(Line(text: center("thank you for coding"), bold: true))
        out.append(Line(text: center("本机会话统计 · 非官方账单"), tint: .soft))
        return out
    }

    /// 和 Codex 模块同构：标签 + 方块进度条 + 百分比 + 重置倒计时，只是用字符画出来。
    private func barRow(_ label: String, percent: Int, reset: String) -> String {
        let cells = 12
        let filled = max(0, min(cells, Int((Double(percent) / 100 * Double(cells)).rounded())))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: cells - filled)
        let left = label + " " + bar
        let pct = "\(percent)%"
        let percentEnd = 32
        let resetEnd = columns
        var line = left
        line += String(repeating: " ", count: max(1, percentEnd - width(line) - width(pct)))
        line += pct
        line += String(repeating: " ", count: max(1, resetEnd - width(line) - width(reset)))
        line += reset
        return line
    }

    /// 段标题后面用一条细线填满整行，等宽字体下最稳的「品牌分隔带」。
    private func sectionTitle(_ name: String) -> String {
        name + " " + String(repeating: "─", count: max(0, columns - width(name) - 1))
    }

    private func rule(_ character: String) -> String {
        String(repeating: character, count: columns)
    }

    private func row(_ left: String, _ right: String) -> String {
        let pad = max(1, columns - width(left) - width(right))
        return left + String(repeating: " ", count: pad) + right
    }

    private func center(_ text: String) -> String {
        let pad = max(0, (columns - width(text)) / 2)
        return String(repeating: " ", count: pad) + text
    }

    private func barcode() -> String {
        let pattern = "▏▎▍▌▋▊▉▌▎▏▎▍▌▉▊▋▌▎▏▎▍▌▋▊▉"
        let pad = max(0, (columns - width(pattern)) / 2)
        return String(repeating: " ", count: pad) + pattern
    }

    /// 等宽字体里中日韩字符占两格，宽度按 2 计，才能对齐。
    private func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.value > 0x2E80 ? 2 : 1)
        }
    }
}
