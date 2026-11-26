import AppKit

/// 设计评审用：DeepSeek 模块在 Touch Bar 上的三个新排布（300×30，无进度条、无百分比）。
/// 不参与正式构建；Tests/render-tb-v2.py 会把它和真实 QuotaView 并排渲染。
enum TBV2Style: Int, CaseIterable {
    case spark      // 1 余额 + 近 7 日迷你柱
    case spent      // 2 余额 + 累计已花
    case todaySpark // 3 今日用量当家 + 迷你柱
}

final class TBV2View: NSView {
    static let viewWidth: CGFloat = 300
    var style: TBV2Style = .spark
    var snapshot: DeepSeekSnapshot?

    private let labelX: CGFloat = 36
    private let contentX: CGFloat = 66
    private let rightEdge: CGFloat = 292
    private let blue = NSColor(calibratedRed: 0.26, green: 0.48, blue: 1, alpha: 1)
    private let green = NSColor(calibratedRed: 0.35, green: 0.84, blue: 0.60, alpha: 1)
    private let dim = NSColor(white: 0.62, alpha: 1)
    private let bright = NSColor(white: 0.95, alpha: 1)

    /// 近 7 日（11-12 … 11-18）真实 DeepSeek token；后两天还没有记录。
    var weekTokens: [Double] = [8_969_898, 106_515_375, 103_088_154, 6_774_405, 3_570_277, 0, 0]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.viewWidth, height: 30) }

    private lazy var peakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")
    private lazy var offPeakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")
    var phase: DeepSeekPricePhase = .offPeak

    func update(_ value: DeepSeekSnapshot) { snapshot = value; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        (phase == .peak ? peakLogo : offPeakLogo)?.draw(in: NSRect(x: 4, y: 2, width: 26, height: 26))
        guard let data = snapshot else { return }
        switch style {
        case .spark: drawSpark(data)
        case .spent: drawSpent(data)
        case .todaySpark: drawTodaySpark(data)
        }
    }

    // MARK: - 1 余额 + 迷你柱

    private func drawSpark(_ data: DeepSeekSnapshot) {
        balance(data, size: 15, x: contentX, y: -0.5)
        spark(x: 160, right: rightEdge, top: 3, bottom: 14)
        left("今日 " + tokensText(data.todayTokens) + " tok", x: contentX, y: 17.5, color: dim, size: 10.5)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 10.5)
    }

    // MARK: - 2 余额 + 累计已花

    private func drawSpent(_ data: DeepSeekSnapshot) {
        balance(data, size: 15, x: contentX, y: -0.5)
        right(spentText(data), right: rightEdge, y: 3, color: dim, size: 10)
        left("今日 " + tokensText(data.todayTokens) + " tok", x: contentX, y: 17.5, color: dim, size: 10.5)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 10.5)
    }

    // MARK: - 3 今日用量当家

    private func drawTodaySpark(_ data: DeepSeekSnapshot) {
        let tokens = tokensText(data.todayTokens)
        left(tokens, x: contentX, y: -0.5, color: bright, size: 15, weight: .bold)
        left(" tok", x: contentX + width(tokens, 15, .bold) + 2, y: 8, color: dim, size: 9)
        spark(x: 196, right: rightEdge, top: 3, bottom: 13)
        left("余额 " + money(data.balance, currency: data.currency), x: contentX, y: 17.5,
             color: dim, size: 10.5)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 10.5)
    }

    // MARK: - 部件

    private func balance(_ data: DeepSeekSnapshot, size: CGFloat, x: CGFloat, y: CGFloat) {
        left(money(data.balance, currency: data.currency), x: x, y: y, color: blue, size: size, weight: .semibold)
    }

    /// 迷你折线：社区里 MoniThor / Runic 的菜单栏迷你图都是折线而不是柱子，
    /// 7 个点从 8.9M 到 106M 时折线比小柱子更容易看出「这两天暴涨」。
    private func spark(x: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        let values = weekTokens
        guard values.count > 1 else { return }
        let peak = max(values.max() ?? 1, 1)
        let step = (right - x) / CGFloat(values.count - 1)
        let maxHeight = bottom - top
        let points = values.enumerated().map { index, value -> NSPoint in
            let ratio = value <= 0 ? 0 : CGFloat((value / peak).squareRoot())
            return NSPoint(x: x + CGFloat(index) * step, y: bottom - max(1, maxHeight * ratio))
        }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        blue.withAlphaComponent(0.9).setStroke()
        path.stroke()
        if let last = points.last {
            blue.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)).fill()
        }
    }

    private func spentText(_ data: DeepSeekSnapshot) -> String {
        guard let balance = data.balance, let starting = data.startingBalance else { return "累计已花 —" }
        return "累计已花 " + money(starting - balance, currency: data.currency)
    }

    private func money(_ value: Decimal?, currency: String) -> String {
        guard let value else { return "—" }
        let symbol = currency.uppercased() == "USD" ? "$" : "¥"
        return symbol + String(format: "%.2f", NSDecimalNumber(decimal: value).doubleValue)
    }

    private func tokensText(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        let n = Double(value)
        if n >= 999_995_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 999_995 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 {
            let k = n / 1_000
            if k >= 999.95 { return String(format: "%.2fM", n / 1_000_000) }
            return String(format: "%.1fK", k)
        }
        return String(value)
    }

    private func cacheText(_ data: DeepSeekSnapshot) -> String {
        data.todayCacheHitPercent.map { String(format: "缓存 %.1f%%", $0) } ?? "缓存 —"
    }

    private func attributes(_ size: CGFloat, _ weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]
    }

    private func width(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: attributes(size, weight)).width
    }

    private func left(_ text: String, x: CGFloat, y: CGFloat, color: NSColor,
                      size: CGFloat, weight: NSFont.Weight = .medium) {
        var attrs = attributes(size, weight)
        attrs[.foregroundColor] = color
        NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: x, y: y))
    }

    private func right(_ text: String, right: CGFloat, y: CGFloat, color: NSColor,
                       size: CGFloat, weight: NSFont.Weight = .medium) {
        left(text, x: right - width(text, size, weight), y: y, color: color, size: size, weight: weight)
    }
}
