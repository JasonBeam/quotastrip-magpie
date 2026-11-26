import AppKit

/// 设计评审 B：仪表 / 刻度隐喻（Touch Bar 右半 300×30，透明底）。
///
/// 三个变体都用「刻度线 / 分段格 / 指针位移」表达余额还剩多少，不写剩余百分比，
/// 也不画圆角 pill 进度条。只用于评审，不参与正式构建；由
/// Tests/render-tb-design-b.py 离屏渲染并与真实 QuotaView 拼成对照表。
///
/// 合并 item 几何：Codex 0–300，3pt 黑缝，DeepSeek 303–603；各 300×30。
/// 列：logo 4,2,26,26 / 标签 36 / 内容 66 / 右边界 292。
/// 行：row1 0.5，row2 15.5，均以 13pt bold 的 baseline 对齐。
enum TBStyleB: Int, CaseIterable {
    case fuel       // 1 精细油表：17 根刻度 + 菱形指针；今日 / 累计已花
    case segments   // 2 二十格电平梯：分段格 + 近 7 日柱状点阵
    case aviation   // 3 航空刻度：21 根细刻度 + 红/琥珀告警区 + T 形指针 + 缓存小表
}

final class TBDesignBView: NSView {
    static let viewWidth: CGFloat = 300
    static let viewHeight: CGFloat = 30

    var style: TBStyleB = .fuel
    var snapshot: DeepSeekSnapshot?
    var phase: DeepSeekPricePhase = .offPeak

    /// A 变体行 2 右端的第二种读法：累计已花（默认）或缓存命中率（与现役同信息）。
    enum TBFuelTail { case spent, cache }
    var fuelTail: TBFuelTail = .spent

    /// 近 7 日每日 token（百万，旧→新）。0 表示当天没有记录，只留一条槽位，不画成有数据。
    var weekTokensMillions: [Double] = [8.97, 106.5, 103.1, 6.77, 3.57, 0, 0]
    var weekTodayIndex: Int = 4

    // MARK: - 审计数据结构（渲染脚本读取，用于越界 / 碰撞 / 指针映射检查）

    struct GaugeReport {
        let name: String
        let scaleX: CGFloat
        let scaleWidth: CGFloat
        let needleX: CGFloat?
        let ratio: Double?
        let lit: Int
        let total: Int
    }

    private(set) var textRuns: [(String, NSRect)] = []
    private(set) var marks: [(String, NSRect)] = []
    private(set) var reports: [GaugeReport] = []

    // MARK: - 几何

    private let labelX: CGFloat = 36
    private let contentX: CGFloat = 66
    private let rightEdge: CGFloat = 292
    private let row1: CGFloat = 0.5
    private let row2: CGFloat = 15.5

    /// 主仪表统一 66…214（宽 148）；B 的分段梯 66…202.1。
    private let gaugeEnd: CGFloat = 214
    private let gaugeWidth: CGFloat = 148

    // MARK: - 颜色（黑底上的三段状态色：正常 / 偏低 / 告警）

    private let blue = NSColor(calibratedRed: 0.26, green: 0.48, blue: 1.00, alpha: 1)
    private let green = NSColor(calibratedRed: 0.36, green: 0.83, blue: 0.64, alpha: 1)
    private let amber = NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.25, alpha: 1)
    private let red = NSColor(calibratedRed: 1.00, green: 0.34, blue: 0.30, alpha: 1)
    private let bright = NSColor(white: 0.95, alpha: 1)
    private let labelColor = NSColor(white: 0.78, alpha: 1)
    private let dim = NSColor(white: 0.60, alpha: 1)
    private let faint = NSColor(white: 0.30, alpha: 1)
    private let railColor = NSColor(white: 0.26, alpha: 1)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.viewWidth, height: Self.viewHeight)
    }

    private lazy var peakLogo: NSImage? = NSImage(
        contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")
    private lazy var offPeakLogo: NSImage? = NSImage(
        contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")

    func update(_ value: DeepSeekSnapshot) {
        snapshot = value
        needsDisplay = true
    }

    // MARK: - 数据派生

    /// 余额占账户累计（余额 + 已花）的比例；分母缺失或 ≤0 时返回 nil——
    /// 宁可不画指针，也不把「未知」画成 0%。
    func remainingRatio() -> Double? {
        guard let balance = snapshot?.balance,
              let starting = snapshot?.startingBalance,
              !balance.isNaN, !starting.isNaN else { return nil }
        let b = NSDecimalNumber(decimal: balance).doubleValue
        let s = NSDecimalNumber(decimal: starting).doubleValue
        guard b.isFinite, s.isFinite, s > 0, b >= 0 else { return nil }
        return min(1, max(0, b / s))
    }

    private func stateColor(_ ratio: Double) -> NSColor {
        if ratio <= 0.10 { return red }
        if ratio <= 0.25 { return amber }
        return blue
    }

    // MARK: - 绘制入口

    override func draw(_ dirtyRect: NSRect) {
        textRuns = []
        marks = []
        reports = []

        (phase == .peak ? peakLogo : offPeakLogo)?.draw(
            in: NSRect(x: 4, y: 2, width: 26, height: 26))

        guard let data = snapshot else {
            text("等待 DSH 数据…", x: labelX, y: 8, size: 11.5, weight: .regular, color: dim)
            return
        }
        switch style {
        case .fuel: drawFuel(data)
        case .segments: drawSegments(data)
        case .aviation: drawAviation(data)
        }
    }

    // MARK: - A 精细油表

    private func drawFuel(_ data: DeepSeekSnapshot) {
        let ratio = remainingRatio()
        label("余额", row: row1)
        amount(money(data.balance, data.currency), right: rightEdge, row: row1,
               maxWidth: rightEdge - gaugeEnd - 12,
               color: ratio.map(stateColor) ?? bright)
        fuelGauge(x: contentX, width: gaugeWidth, ratio: ratio)

        label("今日", row: row2)
        let tailStart: CGFloat
        switch fuelTail {
        case .spent: tailStart = spentTail(data)
        case .cache: tailStart = cacheTail(data)
        }
        tokensRow(data, maxWidth: tailStart - 12 - contentX)
    }

    /// 17 根刻度：9 根主刻度 18.5pt 一根，8 根半刻度 9.25pt 一根；
    /// 指针是 1.6pt 竖杆 + 4.6pt 菱形头，落在精确比例上。
    private func fuelGauge(x: CGFloat, width: CGFloat, ratio: Double?) {
        let bottom: CGFloat = 13.6
        let step = width / 8
        fill(NSRect(x: x, y: bottom, width: width, height: 1), railColor, "fuel rail")

        for i in 0...8 {
            tick(x + CGFloat(i) * step, top: 6.2, bottom: bottom, color: faint, tag: "fuel major")
        }
        for i in 0..<8 {
            tick(x + (CGFloat(i) + 0.5) * step, top: 9.4, bottom: bottom, color: faint, tag: "fuel minor")
        }

        guard let r = ratio else { return }
        let nx = x + CGFloat(r) * width
        let color = stateColor(r)
        var lit = 0
        for i in 0...8 where x + CGFloat(i) * step <= nx + 0.01 {
            tick(x + CGFloat(i) * step, top: 6.2, bottom: bottom, color: color, tag: "fuel major lit")
            lit += 1
        }
        for i in 0..<8 where x + (CGFloat(i) + 0.5) * step <= nx + 0.01 {
            tick(x + (CGFloat(i) + 0.5) * step, top: 9.4, bottom: bottom,
                 color: color.withAlphaComponent(0.90), tag: "fuel minor lit")
            lit += 1
        }

        fill(NSRect(x: nx - 0.8, y: 5.7, width: 1.6, height: 8.7), bright, "fuel needle")
        let head = NSBezierPath()
        head.move(to: NSPoint(x: nx, y: 1.5))
        head.line(to: NSPoint(x: nx + 2.3, y: 3.75))
        head.line(to: NSPoint(x: nx, y: 6.0))
        head.line(to: NSPoint(x: nx - 2.3, y: 3.75))
        head.close()
        bright.setFill()
        head.fill()
        marks.append(("fuel needle head", NSRect(x: nx - 2.3, y: 1.5, width: 4.6, height: 4.5)))
        reports.append(GaugeReport(name: "fuel", scaleX: x, scaleWidth: width,
                                   needleX: nx, ratio: r, lit: lit, total: 17))
    }

    /// 行 2 右端：累计已花（来自 账户累计 − 余额），标签压暗、数值提亮。
    /// 用「累计」而不是「已花」，避免被读成今日花费。
    @discardableResult
    private func spentTail(_ data: DeepSeekSnapshot) -> CGFloat {
        let value = spentText(data)
        let valueW = textWidth(value, 10.5, .regular)
        let valueX = rightEdge - valueW
        text(value, x: valueX, y: yFor(10.5, .regular, row2), size: 10.5, weight: .regular,
             color: NSColor(white: 0.84, alpha: 1))

        let labelText = "累计"
        let labelW = textWidth(labelText, 10.5, .regular)
        let labelX = valueX - 4 - labelW
        text(labelText, x: labelX, y: yFor(10.5, .regular, row2), size: 10.5,
             weight: .regular, color: dim)
        return labelX
    }

    /// 行 2 右端的第二种读法：「缓存 78.6%」。它和「累计 ¥20.16」占同一槽位
    ///（229…292），所以换成缓存后仍然不挤，信息量与现役视图一致。
    @discardableResult
    private func cacheTail(_ data: DeepSeekSnapshot) -> CGFloat {
        let value = Self.cacheText(data.todayCacheHitPercent)
        let valueW = textWidth(value, 10.5, .medium)
        let valueX = rightEdge - valueW
        let color: NSColor = data.todayCacheHitPercent == nil ? dim : green
        text(value, x: valueX, y: yFor(10.5, .medium, row2), size: 10.5,
             weight: .medium, color: color)

        let labelText = "缓存"
        let labelW = textWidth(labelText, 10.5, .regular)
        let labelX = valueX - 4 - labelW
        text(labelText, x: labelX, y: yFor(10.5, .regular, row2), size: 10.5,
             weight: .regular, color: dim)
        return labelX
    }

    // MARK: - B 二十格电平梯

    private func drawSegments(_ data: DeepSeekSnapshot) {
        let ratio = remainingRatio()
        label("余额", row: row1)
        amount(money(data.balance, data.currency), right: rightEdge, row: row1,
               maxWidth: rightEdge - 202.1 - 12,
               color: ratio.map(stateColor) ?? bright)
        segmentLadder(x: contentX, ratio: ratio)

        label("今日", row: row2)
        let weekLabelX = weekStemX - 4 - textWidth("近7日", 10.5, .regular)
        tokensRow(data, maxWidth: weekLabelX - 12 - contentX)
        weekSpectrum(labelX: weekLabelX)
    }

    private let ladderCells = 20
    private let ladderCellWidth: CGFloat = 5.0
    private let ladderGap: CGFloat = 1.9

    /// 20 格、5pt 一格：每格 5% 分辨率，点亮宽度取精确小数，
    /// 所以 71.66% 会留下第 15 格 1.66pt 的余量，而不是四舍五入到 75%。
    private func segmentLadder(x: CGFloat, ratio: Double?) {
        let pitch = ladderCellWidth + ladderGap
        let totalW = CGFloat(ladderCells) * ladderCellWidth
            + CGFloat(ladderCells - 1) * ladderGap
        let top: CGFloat = 6.0
        let height: CGFloat = 7.2

        fill(NSRect(x: x, y: 13.9, width: totalW, height: 1), railColor, "segments rail")

        let color = ratio.map(stateColor) ?? faint
        var lit = 0
        for i in 0..<ladderCells {
            let cellX = x + CGFloat(i) * pitch
            fill(NSRect(x: cellX, y: top, width: ladderCellWidth, height: height),
                 faint.withAlphaComponent(0.55), "segments cell empty")
            guard let r = ratio else { continue }
            let fraction = min(1, max(0, r * Double(ladderCells) - Double(i)))
            if fraction > 0.0001 {
                fill(NSRect(x: cellX, y: top, width: ladderCellWidth * CGFloat(fraction),
                            height: height), color, "segments cell lit")
                lit += 1
            }
        }
        reports.append(GaugeReport(name: "segments", scaleX: x, scaleWidth: totalW,
                                   needleX: ratio.map { x + CGFloat($0) * totalW },
                                   ratio: ratio, lit: lit, total: ladderCells))
    }

    private let weekStemX: CGFloat = 216
    private let weekStemPitch: CGFloat = 12
    private let weekStemWidth: CGFloat = 4
    private let weekBaseline: CGFloat = 28.1

    /// 近 7 日：柱宽 4、步进 12，高度按 log 压缩，
    /// 今日提亮，没有记录的 0 值只留 1.2pt 淡槽位。
    private func weekSpectrum(labelX: CGFloat) {
        let values = weekTokensMillions
        guard values.count == 7 else { return }
        fill(NSRect(x: weekStemX, y: weekBaseline, width: 76, height: 0.8),
             railColor, "week baseline")

        let peak = max(values.max() ?? 1, 1)
        for i in 0..<7 {
            let value = values[i]
            let height: CGFloat
            let color: NSColor
            if value <= 0 {
                height = 1.2
                color = faint
            } else {
                // 7 日数据跨 30 倍，sqrt 会把今日压到 2.0pt、与 0 值空槽几乎同高；
                // 改用 log(1+v)/log(1+peak)，今日仍明显高于空槽。
                let normalized = log(1 + value) / log(1 + peak)
                height = max(3.4, 12.0 * CGFloat(normalized))
                if i == weekTodayIndex {
                    color = bright
                } else if i > weekTodayIndex {
                    color = NSColor(white: 0.34, alpha: 1)
                } else {
                    color = blue.withAlphaComponent(0.62)
                }
            }
            fill(NSRect(x: weekStemX + CGFloat(i) * weekStemPitch,
                        y: weekBaseline - height,
                        width: weekStemWidth, height: height), color, "week stem")
        }

        text("近7日", x: labelX, y: yFor(10.5, .regular, row2), size: 10.5,
             weight: .regular, color: dim)
    }

    // MARK: - C 航空刻度 + 缓存小表

    private func drawAviation(_ data: DeepSeekSnapshot) {
        let ratio = remainingRatio()
        label("余额", row: row1)
        amount(money(data.balance, data.currency), right: rightEdge, row: row1,
               maxWidth: rightEdge - gaugeEnd - 12,
               color: ratio.map(stateColor) ?? bright)
        aviationGauge(x: contentX, width: gaugeWidth, ratio: ratio)

        label("今日", row: row2)
        let percentText = Self.cacheText(snapshot?.todayCacheHitPercent)
        let percentWidth = textWidth(percentText, 10.5, .medium)
        let percentX = rightEdge - percentWidth
        let meterX = percentX - 6 - cacheMeterWidth
        let cacheLabelX = meterX - 4 - textWidth("缓存", 10, .regular)
        tokensRow(data, maxWidth: cacheLabelX - 12 - contentX)
        cacheMeter(x: meterX, labelX: cacheLabelX, percent: percentText, percentX: percentX)
    }

    /// 21 根刻度，步进 5%：低端 0–10% 红、10–25% 琥珀，其余白；
    /// 指针是 2pt 竖杆 + 5.4pt 顶帽，跨过指针的刻度提亮。
    private func aviationGauge(x: CGFloat, width: CGFloat, ratio: Double?) {
        let bottom: CGFloat = 13.6
        let count = 20
        let step = width / CGFloat(count)
        fill(NSRect(x: x, y: bottom, width: width, height: 1), railColor, "aviation rail")

        for i in 0...count {
            let tx = x + CGFloat(i) * step
            let top: CGFloat = (i % 5 == 0) ? 5.6 : 9.2
            tick(tx, top: top, bottom: bottom, color: aviationZoneColor(i, count: count, alpha: 0.42),
                 tag: "aviation tick")
        }

        guard let r = ratio else { return }
        let nx = x + CGFloat(r) * width
        var lit = 0
        for i in 0...count where x + CGFloat(i) * step <= nx + 0.01 {
            let top: CGFloat = (i % 5 == 0) ? 5.6 : 9.2
            tick(x + CGFloat(i) * step, top: top, bottom: bottom,
                 color: aviationZoneColor(i, count: count, alpha: 1.0), tag: "aviation lit")
            lit += 1
        }

        let color = stateColor(r)
        fill(NSRect(x: nx - 1.0, y: 3.4, width: 2.0, height: 11.2), color, "aviation needle")
        fill(NSRect(x: nx - 2.7, y: 2.6, width: 5.4, height: 1.5), color, "aviation needle cap")
        reports.append(GaugeReport(name: "aviation", scaleX: x, scaleWidth: width,
                                   needleX: nx, ratio: r, lit: lit, total: 21))
    }

    private func aviationZoneColor(_ index: Int, count: Int, alpha: CGFloat) -> NSColor {
        let fraction = CGFloat(index) / CGFloat(count)
        if fraction <= 0.10 + 0.0001 { return red.withAlphaComponent(alpha) }
        if fraction <= 0.25 + 0.0001 { return amber.withAlphaComponent(alpha) }
        return NSColor(white: 0.90, alpha: alpha)
    }

    private let cacheMeterWidth: CGFloat = 32

    private static func cacheText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", min(100, max(0, value)))
    }

    /// 缓存命中率小表：6 根刻度（0/20/40/60/80/100），绿色指针 + 绿色百分比。
    /// 百分比右对齐 292，小表贴在百分比左侧 6pt，整簇一起右锚。
    private func cacheMeter(x: CGFloat, labelX: CGFloat, percent: String, percentX: CGFloat) {
        let top: CGFloat = 19.4
        let bottom: CGFloat = 24.8
        let step = cacheMeterWidth / 5

        text("缓存", x: labelX, y: yFor(10, .regular, row2), size: 10,
             weight: .regular, color: dim)

        for i in 0...5 {
            tick(x + CGFloat(i) * step, top: top, bottom: bottom,
                 color: faint, tag: "cache tick")
        }

        var percentColor = dim
        if let value = snapshot?.todayCacheHitPercent, value.isFinite {
            percentColor = green
            let r = min(100, max(0, value)) / 100
            let nx = x + CGFloat(r) * cacheMeterWidth
            var lit = 0
            for i in 0...5 where x + CGFloat(i) * step <= nx + 0.01 {
                tick(x + CGFloat(i) * step, top: top, bottom: bottom,
                     color: green, tag: "cache lit")
                lit += 1
            }
            fill(NSRect(x: nx - 0.8, y: top - 1.2, width: 1.6,
                        height: (bottom - top) + 2.4), green, "cache needle")
            reports.append(GaugeReport(name: "cache", scaleX: x,
                                       scaleWidth: cacheMeterWidth, needleX: nx,
                                       ratio: r, lit: lit, total: 6))
        }

        text(percent, x: percentX, y: yFor(10.5, .medium, row2),
             size: 10.5, weight: .medium, color: percentColor)
    }

    // MARK: - 公共文字

    private lazy var referenceAscender: CGFloat = NSFont.monospacedDigitSystemFont(
        ofSize: 13, weight: .bold).ascender

    private func yFor(_ size: CGFloat, _ weight: NSFont.Weight, _ row: CGFloat) -> CGFloat {
        row + referenceAscender
            - NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight).ascender
    }

    private func textWidth(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func label(_ string: String, row: CGFloat) {
        text(string, x: labelX, y: yFor(11.5, .medium, row), size: 11.5,
             weight: .medium, color: labelColor)
    }

    /// 余额数字：右对齐到 292，宽度不够时逐级缩字号（正常 K/M 格式化后不会触发）。
    private func amount(_ string: String, right: CGFloat, row: CGFloat,
                        maxWidth: CGFloat, color: NSColor) {
        let sizes: [CGFloat] = [13, 12, 11, 10.5]
        let size = sizes.first { textWidth(string, $0, .semibold) <= maxWidth } ?? 10.5
        let width = textWidth(string, size, .semibold)
        text(string, x: right - width, y: yFor(size, .semibold, row), size: size,
             weight: .semibold, color: color)
    }

    private func tokensRow(_ data: DeepSeekSnapshot, maxWidth: CGFloat) {
        let string = data.todayTokens.map { tokensText($0) + " tok" } ?? "—"
        let sizes: [CGFloat] = [13, 12, 11, 10.5]
        let size = sizes.first { textWidth(string, $0, .semibold) <= maxWidth } ?? 10.5
        text(string, x: contentX, y: yFor(size, .semibold, row2), size: size,
             weight: .semibold, color: bright)
    }

    // MARK: - 数字格式化（与现役视图同规则，避免出现超宽读数）

    private func money(_ value: Decimal?, _ currency: String) -> String {
        guard let value, !value.isNaN else { return "—" }
        let symbol: String
        switch currency.uppercased() {
        case "CNY": symbol = "¥"
        case "USD": symbol = "$"
        default: symbol = currency.isEmpty ? "¤" : currency
        }
        let magnitude = NSDecimalNumber(decimal: value).doubleValue
        if magnitude >= 1_000_000 { return symbol + String(format: "%.2fM", magnitude / 1_000_000) }
        if magnitude >= 100_000 { return symbol + String(format: "%.1fK", magnitude / 1_000) }
        if magnitude >= 1_000 { return symbol + String(format: "%.2fK", magnitude / 1_000) }
        return symbol + String(format: "%.2f", magnitude)
    }

    private func spentText(_ data: DeepSeekSnapshot) -> String {
        guard let balance = data.balance, let starting = data.startingBalance,
              !balance.isNaN, !starting.isNaN else { return "—" }
        return money(starting - balance, data.currency)
    }

    private func tokensText(_ value: Int64) -> String {
        if value >= 999_995_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 999_995 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    // MARK: - 低层绘制（全部记入审计）

    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      weight: NSFont.Weight, color: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        let width = (string as NSString).size(withAttributes: [.font: font]).width
        textRuns.append((string, NSRect(x: x, y: y, width: width, height: font.ascender)))
    }

    private func fill(_ rect: NSRect, _ color: NSColor, _ tag: String) {
        color.setFill()
        NSBezierPath(rect: rect).fill()
        marks.append((tag, rect))
    }

    private func tick(_ centerX: CGFloat, top: CGFloat, bottom: CGFloat,
                      color: NSColor, tag: String) {
        fill(NSRect(x: centerX - 0.5, y: top, width: 1, height: bottom - top), color, tag)
    }
}
