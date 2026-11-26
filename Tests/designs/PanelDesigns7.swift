import AppKit
import SwiftUI

/// 照抄 /tmp/token-receipt.html（token-receipt skill 的正版中文票面）的视觉语言：
/// 白纸、极细规则线、等宽小字、两列右对齐、像素 logo、ASCII 条码、票号。
/// 这里把它做成 QuotaStrip 状态面板的两个 AI 版本：Codex 与 DeepSeek 同票。
/// 只用于设计评审，不参与正式构建。
enum ReceiptStyle: Int, CaseIterable {
    case paper   // 白纸（正版观感）
    case pos     // 深色收银屏（暗色模式）
}

struct ReceiptTheme {
    let paper: Color
    let ink: Color
    let inkSoft: Color
    let rule: Color
    let accent: Color

    static let light = ReceiptTheme(
        paper: Color.white,
        ink: Color(red: 0.082, green: 0.082, blue: 0.082),
        inkSoft: Color(red: 0.35, green: 0.35, blue: 0.35),
        rule: Color(red: 0.137, green: 0.137, blue: 0.137),
        accent: Color(red: 0.09, green: 0.45, blue: 0.20))

    static let dark = ReceiptTheme(
        paper: Color(red: 0.055, green: 0.055, blue: 0.058),
        ink: Color(red: 0.93, green: 0.93, blue: 0.93),
        inkSoft: Color(red: 0.62, green: 0.62, blue: 0.62),
        rule: Color(red: 0.55, green: 0.55, blue: 0.55),
        accent: Color(red: 0.36, green: 0.86, blue: 0.52))
}

struct ReceiptFixture {
    var codexFive = 96
    var codexFiveReset = "19:23"
    var codexWeek = 25
    var codexWeekReset = "3d11h"
    var codexToday = "16.1K"
    var codexCache = "91.9%"
    var credits = "1331.4"

    var balance = "¥43.25"
    var spent = "¥27.86"
    var todayTokens = "56.17M"
    var monthTokens = "334.52M"
    var cacheHit = "98.8%"

    var stamp = "2026-11-17 14:44:45"
    var receiptId = "AI_20261117_144445_A7F3"
    var model = "codex · deepseek-flash"
    var footer = "缓存命中 98.8%，钱花在推理上。"
    var barcode = "|| ||||||| |||| | ||||||||| ||"
}

struct ReceiptPanelView: View {
    var style: ReceiptStyle = .paper
    var data = ReceiptFixture()

    private var theme: ReceiptTheme { style == .paper ? .light : .dark }

    private let width: CGFloat = 330
    private let padX: CGFloat = 18
    private let rowSize: CGFloat = 13
    private let metaSize: CGFloat = 11
    private let labelSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rule(strong: true)
            group([
                ("供应商", "DSH_LOCAL", theme.ink),
                ("模型", data.model, theme.ink),
                ("凭据", "DSH 登录态", theme.inkSoft)
            ])
            rule()
            group([("项目", "TOKEN / CNY", theme.inkSoft)])
            rule()
            group([
                ("Codex 5h 剩余", "\(data.codexFive)%  · \(data.codexFiveReset)", theme.ink),
                ("Codex 7d 剩余", "\(data.codexWeek)%  · \(data.codexWeekReset)", theme.ink),
                ("今日输出", data.codexToday + " tok", theme.ink),
                ("输入缓存", data.codexCache, theme.accent)
            ])
            rule()
            group([
                ("余额", data.balance, theme.ink),
                ("累计已花", data.spent, theme.ink),
                ("今日 Tokens", data.todayTokens, theme.ink),
                ("本月 Tokens", data.monthTokens, theme.ink),
                ("缓存命中", data.cacheHit, theme.accent)
            ])
            rule(strong: true)
            totalRow
            rule()
            group([
                ("Credits", data.credits, theme.inkSoft),
                ("计价口径", "官方累计消费", theme.inkSoft)
            ])
            rule(strong: true)
            footer
        }
        .padding(.horizontal, padX)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: width, alignment: .leading)
        .background(theme.paper)
        .overlay(Rectangle().stroke(Color.black.opacity(style == .paper ? 0.05 : 0.35), lineWidth: 1))
    }

    // MARK: - 票头

    private var header: some View {
        VStack(spacing: 0) {
            logo
            Text("CODEX × DEEPSEEK")
                .font(.system(size: labelSize, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundColor(theme.ink)
                .padding(.top, 10)
            Text("感谢使用 Codex 与 DeepSeek")
                .font(.system(size: metaSize, design: .monospaced))
                .foregroundColor(theme.inkSoft)
                .padding(.top, 8)
            Text("小票号: " + data.receiptId)
                .font(.system(size: metaSize, design: .monospaced))
                .foregroundColor(theme.inkSoft)
                .padding(.top, 3)
            Text("日期: " + data.stamp)
                .font(.system(size: metaSize, design: .monospaced))
                .foregroundColor(theme.inkSoft)
                .padding(.top, 3)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private var logo: some View {
        Group {
            if let image = ReceiptAssets.codexLogo, style == .paper {
                Image(nsImage: image).resizable().interpolation(.none)
                    .aspectRatio(contentMode: .fit).frame(width: 74)
            } else {
                Text(">_").font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.ink)
            }
        }
        .frame(height: 58)
    }

    // MARK: - 行与规则线

    private func group(_ rows: [(String, String, Color)]) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0)
                        .font(.system(size: rowSize, design: .monospaced))
                        .foregroundColor(theme.ink)
                    Spacer(minLength: 8)
                    Text(row.1)
                        .font(.system(size: rowSize, weight: .medium, design: .monospaced))
                        .foregroundColor(row.2)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var totalRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("合计已花")
                .font(.system(size: rowSize + 1, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.ink)
            Spacer(minLength: 8)
            Text(data.spent)
                .font(.system(size: rowSize + 3.5, weight: .bold, design: .monospaced))
                .foregroundColor(theme.ink)
                .fixedSize()
        }
        .padding(.vertical, 9)
    }

    private func rule(strong: Bool = false) -> some View {
        Rectangle()
            .fill(theme.rule)
            .frame(height: strong ? 1.4 : 0.9)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Text(data.footer)
                .font(.system(size: metaSize + 0.5, design: .monospaced))
                .foregroundColor(theme.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Text(data.barcode)
                .font(.system(size: 13, design: .monospaced))
                .tracking(-0.4)
                .foregroundColor(theme.ink)
                .padding(.top, 10)
            Text(data.receiptId)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.inkSoft)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 渲染脚本通过环境变量把正版 logo 喂进来；正式落地时会打包进 Resources。
enum ReceiptAssets {
    static let codexLogo: NSImage? = {
        guard let path = ProcessInfo.processInfo.environment["QS_RECEIPT_CODEX_LOGO"] else { return nil }
        return NSImage(contentsOfFile: path)
    }()
}
