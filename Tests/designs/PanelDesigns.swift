import SwiftUI
import AppKit

/// 设计评审用：两种「AI 用量概览」面板方案。不参与正式构建。
/// 参考社区做法：Runic 的 provider tab + hero stat + sparkline，
/// TokenTracker 的活动柱状图，claude-monitor-lite 的临界色。
struct PanelFixture {
    var balance = "¥50.95"
    var spent = "¥20.16"
    var todayTokens = "3.57M"
    var cacheHit = "78.6%"
    var weekPerDay: [Double] = [8.97, 106.5, 103.1, 6.77, 3.57, 0, 0]
    var codexFive = 100
    var codexWeek = 41
    var codexReset = "↻00:29"
    var codexWeekReset = "4d6h"
    var codexToday = "13.3K tok"
    var codexCache = "95.2%"
    var codexCredits = "1331.4"
    var codexCreditsNote = "本机 · 最近记录 11-16 19:29"
    var updated = "更新于 19:29:52"
}

enum PanelV2Style: Int, CaseIterable {
    case heroTabbed   // A：provider 切换 + 余额当家 + 近 7 日柱状
    case stackedSpark // B：两张卡都加趋势条，结构对齐
}

struct PanelV2View: View {
    var style: PanelV2Style = .heroTabbed
    var data = PanelFixture()
    var icon: (String) -> NSImage? = { _ in nil }

    private let blue = Color(red: 0.26, green: 0.48, blue: 1)
    private let green = Color(red: 0.35, green: 0.84, blue: 0.60)
    private let yellow = Color(red: 0.98, green: 0.75, blue: 0.20)
    private let red = Color(red: 0.94, green: 0.36, blue: 0.40)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch style {
            case .heroTabbed: heroTabbed
            case .stackedSpark: stackedSpark
            }
            footer
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
    }

    // MARK: - 共用部件

    private var header: some View {
        HStack(spacing: 10) {
            Text("AI 用量概览").font(.system(size: 15, weight: .semibold))
            Spacer()
            iconButton("arrow.clockwise")
            iconButton("gearshape")
        }
    }

    private func iconButton(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: 22, height: 22)
    }

    private var footer: some View {
        HStack {
            Text(data.updated).font(.system(size: 10.5, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.65))
            Spacer()
            Text("本机会话统计").font(.system(size: 10.5, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.65))
        }
        .padding(.top, 2)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
    }

    private func brandIcon(_ name: String, size: CGFloat = 20) -> some View {
        Group {
            if let image = icon(name) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
    }

    /// 近 7 日柱状条：社区里最常见的趋势表达（TokenTracker / MonitHor / Runic 都在用）。
    private let dayLabels = ["12", "13", "14", "15", "16", "17", "18"]

    /// 近 7 日柱状条：社区里最常见的趋势表达（TokenTracker / MonitHor / Runic 都在用）。
    private func sparkBars(values: [Double], color: Color, height: CGFloat = 30, labels: Bool = true) -> some View {
        let peak = max(values.max() ?? 1, 1)
        return VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    // 没有记录的那天只留一条淡淡的槽位，不画成「有数据」的小柱子。
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(value <= 0 ? Color.primary.opacity(0.12)
                                         : color.opacity(index == values.count - 1 ? 1 : 0.55))
                        // 平方根刻度：8.9M 到 106M 差 12 倍，线性刻度下小柱子看不出是「有数据」。
                        .frame(height: value <= 0 ? 2 : max(4, height * CGFloat((value / peak).squareRoot())))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: height, alignment: .bottom)
            if labels {
                HStack(spacing: 5) {
                    ForEach(Array(dayLabels.prefix(values.count).enumerated()), id: \.offset) { _, day in
                        Text(day)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Color.secondary.opacity(0.55))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func metricTile(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint ?? .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func quotaRow(_ label: String, percent: Int, reset: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(width: 20, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(percent <= 10 ? red : (percent <= 25 ? yellow : green))
                        .frame(width: max(4, geo.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: 7)
            Text("\(percent)%")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 40, alignment: .trailing)
            Text(reset)
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: - A：provider 切换 + 余额当家

    private var heroTabbed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                tab("DeepSeek", icon: "deepseek-logo", active: true)
                tab("Codex", icon: "codex-logo", active: false)
                Spacer()
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(data.balance)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundColor(blue)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("累计已花 \(data.spent)")
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                            Text("今日 \(data.todayTokens) tok")
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                    sparkBars(values: data.weekPerDay, color: blue, height: 30)
                    HStack {
                        Text("近 7 日").font(.system(size: 10, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.65))
                        Spacer()
                        Text("峰值 106.5M").font(.system(size: 10, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.65))
                    }
                    HStack(spacing: 8) {
                        metricTile("今日用量", "\(data.todayTokens) tok")
                        metricTile("缓存命中", data.cacheHit, tint: green)
                    }
                }
            }

            HStack(spacing: 4) {
                Text("Codex").font(.system(size: 11, weight: .medium))
                Text("5h \(data.codexFive)% · 7d \(data.codexWeek)%")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Spacer()
                Text(data.codexReset).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.65))
            }
            .padding(.horizontal, 4)
        }
    }

    private func tab(_ title: String, icon name: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            brandIcon(name, size: 15)
            Text(title).font(.system(size: 11.5, weight: active ? .semibold : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(active ? 0.10 : 0.04))
        )
    }

    // MARK: - B：两张卡 + 趋势条

    private var stackedSpark: some View {
        VStack(spacing: 12) {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        brandIcon("codex-logo", size: 18)
                        Text("Codex").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.65))
                    }
                    quotaRow("5h", percent: data.codexFive, reset: data.codexReset)
                    quotaRow("7d", percent: data.codexWeek, reset: data.codexWeekReset)
                    HStack(spacing: 8) {
                        metricTile("今日输出", data.codexToday)
                        metricTile("输入缓存", data.codexCache, tint: green)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Credits").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary)
                            Text(data.codexCredits)
                                .font(.system(size: 13, weight: .semibold))                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(data.codexCreditsNote).font(.system(size: 10, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.65))
                            Text("查看积分").font(.system(size: 10.5, weight: .medium)).foregroundColor(blue)
                        }
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        brandIcon("deepseek-logo", size: 18)
                        Text("DeepSeek Account").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.65))
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(data.balance)
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundColor(blue)
                        Spacer()
                        Text("累计已花 \(data.spent)")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                    sparkBars(values: data.weekPerDay, color: blue, height: 22)
                    HStack(spacing: 8) {
                        metricTile("今日用量", "\(data.todayTokens) tok")
                        metricTile("缓存命中", data.cacheHit, tint: green)
                    }
                }
            }
        }
    }
}
