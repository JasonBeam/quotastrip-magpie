import SwiftUI

/// 第五轮：把票据往「便利店小票」推。
/// 18 = 7-11 风格热敏小票：纸质暖白底、居中店头、等宽、整数右对齐、双线分隔、锯齿撕口、条码、谢谢惠顾。
/// 仅设计稿，由 Tests/render-panel5.py 用真实 NSHostingView 渲染；macOS 11 兼容。
struct Panel5Fixture {
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

enum Panel5Style: Int, CaseIterable {
    case receipt711         // 18 标准宽度 330
    case receipt711Compact  // 19 窄版 300，去掉付款方式独立行
}

struct Panel5View: View {
    let style: Panel5Style
    var data = Panel5Fixture()

    /// 热敏纸的暖白；深浅色都保持纸的质感，像真的贴在深色 popover 上。
    private var paper: Color { Color(red: 0.98, green: 0.97, blue: 0.94) }
    private var ink: Color { Color(red: 0.13, green: 0.13, blue: 0.14) }
    private var inkSoft: Color { Color(red: 0.13, green: 0.13, blue: 0.14).opacity(0.62) }
    private var priceInk: Color { Color(red: 0.13, green: 0.13, blue: 0.14) }
    private var green: Color { Color(red: 0.09, green: 0.45, blue: 0.28) }

    private let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    private let monoBold = Font.system(size: 12, weight: .bold, design: .monospaced)

    var body: some View {
        switch style {
        case .receipt711: receipt
        case .receipt711Compact: Panel5CompactView()
        }
    }

    // MARK: - 小票主体

    private var receipt: some View {
        VStack(spacing: 0) {
            SerratedEdge(pointsUp: false)
                .fill(paper)
                .frame(height: 5)

            VStack(alignment: .leading, spacing: 0) {
                header
                doubleRule
                section([("余额", "¥" + data.balance, priceInk, 17),
                         ("累计已花", "¥" + data.spent, ink, 12)])
                singleRule
                section([("付款方式", "DSH 登录态", inkSoft, 10.5)])
                singleRule
                section([("今日用量", data.today + " tok", ink, 12),
                         ("本月累计", data.month + " tok", ink, 12),
                         ("缓存命中", data.cache, green, 12)])
                doubleRule
                dividerLabel("CODEX · OPENAI")
                section([("5h 剩余", "\(data.codexFive)%", ink, 12),
                         ("7d 剩余", "\(data.codexWeek)%", ink, 12),
                         ("今日输出", data.codexTodayOutput + " tok", ink, 12),
                         ("输入缓存", data.codexCache, green, 12),
                         ("Credits", data.codexCredits, ink, 12)])
                doubleRule
                total
                barcode
                barcodeNumber
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            SerratedEdge(pointsUp: true)
                .fill(paper)
                .frame(height: 5)
        }
        .background(paper)
        .frame(width: 330)
        .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 3)
    }

    private var header: some View {
        VStack(spacing: 3) {
            Text("AI 用量小票").font(.system(size: 13, weight: .bold, design: .monospaced))
            Text("CODEX × DEEPSEEK").font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2).foregroundColor(inkSoft)
            Text("NO.0001  ·  " + data.stamp).font(.system(size: 9, design: .monospaced))
                .foregroundColor(inkSoft)
            Text("STORE 001   TERM 03   CASHIER AI")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(inkSoft.opacity(0.85))
        }
        .foregroundColor(ink)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private func section(_ rows: [(String, String, Color, CGFloat)]) -> some View {
        VStack(spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0).font(mono).foregroundColor(inkSoft).fixedSize()
                    Spacer(minLength: 10)
                    Text(row.1)
                        .font(.system(size: row.3, weight: .semibold, design: .monospaced))
                        .foregroundColor(row.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 7)
    }

    private func dividerLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0).foregroundColor(inkSoft)
            Spacer()
        }
        .padding(.top, 2)
    }

    private var singleRule: some View {
        Rectangle().fill(ink.opacity(0.28)).frame(height: 1)
    }

    private var doubleRule: some View {
        VStack(spacing: 2) {
            Rectangle().fill(ink.opacity(0.55)).frame(height: 1)
            Rectangle().fill(ink.opacity(0.55)).frame(height: 1)
        }
    }

    private var total: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("合计已花").font(.system(size: 13, weight: .bold, design: .monospaced))
            Spacer()
            Text("¥" + data.spent).font(.system(size: 17, weight: .bold, design: .monospaced))
        }
        .foregroundColor(ink)
        .padding(.top, 8)
    }

    private var barcode: some View {
        HStack(spacing: 1.4) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, width in
                Rectangle().fill(ink).frame(width: width, height: 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    static let bars: [CGFloat] = [2, 1, 3, 1, 2, 1, 1, 4, 1, 2, 3, 1, 1, 2, 4, 1,
                                          2, 1, 3, 2, 1, 1, 3, 1, 4, 1, 2, 2, 1, 3, 1, 2]

    private var barcodeNumber: some View {
        Text("0001 4532 0017 1117")
            .font(.system(size: 9, design: .monospaced))
            .tracking(1.6)
            .foregroundColor(inkSoft)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text("本机会话统计 · 非官方账单").font(.system(size: 9, design: .monospaced))
            Text("谢谢惠顾").font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("13:06:23").font(.system(size: 9, design: .monospaced))
        }
        .foregroundColor(inkSoft)
        .frame(maxWidth: .infinity)
    }
}

/// 19 · 窄版小票：300pt，字号小一档，付款方式并进页脚，更像 58mm 热敏纸。
struct Panel5CompactView: View {
    var data = Panel5Fixture()

    private var paper: Color { Color(red: 0.98, green: 0.97, blue: 0.94) }
    private var ink: Color { Color(red: 0.13, green: 0.13, blue: 0.14) }
    private var inkSoft: Color { Color(red: 0.13, green: 0.13, blue: 0.14).opacity(0.62) }
    private var green: Color { Color(red: 0.09, green: 0.45, blue: 0.28) }

    var body: some View {
        VStack(spacing: 0) {
            SerratedEdge(pointsUp: false).fill(paper).frame(height: 5)
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 2) {
                    Text("AI 用量小票").font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text("CODEX × DEEPSEEK").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.1).foregroundColor(inkSoft)
                    Text("NO.0002 · " + data.stamp).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(inkSoft)
                }
                .foregroundColor(ink)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 7)

                double
                rows([("余额", "¥" + data.balance, ink, 16),
                      ("累计已花", "¥" + data.spent, ink, 11)])
                single
                rows([("今日用量", data.today + " tok", ink, 11),
                      ("本月累计", data.month + " tok", ink, 11),
                      ("缓存命中", data.cache, green, 11)])
                double
                Text("CODEX · OPENAI").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.9).foregroundColor(inkSoft)
                    .padding(.top, 1)
                rows([("5h 剩余", "\(data.codexFive)%", ink, 11),
                      ("7d 剩余", "\(data.codexWeek)%", ink, 11),
                      ("今日输出", data.codexTodayOutput + " tok", ink, 11),
                      ("输入缓存", data.codexCache, green, 11),
                      ("Credits", data.codexCredits, ink, 11)])
                double
                HStack(alignment: .firstTextBaseline) {
                    Text("合计已花").font(.system(size: 12, weight: .bold, design: .monospaced))
                    Spacer()
                    Text("¥" + data.spent).font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                .foregroundColor(ink)
                .padding(.top, 7)

                barcode.padding(.top, 9).padding(.bottom, 1)
                Text("0002 8817 4532 0011").font(.system(size: 9, design: .monospaced))
                    .tracking(1.4).foregroundColor(inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 5)
                VStack(spacing: 1) {
                    Text("付款方式 DSH 登录态 · 本机会话统计")
                        .font(.system(size: 9, design: .monospaced))
                    Text("谢谢惠顾").font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    Text("13:06:23").font(.system(size: 9, design: .monospaced))
                }
                .foregroundColor(inkSoft)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            SerratedEdge(pointsUp: true).fill(paper).frame(height: 5)
        }
        .background(paper)
        .frame(width: 300)
        .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 3)
    }

    private func rows(_ items: [(String, String, Color, CGFloat)]) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.0).font(.system(size: 11, design: .monospaced)).foregroundColor(inkSoft).fixedSize()
                    Spacer(minLength: 8)
                    Text(row.1)
                        .font(.system(size: row.3, weight: .semibold, design: .monospaced))
                        .foregroundColor(row.2).lineLimit(1).minimumScaleFactor(0.7).fixedSize()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var single: some View { Rectangle().fill(ink.opacity(0.28)).frame(height: 1) }
    private var double: some View {
        VStack(spacing: 2) {
            Rectangle().fill(ink.opacity(0.55)).frame(height: 1)
            Rectangle().fill(ink.opacity(0.55)).frame(height: 1)
        }
    }

    private var barcode: some View {
        HStack(spacing: 1.2) {
            ForEach(Array(Panel5View.bars.enumerated()), id: \.offset) { _, width in
                Rectangle().fill(ink).frame(width: width, height: 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// 撕口：一排小三角，贴在小票上下边。
struct SerratedEdge: Shape {
    var pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 6
        var x: CGFloat = 0
        if pointsUp {
            path.move(to: CGPoint(x: 0, y: rect.maxY))
            while x < rect.width {
                path.addLine(to: CGPoint(x: x + step / 2, y: rect.minY))
                path.addLine(to: CGPoint(x: x + step, y: rect.maxY))
                x += step
            }
        } else {
            path.move(to: CGPoint(x: 0, y: rect.minY))
            while x < rect.width {
                path.addLine(to: CGPoint(x: x + step / 2, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + step, y: rect.minY))
                x += step
            }
        }
        path.closeSubpath()
        return path
    }
}
