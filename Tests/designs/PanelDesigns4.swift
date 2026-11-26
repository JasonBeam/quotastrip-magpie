import SwiftUI

/// 第四轮：两个完全不同的语言。
/// 16 = macOS 原生（无卡片、细分隔线、大字留白）
/// 17 = 票据 / 终端（全等宽、点线引导）
/// 仅设计稿，由 Tests/render-panel4.py 用真实 NSHostingView 渲染；macOS 11 兼容。
struct Panel4Fixture {
    var balance = "45.69"
    var spent = "25.42"
    var today = "19.93M"
    var month = "298.28M"
    var cache = "98.4%"
    var codexFive = 52
    var codexWeek = 25
    var codexTodayOutput = "12.3K"
    var codexCache = "90.7%"
    var codexCredits = "1331.4"
    var stamp = "11-17 13:06"
}

enum Panel4Style: Int, CaseIterable {
    case native   // 16
    case receipt  // 17
}

struct Panel4View: View {
    let style: Panel4Style
    var data = Panel4Fixture()

    private var blue: Color { Color(red: 0.26, green: 0.48, blue: 1) }
    private var green: Color { Color(red: 0.16, green: 0.62, blue: 0.42) }

    var body: some View {
        switch style {
        case .native: nativePanel
        case .receipt: receiptPanel
        }
    }

    // MARK: - 16 macOS 原生

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
    }

    private func micro(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color.secondary)
            .tracking(0.8)
    }

    private func nativeRow(_ label: String, _ value: String, tint: Color, size: CGFloat = 16) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundColor(Color.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var nativePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("用量概览").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .foregroundColor(Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                micro("DeepSeek · 余额")
                Text("¥" + data.balance)
                    .font(.system(size: 34, weight: .medium, design: .monospaced))
                    .foregroundColor(blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("累计已花 ¥" + data.spent)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.secondary)
            }

            hairline

            VStack(spacing: 8) {
                nativeRow("今日用量", data.today + " tok", tint: Color.primary)
                nativeRow("本月累计", data.month, tint: Color.primary)
                nativeRow("缓存命中", data.cache, tint: green)
            }

            hairline

            VStack(alignment: .leading, spacing: 8) {
                micro("Codex")
                nativeRow("5 小时剩余", "\(data.codexFive)%", tint: Color.primary)
                nativeRow("7 天剩余", "\(data.codexWeek)%", tint: Color.primary)
                nativeRow("今日输出", data.codexTodayOutput + " tok", tint: Color.primary)
                nativeRow("输入缓存", data.codexCache, tint: green)
            }

            HStack {
                Text("更新于 13:06:23").font(.system(size: 10.5))
                Spacer()
                Text("本机会话统计").font(.system(size: 10.5))
            }
            .foregroundColor(Color.secondary)
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(Color.primary.opacity(0.001))   // 让 popover 材质透上来，不铺灰卡
    }

    // MARK: - 17 票据 / 终端

    private func leader(label: String, value: String, tint: Color, valueSize: CGFloat = 15) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundColor(Color.secondary)
                .fixedSize()
            DottedRule()
                .stroke(Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            Text(value)
                .font(.system(size: valueSize, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .fixedSize()
        }
        .frame(height: max(20, valueSize + 6))
    }

    private func rule(_ dashed: Bool) -> some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
            }
            .stroke(Color.secondary.opacity(0.30),
                    style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : []))
        }
        .frame(height: 1)
    }

    private var receiptPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI USAGE").font(.system(size: 12, weight: .bold, design: .monospaced))
                Spacer()
                Text(data.stamp).font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Color.secondary)
            }
            rule(true)

            leader(label: "余额", value: "¥" + data.balance, tint: blue, valueSize: 22)
            leader(label: "累计已花", value: "¥" + data.spent, tint: Color.primary)
            leader(label: "今日用量", value: data.today + " tok", tint: Color.primary)
            leader(label: "本月累计", value: data.month, tint: Color.primary)
            leader(label: "缓存命中", value: data.cache, tint: green)

            rule(true)

            Text("CODEX").font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(Color.secondary)
            leader(label: "5h", value: "\(data.codexFive)%", tint: Color.primary, valueSize: 14)
            leader(label: "7d", value: "\(data.codexWeek)%", tint: Color.primary, valueSize: 14)
            leader(label: "今日输出", value: data.codexTodayOutput + " tok", tint: Color.primary, valueSize: 14)
            leader(label: "输入缓存", value: data.codexCache, tint: green, valueSize: 14)
            leader(label: "Credits", value: data.codexCredits, tint: Color.primary, valueSize: 14)

            rule(true)
            HStack {
                Text("本机会话统计").font(.system(size: 10, design: .monospaced))
                Spacer()
                Text("13:06:23").font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(Color.secondary)
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
    }
}


/// 点线引导：只在标签与数值之间画点，不再垫在数字下面。
struct DottedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}
