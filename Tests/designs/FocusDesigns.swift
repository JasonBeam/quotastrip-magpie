import AppKit

/// 第二轮设计比较：完全无进度条，从「DeepSeek 用户真正盯的数据」出发的 5 种排布。
/// 只用于设计评审，不参与正式构建；由 Tests/render-designs2.py 编译离屏渲染。
/// 与真实 DeepSeekTouchBarView 同几何：flipped、y 从顶部算、300×30。
enum FocusStyle: Int, CaseIterable {
    case hero      // 6 余额当家：大字金额 + 一行副指标
    case peak      // 7 峰谷价：闲时/高峰徽章 + 余额
    case today     // 8 今日用量当家：大字 token + 余额
    case lights    // 9 状态灯：两个色点 + 读数
    case countdown // 10 倒计时：距下次调价还有多久
}

final class FocusDesignView: NSView {
    static let viewWidth: CGFloat = 300
    var style: FocusStyle = .hero
    var snapshot: DeepSeekSnapshot?
    var phase: DeepSeekPricePhase = .offPeak
    /// 倒计时用，测试里固定成可复现的秒数。
    var countdownOverride: TimeInterval?

    private let labelX: CGFloat = 36
    private let contentX: CGFloat = 66
    private let valueRight: CGFloat = 234
    private let rightEdge: CGFloat = 292
    private let blue = NSColor(calibratedRed: 0.26, green: 0.48, blue: 1, alpha: 1)
    private let green = NSColor(calibratedRed: 0.35, green: 0.84, blue: 0.60, alpha: 1)
    private let dim = NSColor(white: 0.62, alpha: 1)
    private let bright = NSColor(white: 0.95, alpha: 1)

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
        case .hero: drawHero(data)
        case .peak: drawPeak(data)
        case .today: drawToday(data)
        case .lights: drawLights(data)
        case .countdown: drawCountdown(data)
        }
    }

    // MARK: - 6. 余额当家

    private func drawHero(_ data: DeepSeekSnapshot) {
        drawText(money(data.balance, currency: data.currency), x: labelX, y: -0.5,
                 color: blue, size: 15, weight: .bold)
        right(percentText(data), right: rightEdge, y: 3, color: dim, size: 11.5, weight: .medium)
        left("今日 " + tokensText(data.todayTokens) + " tok", x: labelX, y: 17.5,
             color: dim, size: 10.5, weight: .regular)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 11, weight: .medium)
    }

    // MARK: - 7. 峰谷价徽章

    private func drawPeak(_ data: DeepSeekSnapshot) {
        let isPeak = phase == .peak
        let text = isPeak ? "高峰 原价 x1" : "闲时 5 折"
        let tint = isPeak ? NSColor.systemOrange : blue
        let pillWidth = width(text, 10.5, .semibold) + 12
        let rect = NSRect(x: contentX, y: 2, width: pillWidth, height: 14)
        tint.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        drawText(text, x: contentX + 6, y: 3.5, color: tint, size: 10.5, weight: .semibold)
        right(money(data.balance, currency: data.currency), right: rightEdge, y: 0,
              color: blue, size: 14, weight: .semibold)
        left(tokensText(data.todayTokens) + " tok", x: contentX, y: 17.5,
             color: bright, size: 11.5, weight: .medium)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 11, weight: .medium)
    }

    // MARK: - 8. 今日用量当家

    private func drawToday(_ data: DeepSeekSnapshot) {
        let tokens = tokensText(data.todayTokens)
        drawText(tokens, x: contentX, y: -0.5, color: bright, size: 15, weight: .bold)
        let tokensWidth = width(tokens, 15, .bold)
        drawText(" tok", x: contentX + tokensWidth + 2, y: 8, color: dim, size: 9.5, weight: .regular)
        right(cacheText(data), right: rightEdge, y: 4, color: green, size: 11.5, weight: .medium)
        let balance = money(data.balance, currency: data.currency)
        drawText("余额 " + balance, x: contentX, y: 17.5, color: dim, size: 11, weight: .regular)
        right(percentText(data), right: rightEdge, y: 17.5, color: dim, size: 11, weight: .regular)
    }

    // MARK: - 9. 状态灯

    private func drawLights(_ data: DeepSeekSnapshot) {
        let percent = percentValue(data)
        let balanceColor: NSColor = {
            guard let percent else { return NSColor(white: 0.6, alpha: 1) }
            if percent <= 10 { return .systemRed }
            if percent <= 25 { return .systemYellow }
            return blue
        }()
        dot(x: contentX, y: 6.5, color: balanceColor)
        drawText(money(data.balance, currency: data.currency), x: contentX + 11, y: 1.5,
                 color: balanceColor, size: 13.5, weight: .semibold)
        right(percentText(data), right: rightEdge, y: 4, color: dim, size: 11, weight: .medium)

        dot(x: contentX, y: 22, color: green)
        drawText(tokensText(data.todayTokens) + " tok", x: contentX + 11, y: 17,
                 color: bright, size: 11, weight: .medium)
        right(cacheText(data), right: rightEdge, y: 17, color: green, size: 11, weight: .medium)
    }

    // MARK: - 10. 距下次调价

    private func drawCountdown(_ data: DeepSeekSnapshot) {
        let isPeak = phase == .peak
        let tint = isPeak ? NSColor.systemOrange : green
        let seconds = countdownOverride ?? DeepSeekPricingClock.secondsUntilNextBoundary(from: Date()) ?? 0
        let clock = String(format: "%02d:%02d", Int(seconds) / 3600, (Int(seconds) % 3600) / 60)
        drawText(isPeak ? "高峰" : "闲时", x: labelX, y: 4, color: dim, size: 10.5, weight: .regular)
        drawText(clock, x: contentX, y: 0.5, color: tint, size: 14, weight: .semibold)
        right(money(data.balance, currency: data.currency), right: rightEdge, y: 2,
              color: blue, size: 13, weight: .semibold)
        left(tokensText(data.todayTokens) + " tok", x: contentX, y: 17.5,
             color: bright, size: 11, weight: .medium)
        right(cacheText(data), right: rightEdge, y: 17.5, color: green, size: 11, weight: .medium)
    }

    // MARK: - 数值与绘制辅助

    private func dot(x: CGFloat, y: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 5, height: 5)).fill()
    }

    private func percentValue(_ data: DeepSeekSnapshot) -> Int? {
        guard let balance = data.balance, let starting = data.startingBalance else { return nil }
        let b = NSDecimalNumber(decimal: balance).doubleValue
        let s = NSDecimalNumber(decimal: starting).doubleValue
        guard s > 0 else { return nil }
        return max(0, min(100, Int((b / s * 100).rounded())))
    }

    private func percentText(_ data: DeepSeekSnapshot) -> String {
        percentValue(data).map { "剩 \($0)%" } ?? "剩 —"
    }

    private func cacheText(_ data: DeepSeekSnapshot) -> String {
        data.todayCacheHitPercent.map { String(format: "缓存 %.1f%%", $0) } ?? "缓存 —"
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
}
