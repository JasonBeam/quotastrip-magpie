import AppKit

/// 只用于设计比较：几种「去掉进度条」的 DeepSeek 模块排布。
/// 不参与正式构建；由 Tests/render-designs.py 编译并离屏渲染。
/// 坐标与真实 DeepSeekTouchBarView 一致：flipped、y 从顶部算、300×30。
enum NoBarStyle: Int, CaseIterable {
    case numbers   // 1 纯数字：大字金额 + 百分比
    case fraction  // 2 分数式：¥9.50 / 21.11
    case columns   // 3 三列网格：余额 / 今日 / 缓存
    case badge     // 4 徽章：45% 药丸
    case sentence  // 5 一句话：余额 ¥9.50（剩 45%）
}

final class NoBarDesignView: NSView {
    static let viewWidth: CGFloat = 300
    var style: NoBarStyle = .numbers
    var snapshot: DeepSeekSnapshot?
    var phase: DeepSeekPricePhase = .offPeak

    private let labelX: CGFloat = 36
    private let contentX: CGFloat = 66
    private let amountRight: CGFloat = 234
    private let rightEdge: CGFloat = 292
    private let blue = NSColor(calibratedRed: 0.26, green: 0.48, blue: 1, alpha: 1)
    private let green = NSColor(calibratedRed: 0.35, green: 0.84, blue: 0.60, alpha: 1)
    private let dim = NSColor(white: 0.62, alpha: 1)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.viewWidth, height: 30) }

    private lazy var peakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")
    private lazy var offPeakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")

    func update(_ value: DeepSeekSnapshot) { snapshot = value; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        (phase == .peak ? peakLogo : offPeakLogo)?.draw(in: NSRect(x: 4, y: 2, width: 26, height: 26))
        guard let data = snapshot else { return }
        switch style {
        case .numbers: drawNumbers(data)
        case .fraction: drawFraction(data)
        case .columns: drawColumns(data)
        case .badge: drawBadge(data)
        case .sentence: drawSentence(data)
        }
    }

    // MARK: - 1. 纯数字

    private func drawNumbers(_ data: DeepSeekSnapshot) {
        label("余额", y: 2.5)
        label("今日", y: 17.5)
        right(money(data.balance, currency: data.currency), right: amountRight, y: 1,
              color: blue, size: 15, weight: .semibold)
        right(percentText(data), right: rightEdge, y: 1.5,
              color: percentColor(data), size: 13, weight: .bold)
        left(tokensText(data.todayTokens) + " tok", x: contentX, y: 16,
             color: NSColor(white: 0.95, alpha: 1), size: 13, weight: .semibold)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 11.5, weight: .medium)
    }

    // MARK: - 2. 分数式

    private func drawFraction(_ data: DeepSeekSnapshot) {
        label("余额", y: 2.5)
        label("今日", y: 17.5)
        let balance = money(data.balance, currency: data.currency)
        let total = money(data.startingBalance, currency: data.currency)
        right(percentText(data), right: rightEdge, y: 1.5, color: percentColor(data), size: 13, weight: .bold)
        // 从左往右读：¥9.50 / 21.11，百分比在右端。
        left(balance, x: contentX, y: 2, color: blue, size: 13, weight: .semibold)
        left("/ " + total, x: contentX + width(balance, 13, .semibold) + 4, y: 2.8,
             color: dim, size: 10.5, weight: .regular)
        left(tokensText(data.todayTokens) + " tok", x: contentX, y: 16,
             color: NSColor(white: 0.95, alpha: 1), size: 13, weight: .semibold)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 11.5, weight: .medium)
    }

    // MARK: - 3. 三列网格

    private func drawColumns(_ data: DeepSeekSnapshot) {
        right("余额", right: 150, y: 1.5, color: dim, size: 10, weight: .regular)
        right("今日", right: 224, y: 1.5, color: dim, size: 10, weight: .regular)
        right("缓存", right: rightEdge, y: 1.5, color: dim, size: 10, weight: .regular)
        right(money(data.balance, currency: data.currency), right: 150, y: 13.5,
              color: blue, size: 13, weight: .semibold)
        right(tokensText(data.todayTokens), right: 224, y: 13.5,
              color: NSColor(white: 0.95, alpha: 1), size: 13, weight: .semibold)
        right(cacheValue(data), right: rightEdge, y: 13.5, color: green, size: 13, weight: .semibold)
    }

    // MARK: - 4. 徽章

    private func drawBadge(_ data: DeepSeekSnapshot) {
        label("余额", y: 2.5)
        label("今日", y: 17.5)
        let text = percentText(data)
        let pillWidth = width(text, 12, .bold) + 12
        let rect = NSRect(x: rightEdge - pillWidth, y: 2, width: pillWidth, height: 14)
        percentColor(data).withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        right(text, right: rightEdge - 6, y: 2.5, color: percentColor(data), size: 12, weight: .bold)
        right(money(data.balance, currency: data.currency), right: rightEdge - pillWidth - 10, y: 1,
              color: blue, size: 15, weight: .semibold)
        left(tokensText(data.todayTokens) + " tok", x: contentX, y: 16,
             color: NSColor(white: 0.95, alpha: 1), size: 13, weight: .semibold)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 11.5, weight: .medium)
    }

    // MARK: - 5. 一句话

    private func drawSentence(_ data: DeepSeekSnapshot) {
        let balance = money(data.balance, currency: data.currency)
        let suffix = "（剩 " + percentText(data) + "）"
        let suffixWidth = width(suffix, 10.5, .regular)
        right(suffix, right: rightEdge, y: 2.5, color: dim, size: 10.5, weight: .regular)
        let amountRight = rightEdge - suffixWidth - 2
        right(balance, right: amountRight, y: 1, color: blue, size: 15, weight: .semibold)
        right("余额", right: amountRight - width(balance, 15, .semibold) - 8, y: 2.8,
              color: dim, size: 11, weight: .regular)
        let cache = "缓存 " + cacheValue(data)
        right(cache, right: rightEdge, y: 17.5, color: green, size: 11.5, weight: .medium)
        left("今日 " + tokensText(data.todayTokens) + " tok", x: contentX, y: 16,
             color: NSColor(white: 0.9, alpha: 1), size: 12, weight: .medium)
    }

    // MARK: - 数值与绘制辅助

    private func percent(of data: DeepSeekSnapshot) -> Int? {
        guard let balance = data.balance, let starting = data.startingBalance else { return nil }
        let b = NSDecimalNumber(decimal: balance).doubleValue
        let s = NSDecimalNumber(decimal: starting).doubleValue
        guard s > 0 else { return nil }
        return max(0, min(100, Int((b / s * 100).rounded())))
    }

    private func percentText(_ data: DeepSeekSnapshot) -> String {
        percent(of: data).map { "\($0)%" } ?? "—"
    }

    private func percentColor(_ data: DeepSeekSnapshot) -> NSColor {
        guard let value = percent(of: data) else { return NSColor(white: 0.6, alpha: 1) }
        if value <= 10 { return .systemRed }
        if value <= 25 { return .systemYellow }
        return NSColor(white: 0.95, alpha: 1)
    }

    private func cacheText(_ data: DeepSeekSnapshot) -> String {
        data.todayCacheHitPercent.map { String(format: "缓存 %.1f%%", $0) } ?? "缓存 —"
    }

    private func cacheValue(_ data: DeepSeekSnapshot) -> String {
        data.todayCacheHitPercent.map { String(format: "%.1f%%", $0) } ?? "—"
    }

    private func money(_ value: Decimal?, currency: String) -> String {
        guard let value = value else { return "—" }
        let symbol = currency.uppercased() == "USD" ? "$" : "¥"
        return symbol + String(format: "%.2f", NSDecimalNumber(decimal: value).doubleValue)
    }

    private func tokensText(_ value: Int64?) -> String {
        guard let value = value, value >= 0 else { return "—" }
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

    private func attributes(_ size: CGFloat, _ weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]
    }

    private func width(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: attributes(size, weight)).width
    }

    private func drawText(_ text: String, x: CGFloat, y: CGFloat,
                          color: NSColor, size: CGFloat, weight: NSFont.Weight) {
        var attrs = attributes(size, weight)
        attrs[.foregroundColor] = color
        NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: x, y: y))
    }

    private func right(_ text: String, right: CGFloat, y: CGFloat,
                       color: NSColor, size: CGFloat, weight: NSFont.Weight) {
        drawText(text, x: right - width(text, size, weight), y: y, color: color, size: size, weight: weight)
    }

    private func left(_ text: String, x: CGFloat, y: CGFloat,
                      color: NSColor, size: CGFloat, weight: NSFont.Weight) {
        drawText(text, x: x, y: y, color: color, size: size, weight: weight)
    }

    private func label(_ text: String, y: CGFloat) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: dim,
        ]
        attrs[.foregroundColor] = dim
        NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: labelX, y: y))
    }
}
