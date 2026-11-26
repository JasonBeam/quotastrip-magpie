import AppKit

/// 第三轮设计：只用于评审，不参与正式构建；由 Tests/render-designs3.py 离屏渲染。
/// 全部只用「可真实取得」的数据：余额、累计充值（余额+官方累计消费）、官方累计已花、
/// 今日 token、缓存命中、峰谷时段。续航天数是示意（需另行定义算法后才能上线）。

// MARK: - Touch Bar（300×30，flipped，y 从顶部算）

enum TBStyle: Int, CaseIterable {
    case runway    // T1 余额 + 续航天数
    case columns   // T2 三栏仪表
    case phase     // T3 时段主导（闲时/高峰 + 距切换）
    case single    // T4 单行极简
    case spent     // T5 余额 + 累计已花
}

final class TBDesignView: NSView {
    static let viewWidth: CGFloat = 300
    var style: TBStyle = .runway
    var snapshot: DeepSeekSnapshot?
    var phase: DeepSeekPricePhase = .offPeak
    var spent: Decimal = Decimal(string: "19.02")!
    var runwayDays = 11
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

    override func draw(_ dirtyRect: NSRect) {
        drawn = []
        (phase == .peak ? peakLogo : offPeakLogo)?.draw(in: NSRect(x: 4, y: 2, width: 26, height: 26))
        guard let d = snapshot else { return }
        switch style {
        case .runway: drawRunway(d)
        case .columns: drawColumns(d)
        case .phase: drawPhase(d)
        case .single: drawSingle(d)
        case .spent: drawSpent(d)
        }
    }

    private func balanceColor(_ d: DeepSeekSnapshot) -> NSColor {
        guard let p = percent(d) else { return dim }
        if p <= 10 { return .systemRed }
        if p <= 25 { return .systemYellow }
        return blue
    }

    // T1：金额是主角，右侧回答「还能撑多久」
    private func drawRunway(_ d: DeepSeekSnapshot) {
        text(money(d.balance, d.currency), x: labelX, y: -0.5, color: balanceColor(d), size: 15, weight: .bold)
        right("约够 \(runwayDays) 天", right: rightEdge, y: 2.5, color: bright, size: 11.5, weight: .medium)
        text("今日 " + tokens(d.todayTokens) + " tok", x: labelX, y: 17.5, color: dim, size: 10.5, weight: .regular)
        right(cache(d), right: rightEdge, y: 17.5, color: green, size: 10.5, weight: .medium)
    }

    // T2：三个读数等宽并列，标签在上，扫一眼就读完
    private func drawColumns(_ d: DeepSeekSnapshot) {
        let xs: [CGFloat] = [38, 126, 212]
        for (x, name) in zip(xs, ["余额", "今日 token", "缓存命中"]) {
            text(name, x: x, y: 1, color: dim, size: 9.5, weight: .regular)
        }
        text(money(d.balance, d.currency), x: xs[0], y: 12, color: balanceColor(d), size: 14, weight: .semibold)
        text(tokens(d.todayTokens), x: xs[1], y: 12, color: bright, size: 14, weight: .semibold)
        text(cacheValue(d), x: xs[2], y: 12, color: green, size: 14, weight: .semibold)
    }

    // T3：先告诉你「现在划不划算」，再给读数
    private func drawPhase(_ d: DeepSeekSnapshot) {
        let isPeak = phase == .peak
        let tint = isPeak ? orange : blue
        let label = isPeak ? "高峰 原价" : "闲时 5 折"
        let pillW = width(label, 10.5, .semibold) + 12
        tint.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: NSRect(x: labelX, y: 2, width: pillW, height: 14), xRadius: 7, yRadius: 7).fill()
        text(label, x: labelX + 6, y: 3.5, color: tint, size: 10.5, weight: .semibold)
        let h = Int(countdown) / 3600, m = (Int(countdown) % 3600) / 60
        text(String(format: "%@ %02d:%02d", isPeak ? "距闲时" : "距高峰", h, m),
             x: labelX + pillW + 8, y: 3.8, color: dim, size: 10.5, weight: .regular)
        var x = labelX
        let items: [(String, NSColor, CGFloat)] = [
            (money(d.balance, d.currency), balanceColor(d), 13),
            (tokens(d.todayTokens), bright, 12.5),
            (cacheValue(d), green, 12.5)]
        for (i, item) in items.enumerated() {
            text(item.0, x: x, y: 16.5, color: item.1, size: item.2, weight: .semibold)
            x += width(item.0, item.2, .semibold)
            if i < items.count - 1 {
                text("  ·  ", x: x, y: 16.8, color: dim, size: 11, weight: .regular)
                x += width("  ·  ", 11, .regular)
            }
        }
    }

    // T4：只有一行，垂直居中，最安静
    private func drawSingle(_ d: DeepSeekSnapshot) {
        let y: CGFloat = 6
        text(money(d.balance, d.currency), x: labelX, y: y, color: balanceColor(d), size: 16, weight: .bold)
        let mid = tokens(d.todayTokens)
        text(mid, x: 164 - width(mid, 16, .semibold) / 2, y: y, color: bright, size: 16, weight: .semibold)
        right(cacheValue(d), right: rightEdge, y: y, color: green, size: 16, weight: .semibold)
    }

    // T5：余额 + 官方累计已花，看「花了多少、剩多少」
    private func drawSpent(_ d: DeepSeekSnapshot) {
        text(money(d.balance, d.currency), x: labelX, y: -0.5, color: balanceColor(d), size: 15, weight: .bold)
        right("剩 \(percent(d).map { "\($0)%" } ?? "—")", right: rightEdge, y: 2.5, color: dim, size: 11.5, weight: .medium)
        let spentText = "已花 " + money(spent, d.currency)
        text(spentText, x: labelX, y: 17.5, color: dim, size: 10.5, weight: .regular)
        text(" · " + tokens(d.todayTokens) + " tok", x: labelX + width(spentText, 10.5, .regular),
             y: 17.5, color: bright, size: 10.5, weight: .regular)
        right(cache(d), right: rightEdge, y: 17.5, color: green, size: 10.5, weight: .medium)
    }

    // MARK: helpers
    private func percent(_ d: DeepSeekSnapshot) -> Int? {
        guard let b = d.balance, let s = d.startingBalance else { return nil }
        let bv = NSDecimalNumber(decimal: b).doubleValue, sv = NSDecimalNumber(decimal: s).doubleValue
        guard sv > 0 else { return nil }
        return max(0, min(100, Int((bv / sv * 100).rounded())))
    }
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
    var drawn: [(String, NSRect)] = []
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
}

// MARK: - 菜单栏（高 24pt，flipped）

enum MBStyle: Int, CaseIterable {
    case balance   // A 鲸鱼 + 余额
    case percent   // B 鲸鱼 + 余额 + 剩余百分比
    case dual      // C 双家活图标：上条 Codex 5h，下条 DeepSeek 余额（无文字）
    case dualText  // D 双家活图标 + 余额
    case phaseDot  // E 峰谷色点 + 余额
}

final class MBDesignView: NSView {
    var style: MBStyle = .balance
    var dark = true
    var snapshot: DeepSeekSnapshot?
    var phase: DeepSeekPricePhase = .offPeak
    var codexFive = 100
    var label = ""

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func update(_ value: DeepSeekSnapshot) { snapshot = value; needsDisplay = true }

    private lazy var logo = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")
    private var fg: NSColor { dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1) }
    private var sub: NSColor { dark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.40, alpha: 1) }
    private var track: NSColor { fg.withAlphaComponent(0.30) }

    override func draw(_ dirtyRect: NSRect) {
        drawn = []
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        bounds.fill()
        // 邻居图标，体现菜单栏里的真实拥挤程度
        for x in [CGFloat(8), CGFloat(24)] {
            sub.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 8, width: 8, height: 8)).fill()
        }
        draw(text: label, x: 44, y: 5, size: 10, color: sub, weight: .regular)
        guard let d = snapshot else { return }
        var x = bounds.width - 12
        switch style {
        case .balance: x = drawBalance(d, rightEdge: x)
        case .percent: x = drawPercent(d, rightEdge: x)
        case .dual: x = drawDual(d, rightEdge: x, withText: false)
        case .dualText: x = drawDual(d, rightEdge: x, withText: true)
        case .phaseDot: x = drawPhaseDot(d, rightEdge: x)
        }
        _ = x
    }

    private func logoDraw(at x: CGFloat) {
        logo?.draw(in: NSRect(x: x, y: 4, width: 16, height: 16))
    }

    private func statusColor(_ d: DeepSeekSnapshot) -> NSColor {
        guard let p = percent(d) else { return fg }
        if p <= 10 { return .systemRed }
        if p <= 25 { return .systemOrange }
        return fg
    }

    // A
    private func drawBalance(_ d: DeepSeekSnapshot, rightEdge: CGFloat) -> CGFloat {
        let s = money(d)
        let w = width(s, 13, .medium)
        let x = rightEdge - w
        draw(text: s, x: x, y: 4, size: 13, color: statusColor(d), weight: .medium)
        logoDraw(at: x - 22)
        return x - 22
    }

    // B
    private func drawPercent(_ d: DeepSeekSnapshot, rightEdge: CGFloat) -> CGFloat {
        let p = percent(d).map { "\($0)%" } ?? "—"
        let pw = width(p, 10.5, .regular)
        draw(text: p, x: rightEdge - pw, y: 6, size: 10.5, color: sub, weight: .regular)
        return drawBalance(d, rightEdge: rightEdge - pw - 6)
    }

    // C / D：上条 = Codex 5h 剩余，下条 = DeepSeek 余额剩余（一个图标同时说两家）
    private func drawDual(_ d: DeepSeekSnapshot, rightEdge: CGFloat, withText: Bool) -> CGFloat {
        var edge = rightEdge
        if withText {
            let s = money(d)
            let w = width(s, 13, .medium)
            draw(text: s, x: edge - w, y: 4, size: 13, color: statusColor(d), weight: .medium)
            edge -= w + 6
        }
        let iconW: CGFloat = 20
        let x0 = edge - iconW
        let rows: [(y: CGFloat, ratio: CGFloat, color: NSColor)] = [
            (5, CGFloat(codexFive) / 100, fg),
            (13, CGFloat(percent(d) ?? 0) / 100, statusColor(d))]
        for r in rows {
            track.setFill()
            NSBezierPath(roundedRect: NSRect(x: x0, y: r.y, width: iconW, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            r.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x0, y: r.y, width: max(5, iconW * r.ratio), height: 5),
                         xRadius: 2.5, yRadius: 2.5).fill()
        }
        return x0
    }

    // E
    private func drawPhaseDot(_ d: DeepSeekSnapshot, rightEdge: CGFloat) -> CGFloat {
        let s = money(d)
        let w = width(s, 13, .medium)
        let x = rightEdge - w
        draw(text: s, x: x, y: 4, size: 13, color: statusColor(d), weight: .medium)
        (phase == .peak ? NSColor.systemOrange : NSColor.systemBlue).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 11, y: 9.5, width: 6, height: 6)).fill()
        logoDraw(at: x - 11 - 22)
        return x - 33
    }

    // helpers
    private func percent(_ d: DeepSeekSnapshot) -> Int? {
        guard let b = d.balance, let s = d.startingBalance else { return nil }
        let bv = NSDecimalNumber(decimal: b).doubleValue, sv = NSDecimalNumber(decimal: s).doubleValue
        guard sv > 0 else { return nil }
        return max(0, min(100, Int((bv / sv * 100).rounded())))
    }
    private func money(_ d: DeepSeekSnapshot) -> String {
        guard let b = d.balance else { return "—" }
        return (d.currency.uppercased() == "USD" ? "$" : "¥") + String(format: "%.2f", NSDecimalNumber(decimal: b).doubleValue)
    }
    private func attrs(_ size: CGFloat, _ weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]
    }
    private func width(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        (s as NSString).size(withAttributes: attrs(size, weight)).width
    }
    var drawn: [(String, NSRect)] = []
    private func draw(text s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
        var a = attrs(size, weight); a[.foregroundColor] = color
        let attributed = NSAttributedString(string: s, attributes: a)
        let box = attributed.size()
        drawn.append((s, NSRect(x: x, y: y, width: box.width, height: box.height)))
        attributed.draw(at: NSPoint(x: x, y: y))
    }
}
