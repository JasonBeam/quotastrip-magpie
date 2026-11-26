import AppKit

/// 第四轮设计：去掉「剩余百分比」。只用真实可得的数据：
///   现在就有：余额、官方累计已花(totalCosts)、今日 token、缓存命中、近几日 token、峰谷时段
///   需另行记录才能算：今日花费(按 totalCosts 当日首读做基线)、续航天数
/// 仅用于设计评审，不参与正式构建；由 Tests/render-designs4.py 离屏渲染。

// MARK: - Touch Bar（300×30，flipped，y 从顶部算）

enum TB4Style: Int, CaseIterable {
    case ledger       // 1 账本：余额 + 累计已花（全部现成数据）
    case trend        // 2 趋势：今日 token 对比日均
    case spend        // 3 今日花费（需记录基线）
    case phaseLedger  // 4 时段徽章 + 余额 + 已花
    case columns      // 5 三栏：余额 | 累计已花 | 缓存
}

final class TB4View: NSView {
    static let viewWidth: CGFloat = 300
    var style: TB4Style = .ledger
    var snapshot: DeepSeekSnapshot?
    var phase: DeepSeekPricePhase = .offPeak
    var totalSpent = "19.25"
    var todaySpend = "0.42"          // 示意值：真实需要 totalCosts 当日基线
    var weekAvgTokens = "72.9M"   // 已完整的前 3 天均值（真实：8.97M/106.5M/103.1M）
    var countdown: TimeInterval = 5025

    private let labelX: CGFloat = 36
    private let rightEdge: CGFloat = 292
    private let blue = NSColor(calibratedRed: 0.26, green: 0.48, blue: 1, alpha: 1)
    private let green = NSColor(calibratedRed: 0.35, green: 0.84, blue: 0.60, alpha: 1)
    private let orange = NSColor.systemOrange
    private let dim = NSColor(white: 0.62, alpha: 1)
    private let bright = NSColor(white: 0.95, alpha: 1)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.viewWidth, height: 30) }

    private lazy var peakLogo = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")
    private lazy var offPeakLogo = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")

    func update(_ value: DeepSeekSnapshot) { snapshot = value; needsDisplay = true }

    var drawn: [(String, NSRect)] = []

    override func draw(_ dirtyRect: NSRect) {
        drawn = []
        (phase == .peak ? peakLogo : offPeakLogo)?.draw(in: NSRect(x: 4, y: 2, width: 26, height: 26))
        guard let d = snapshot else { return }
        switch style {
        case .ledger: drawLedger(d)
        case .trend: drawTrend(d)
        case .spend: drawSpend(d)
        case .phaseLedger: drawPhaseLedger(d)
        case .columns: drawColumns(d)
        }
    }

    /// 没有「本次充值额」，低余额只能按绝对金额提示：≤¥5 红、≤¥15 黄。阈值是设计假设，上线前需用户定。
    private func balanceColor(_ d: DeepSeekSnapshot) -> NSColor {
        guard let b = d.balance else { return dim }
        let v = NSDecimalNumber(decimal: b).doubleValue
        if v <= 5 { return .systemRed }
        if v <= 15 { return .systemYellow }
        return blue
    }

    // 1 账本
    private func drawLedger(_ d: DeepSeekSnapshot) {
        text(money(d.balance, d.currency), x: labelX, y: -0.5, color: balanceColor(d), size: 15, weight: .bold)
        rightPair("累计已花 ", "¥" + totalSpent, right: rightEdge, y: 2.5)
        text("今日 " + tokens(d.todayTokens) + " tok", x: labelX, y: 17.5, color: dim, size: 10.5, weight: .regular)
        right(cache(d), right: rightEdge, y: 17.5, color: green, size: 10.5, weight: .medium)
    }

    // 2 趋势
    private func drawTrend(_ d: DeepSeekSnapshot) {
        text(money(d.balance, d.currency), x: labelX, y: -0.5, color: balanceColor(d), size: 15, weight: .bold)
        rightPair("今日 ", tokens(d.todayTokens), right: rightEdge, y: 2.5, tail: "  日均 " + weekAvgTokens)
        let isPeak = phase == .peak
        text(isPeak ? "高峰 原价" : "闲时 5 折", x: labelX, y: 17.5,
             color: isPeak ? orange : blue, size: 10.5, weight: .semibold)
        right(cache(d), right: rightEdge, y: 17.5, color: green, size: 10.5, weight: .medium)
    }

    // 3 今日花费
    private func drawSpend(_ d: DeepSeekSnapshot) {
        text(money(d.balance, d.currency), x: labelX, y: -0.5, color: balanceColor(d), size: 15, weight: .bold)
        rightPair("今日花 ", "¥" + todaySpend, right: rightEdge, y: 2.5)
        text("今日 " + tokens(d.todayTokens) + " tok", x: labelX, y: 17.5, color: dim, size: 10.5, weight: .regular)
        right(cache(d), right: rightEdge, y: 17.5, color: green, size: 10.5, weight: .medium)
    }

    // 4 时段徽章 + 余额
    private func drawPhaseLedger(_ d: DeepSeekSnapshot) {
        let isPeak = phase == .peak
        let tint = isPeak ? orange : blue
        let label = isPeak ? "高峰 原价" : "闲时 5 折"
        let pillW = width(label, 10.5, .semibold) + 12
        tint.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: NSRect(x: labelX, y: 2, width: pillW, height: 14), xRadius: 7, yRadius: 7).fill()
        text(label, x: labelX + 6, y: 3.5, color: tint, size: 10.5, weight: .semibold)
        right(money(d.balance, d.currency), right: rightEdge, y: 0, color: balanceColor(d), size: 14, weight: .bold)
        text("已花 ¥" + totalSpent, x: labelX, y: 17.5, color: dim, size: 10.5, weight: .regular)
        let mid = " · " + tokens(d.todayTokens) + " tok"
        text(mid, x: labelX + width("已花 ¥" + totalSpent, 10.5, .regular), y: 17.5, color: bright, size: 10.5, weight: .regular)
        right(cache(d), right: rightEdge, y: 17.5, color: green, size: 10.5, weight: .medium)
    }

    // 5 三栏
    private func drawColumns(_ d: DeepSeekSnapshot) {
        let xs: [CGFloat] = [38, 126, 212]
        for (x, name) in zip(xs, ["余额", "累计已花", "缓存命中"]) {
            text(name, x: x, y: 1, color: dim, size: 9.5, weight: .regular)
        }
        text(money(d.balance, d.currency), x: xs[0], y: 12, color: balanceColor(d), size: 14, weight: .semibold)
        text("¥" + totalSpent, x: xs[1], y: 12, color: bright, size: 14, weight: .semibold)
        text(cacheValue(d), x: xs[2], y: 12, color: green, size: 14, weight: .semibold)
    }

    // MARK: helpers
    private func money(_ v: Decimal?, _ c: String) -> String {
        guard let v else { return "—" }
        return (c.uppercased() == "USD" ? "$" : "¥") + String(format: "%.2f", NSDecimalNumber(decimal: v).doubleValue)
    }
    private func tokens(_ v: Int64?) -> String {
        guard let v, v >= 0 else { return "—" }
        let n = Double(v)
        if n >= 999_995_000 { return String(format: "%.2fB", n / 1e9) }
        if n >= 999_995 { return String(format: "%.2fM", n / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1e3) }
        return String(v)
    }
    private func cache(_ d: DeepSeekSnapshot) -> String {
        d.todayCacheHitPercent.map { String(format: "缓存 %.1f%%", $0) } ?? "缓存 —"
    }
    private func cacheValue(_ d: DeepSeekSnapshot) -> String {
        d.todayCacheHitPercent.map { String(format: "%.1f%%", $0) } ?? "—"
    }
    private func attrs(_ size: CGFloat, _ weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]
    }
    private func width(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        (s as NSString).size(withAttributes: attrs(size, weight)).width
    }
    private func text(_ s: String, x: CGFloat, y: CGFloat, color: NSColor, size: CGFloat, weight: NSFont.Weight) {
        var a = attrs(size, weight); a[.foregroundColor] = color
        let attributed = NSAttributedString(string: s, attributes: a)
        let box = attributed.size()
        drawn.append((s, NSRect(x: x, y: y, width: box.width, height: box.height)))
        attributed.draw(at: NSPoint(x: x, y: y))
    }
    private func right(_ s: String, right: CGFloat, y: CGFloat, color: NSColor, size: CGFloat, weight: NSFont.Weight) {
        text(s, x: right - width(s, size, weight), y: y, color: color, size: size, weight: weight)
    }
    /// 右对齐的「灰标签 + 亮数值 (+ 灰尾巴)」，分三段画，三段互不重叠。
    private func rightPair(_ label: String, _ value: String, right edge: CGFloat, y: CGFloat, tail: String = "") {
        var x = edge
        if !tail.isEmpty {
            x -= width(tail, 10.5, .regular)
            text(tail, x: x, y: y + 0.3, color: dim, size: 10.5, weight: .regular)
        }
        x -= width(value, 11.5, .semibold)
        text(value, x: x, y: y, color: bright, size: 11.5, weight: .semibold)
        x -= width(label, 10.5, .regular)
        text(label, x: x, y: y + 0.3, color: dim, size: 10.5, weight: .regular)
    }
}

// MARK: - 菜单栏（高 24pt，flipped）

enum MB4Style: Int, CaseIterable {
    case balance    // A 鲸鱼 + 余额
    case phaseDot   // B 峰谷色点 + 余额
    case tokens     // C 余额 + 今日 token
    case spent      // D 余额 + 累计已花
    case spend      // E 余额 + 今日花费（需记录基线）
}

final class MB4View: NSView {
    var style: MB4Style = .balance
    var dark = true
    var snapshot: DeepSeekSnapshot?
    var phase: DeepSeekPricePhase = .offPeak
    var totalSpent = "19.25"
    var todaySpend = "0.42"
    var label = ""
    var drawn: [(String, NSRect)] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func update(_ value: DeepSeekSnapshot) { snapshot = value; needsDisplay = true }

    private lazy var logo = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")
    private var fg: NSColor { dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1) }
    private var sub: NSColor { dark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.40, alpha: 1) }

    override func draw(_ dirtyRect: NSRect) {
        drawn = []
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        bounds.fill()
        for x in [CGFloat(8), CGFloat(24)] {
            sub.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 8, width: 8, height: 8)).fill()
        }
        put(label, x: 44, y: 5, size: 10, color: sub, weight: .regular)
        guard let d = snapshot else { return }
        var edge = bounds.width - 12
        let balanceText = money(d)
        switch style {
        case .balance: break
        case .phaseDot: break
        case .tokens:
            let t = tokens(d.todayTokens)
            edge -= width(t, 10.5, .regular) + 5
            put(t, x: edge, y: 6.5, size: 10.5, color: sub, weight: .regular)
        case .spent:
            let t = "已花 " + totalSpent
            edge -= width(t, 10.5, .regular) + 5
            put(t, x: edge, y: 6.5, size: 10.5, color: sub, weight: .regular)
        case .spend:
            let t = "今日 −" + todaySpend
            edge -= width(t, 10.5, .regular) + 5
            put(t, x: edge, y: 6.5, size: 10.5, color: sub, weight: .regular)
        }
        let bw = width(balanceText, 13, .medium)
        // 副文字已经把 edge 左移了 5pt，这里再留 4pt 空隙，余额和副文字之间共 9pt。
        let bx = edge - bw - (style == .balance || style == .phaseDot ? 0 : 4)
        put(balanceText, x: bx, y: 4, size: 13, color: balanceColor(d), weight: .medium)
        var logoX = bx - 22
        if style == .phaseDot {
            (phase == .peak ? NSColor.systemOrange : NSColor.systemBlue).setFill()
            NSBezierPath(ovalIn: NSRect(x: bx - 11, y: 9.5, width: 6, height: 6)).fill()
            logoX = bx - 11 - 22
        }
        logo?.draw(in: NSRect(x: logoX, y: 4, width: 16, height: 16))
    }

    /// 没有「本次充值额」时只能用绝对金额提示：≤¥5 红、≤¥15 橙（设计假设）。
    private func balanceColor(_ d: DeepSeekSnapshot) -> NSColor {
        guard let b = d.balance else { return fg }
        let v = NSDecimalNumber(decimal: b).doubleValue
        if v <= 5 { return .systemRed }
        if v <= 15 { return .systemOrange }
        return fg
    }
    private func money(_ d: DeepSeekSnapshot) -> String {
        guard let b = d.balance else { return "—" }
        return (d.currency.uppercased() == "USD" ? "$" : "¥") + String(format: "%.2f", NSDecimalNumber(decimal: b).doubleValue)
    }
    private func tokens(_ v: Int64?) -> String {
        guard let v, v >= 0 else { return "—" }
        let n = Double(v)
        if n >= 999_995 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1e3) }
        return String(v)
    }
    private func attrs(_ size: CGFloat, _ weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]
    }
    private func width(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        (s as NSString).size(withAttributes: attrs(size, weight)).width
    }
    private func put(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
        var a = attrs(size, weight); a[.foregroundColor] = color
        let attributed = NSAttributedString(string: s, attributes: a)
        let box = attributed.size()
        drawn.append((s, NSRect(x: x, y: y, width: box.width, height: box.height)))
        attributed.draw(at: NSPoint(x: x, y: y))
    }
}
