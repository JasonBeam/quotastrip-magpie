import SwiftUI

/// 第三轮面板设计：主题只有一个——字要大。
/// 不参与正式构建，由 Tests/render-panel3.py 用真实 NSHostingView 离屏渲染。
/// macOS 11 兼容：不用 Color(nsColor:)、foregroundStyle、monospacedDigit、overlay(alignment:)。
struct Panel3Fixture {
    // Codex
    var codexFive = 52
    var codexFiveReset = "13:18"
    var codexWeek = 25
    var codexWeekReset = "3d12h"
    var codexTodayOutput = "12.3K tok"
    var codexCache = "90.7%"
    var codexCredits = "1331.4"
    // DeepSeek
    var balance = "45.69"
    var spent = "25.42"
    var today = "19.93M"
    var month = "298.28M"
    var cache = "98.4%"
}

enum Panel3Style: Int, CaseIterable {
    case listBig   // 11 大字清单：一行一个指标，数值 26pt
    case tiles     // 12 KPI 磁贴：2×2，数值 30pt
    case wide      // 13 横向宽卡：余额 40pt 当主角，右侧三行 17pt
    case rings     // 14 圆环：5h/7d/缓存 用环，数字 20pt
    case split     // 15 分栏大表：Codex | DeepSeek 并排，数值 22pt
}

struct Panel3View: View {
    let style: Panel3Style
    var data = Panel3Fixture()

    private var deepSeekBlue: Color { Color(red: 0.26, green: 0.48, blue: 1) }
    private var hitGreen: Color { Color(red: 0.20, green: 0.68, blue: 0.47) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch style {
            case .listBig: listBig
            case .tiles: tiles
            case .wide: wide
            case .rings: rings
            case .split: split
            }
            footer
        }
        .padding(18)
        .frame(width: style == .wide ? 470 : 400, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("AI 用量概览").font(.system(size: 15, weight: .semibold))
            Spacer()
            Image(systemName: "arrow.clockwise").font(.system(size: 13))
            Image(systemName: "gearshape").font(.system(size: 13))
        }
        .foregroundColor(Color.secondary)
    }

    private var footer: some View {
        HStack {
            Text("更新于 13:06:23").font(.system(size: 11))
            Spacer()
            Text("本机会话统计").font(.system(size: 11))
        }
        .foregroundColor(Color.secondary)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private func providerTitle(_ name: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundColor(tint)
            Text(name).font(.system(size: 14, weight: .semibold))
            Spacer()
            Image(systemName: "arrow.up.right.square").font(.system(size: 11)).foregroundColor(Color.secondary)
        }
    }

    private func bigRow(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12.5)).foregroundColor(Color.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }

    // MARK: - 11 大字清单

    private var listBig: some View {
        VStack(spacing: 14) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    providerTitle("Codex", symbol: "cube", tint: Color.secondary)
                    bigRow("5 小时剩余", "\(data.codexFive)%", tint: Color.primary)
                    bigRow("7 天剩余", "\(data.codexWeek)%", tint: Color.primary)
                    bigRow("今日输出", data.codexTodayOutput, tint: Color.primary)
                    bigRow("输入缓存", data.codexCache, tint: hitGreen)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    providerTitle("DeepSeek", symbol: "dollarsign.circle", tint: deepSeekBlue)
                    bigRow("余额", "¥" + data.balance, tint: deepSeekBlue)
                    bigRow("今日用量", data.today, tint: Color.primary)
                    bigRow("本月累计", data.month, tint: Color.primary)
                    bigRow("缓存命中", data.cache, tint: hitGreen)
                }
            }
        }
    }

    // MARK: - 12 KPI 磁贴

    private func tile(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundColor(Color.secondary)
            Text(value)
                .font(.system(size: 27, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }

    private var tiles: some View {
        VStack(spacing: 14) {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    providerTitle("Codex", symbol: "cube", tint: Color.secondary)
                    HStack(spacing: 10) {
                        tile("5 小时", "\(data.codexFive)%", tint: Color.primary)
                        tile("7 天", "\(data.codexWeek)%", tint: Color.primary)
                    }
                    HStack(spacing: 10) {
                        tile("今日输出", data.codexTodayOutput, tint: Color.primary)
                        tile("输入缓存", data.codexCache, tint: hitGreen)
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 10) {
                    providerTitle("DeepSeek", symbol: "dollarsign.circle", tint: deepSeekBlue)
                    HStack(spacing: 10) {
                        tile("余额", "¥" + data.balance, tint: deepSeekBlue)
                        tile("今日用量", data.today, tint: Color.primary)
                    }
                    HStack(spacing: 10) {
                        tile("本月累计", data.month, tint: Color.primary)
                        tile("缓存命中", data.cache, tint: hitGreen)
                    }
                }
            }
        }
    }

    // MARK: - 13 横向宽卡

    private func wideRow(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundColor(Color.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
        }
    }

    private var wide: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                providerTitle("DeepSeek Account", symbol: "dollarsign.circle", tint: deepSeekBlue)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("余额").font(.system(size: 12)).foregroundColor(Color.secondary)
                        Text("¥" + data.balance)
                            .font(.system(size: 40, weight: .semibold, design: .monospaced))
                            .foregroundColor(deepSeekBlue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("累计已花 ¥" + data.spent).font(.system(size: 11.5)).foregroundColor(Color.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 9) {
                        wideRow("今日用量", data.today, tint: Color.primary)
                        wideRow("本月累计", data.month, tint: Color.primary)
                        wideRow("缓存命中", data.cache, tint: hitGreen)
                    }
                }
                Divider().opacity(0.4)
                HStack(spacing: 16) {
                    miniStat("Codex 5 小时", "\(data.codexFive)%", tint: Color.primary)
                    miniStat("7 天", "\(data.codexWeek)%", tint: Color.primary)
                    miniStat("今日输出", data.codexTodayOutput, tint: Color.primary)
                }
            }
        }
    }

    private func miniStat(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundColor(Color.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 14 圆环

    private func ring(_ label: String, _ percent: Int, tint: Color) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, percent))) / 100.0)
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(percent)%")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.primary)
                Text(label).font(.system(size: 10.5)).foregroundColor(Color.secondary)
            }
        }
        .frame(width: 86, height: 86)
    }

    private var rings: some View {
        VStack(spacing: 14) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    providerTitle("Codex", symbol: "cube", tint: Color.secondary)
                    HStack(spacing: 18) {
                        ring("5 小时", data.codexFive, tint: Color(red: 0.20, green: 0.78, blue: 0.35))
                        ring("7 天", data.codexWeek, tint: Color(red: 0.95, green: 0.72, blue: 0.20))
                    }
                    HStack(spacing: 16) {
                        miniStat("今日输出", data.codexTodayOutput, tint: Color.primary)
                        miniStat("输入缓存", data.codexCache, tint: hitGreen)
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    providerTitle("DeepSeek", symbol: "dollarsign.circle", tint: deepSeekBlue)
                    HStack(spacing: 18) {
                        ring("缓存命中", 98, tint: hitGreen)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("¥" + data.balance)
                                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                                .foregroundColor(deepSeekBlue)
                            wideRow("今日用量", data.today, tint: Color.primary)
                            wideRow("本月累计", data.month, tint: Color.primary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 15 分栏大表

    private func column(_ title: String, symbol: String, tint: Color,
                        rows: [(String, String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundColor(tint)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.0).font(.system(size: 11)).foregroundColor(Color.secondary)
                    Text(row.1)
                        .font(.system(size: 21, weight: .semibold, design: .monospaced))
                        .foregroundColor(row.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.05)))
    }

    private var split: some View {
        HStack(alignment: .top, spacing: 12) {
            column("Codex", symbol: "cube", tint: Color.secondary, rows: [
                ("5 小时", "\(data.codexFive)%", Color.primary),
                ("7 天", "\(data.codexWeek)%", Color.primary),
                ("今日输出", data.codexTodayOutput, Color.primary),
                ("输入缓存", data.codexCache, hitGreen),
            ])
            column("DeepSeek", symbol: "dollarsign.circle", tint: deepSeekBlue, rows: [
                ("余额", "¥" + data.balance, deepSeekBlue),
                ("今日", data.today, Color.primary),
                ("本月", data.month, Color.primary),
                ("缓存", data.cache, hitGreen),
            ])
        }
    }
}
