import AppKit
import CoreText

/// 设计评审用：DeepSeek 模块（逻辑宽 300 × 30pt）的「排版驱动 / 瑞士式数据排版」三案。
///
/// 只用字号、字重、对齐、留白和一条极细分隔线建立层级：没有进度条、没有饼图、没有药丸徽章，
/// 也没有任何百分比进度的暗示（分母不可信）。颜色只有品牌蓝、中性白/灰，缓存命中率用一个克制的绿。
///
/// 三个变体是同一个排版系统的三种「主角」选择：
/// 1. strip  单基线数据带 —— 三个数字压在同一条基线上，两条竖细线分栏，余额是主角。
/// 2. ledger 账本 2×2     —— 四格、微标签 + 右对齐数值，一条横细线分上下，四个数平权可核对。
/// 3. today  今日主导      —— 今日 token 是主角，缓存同线右对齐，账户信息退到脚注。
///
/// 不参与正式构建；Tests/render-tb-design-a.py 会把它和现役 DeepSeekTouchBarView 并排渲染，
/// 并用真实的 NSString / CTLine 度量对每个文字块做越界与重叠自查。
enum TBAStyle: Int, CaseIterable {
    case strip
    case ledger
    case today

    var slug: String {
        switch self {
        case .strip: return "strip"
        case .ledger: return "ledger"
        case .today: return "today"
        }
    }

    var title: String {
        switch self {
        case .strip: return "单基线数据带"
        case .ledger: return "账本 2×2"
        case .today: return "今日主导"
        }
    }
}

/// 一段文字：位置用「基线 + 左边界」，宽度由真实字体度量得出，绝不用手写的近似值对齐。
struct TBARun {
    let id: String
    let text: String
    let x: CGFloat
    /// 基线在翻转坐标系里的 y。
    let baseline: CGFloat
    let size: CGFloat
    let weight: NSFont.Weight
    let kern: CGFloat
    let color: NSColor
}

/// 一条极细分隔线：用 fill 而不是 stroke，0.5pt 在 2x 下正好 1 个物理像素。
struct TBARule {
    let id: String
    let rect: NSRect
}

/// 自查用度量：advance 宽度 + 墨迹相对基线的上下距（上负下正）。
struct TBAMetrics {
    let advance: CGFloat
    let inkTop: CGFloat
    let inkBottom: CGFloat
}

final class TBDesignAView: NSView {
    // MARK: - 与现役视图共享的几何

    static let viewWidth: CGFloat = 300
    static let viewHeight: CGFloat = 30
    /// 与 DeepSeekTouchBarView 相同的标签列起点，图标 26×26 在 (4, 2)。
    static let textLeft: CGFloat = 36
    /// 与现役视图相同的右边界：292，右边留 8pt 呼吸，不贴 300 的模块边缘。
    static let rightEdge: CGFloat = 292
    static let logoRect = NSRect(x: 4, y: 2, width: 26, height: 26)
    /// 文字块的 x 安全区，自查用。
    static let minX: CGFloat = 4

    /// 色板：品牌蓝 + 中性白/灰，命中率一个克制的绿。没有第四种颜色。
    enum Palette {
        static let blue = NSColor(calibratedRed: 0.26, green: 0.48, blue: 1.00, alpha: 1)
        static let green = NSColor(calibratedRed: 0.36, green: 0.83, blue: 0.64, alpha: 1)
        static let white = NSColor(white: 0.97, alpha: 1)
        static let mid = NSColor(white: 0.80, alpha: 1)
        static let dim = NSColor(white: 0.58, alpha: 1)
        static let rule = NSColor(white: 1.00, alpha: 0.26)
    }

    // MARK: - 状态

    var style: TBAStyle = .strip
    var snapshot: DeepSeekSnapshot?
    var phase: DeepSeekPricePhase = .offPeak

    /// 近 7 日 DeepSeek token（旧 → 新，真实数据）。后两天还没到，所以是 0。
    var weekTokens: [Double] = [8_969_898, 106_515_375, 103_088_154, 6_774_405, 3_570_277, 0, 0]

    private lazy var offPeakLogo: NSImage? =
        NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")
    private lazy var peakLogo: NSImage? =
        NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.viewWidth, height: Self.viewHeight) }

    func update(_ value: DeepSeekSnapshot) {
        snapshot = value
        needsDisplay = true
    }

    // MARK: - 排版片段

    /// 一段带字号/字重/字距的文字。gap 是它和前一段之间要留的间距。
    private struct Piece {
        let id: String
        let text: String
        let size: CGFloat
        let weight: NSFont.Weight
        let kern: CGFloat
        let color: NSColor
        let gap: CGFloat
    }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private func attributes(_ size: CGFloat, _ weight: NSFont.Weight, kern: CGFloat,
                            color: NSColor) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight), .foregroundColor: color]
        if kern != 0 { attrs[.kern] = kern }
        return attrs
    }

    private func width(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ kern: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: attributes(size, weight, kern: kern, color: .white)).size().width
    }

    /// 真实度量：NSString 的 advance 宽度 + CTLine 的墨迹上下界（相对基线）。
    static func metrics(_ text: String, size: CGFloat, weight: NSFont.Weight, kern: CGFloat) -> TBAMetrics {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]
        if kern != 0 { attrs[.kern] = kern }
        let string = NSAttributedString(string: text, attributes: attrs)
        let advance = string.size().width
        let line = CTLineCreateWithAttributedString(string)
        guard let context = measureContext else {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            return TBAMetrics(advance: advance, inkTop: -font.ascender, inkBottom: -font.descender)
        }
        let ink = CTLineGetImageBounds(line, context)
        if ink.isNull || ink.isEmpty {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            return TBAMetrics(advance: advance, inkTop: -font.ascender, inkBottom: -font.descender)
        }
        return TBAMetrics(advance: advance, inkTop: -ink.maxY, inkBottom: -ink.minY)
    }

    private static let measureContext: CGContext? = CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)

    private func width(_ piece: Piece) -> CGFloat {
        width(piece.text, piece.size, piece.weight, piece.kern)
    }

    private func groupWidth(_ pieces: [Piece]) -> CGFloat {
        pieces.reduce(0) { $0 + $1.gap + width($1) }
    }

    private func group(_ pieces: [Piece], x: CGFloat, baseline: CGFloat) -> [TBARun] {
        var cursor = x
        var runs: [TBARun] = []
        for piece in pieces {
            cursor += piece.gap
            runs.append(TBARun(id: piece.id, text: piece.text, x: cursor, baseline: baseline,
                               size: piece.size, weight: piece.weight, kern: piece.kern, color: piece.color))
            cursor += width(piece)
        }
        return runs
    }

    /// 0.5pt 的线只有落在设备像素边界上才是 1 个物理像素；否则 2x 下会被抗锯齿摊成两行半亮像素。
    private func rule(id: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 0.5) -> TBARule {
        let snappedX = (x * 2).rounded() / 2
        let snappedY = (y * 2).rounded() / 2
        return TBARule(id: id, rect: NSRect(x: snappedX, y: snappedY,
                                           width: (width * 2).rounded() / 2,
                                           height: (height * 2).rounded() / 2))
    }

    // MARK: - 布局（纯函数，渲染与自查共用同一份结果）

    func rules(for data: DeepSeekSnapshot) -> [TBARule] {
        switch style {
        case .strip: return stripModel(data).rules
        case .ledger: return ledgerRules()
        case .today: return todayRules()
        }
    }

    func runs(for data: DeepSeekSnapshot) -> [TBARun] {
        let base: [TBARun]
        switch style {
        case .strip: base = stripModel(data).runs
        case .ledger: base = ledgerRuns(data)
        case .today: base = todayRuns(data)
        }
        // 数据过期时整条降亮度（同色系降透明度），不引入第三种颜色、不加图元：
        // 排版系统自己就能表达「这组数不是此刻的」。
        guard data.stale else { return base }
        return base.map {
            TBARun(id: $0.id, text: $0.text, x: $0.x, baseline: $0.baseline, size: $0.size,
                   weight: $0.weight, kern: $0.kern, color: $0.color.withAlphaComponent(0.45))
        }
    }

    // MARK: 方案 1 · 单基线数据带

    /// 次级两栏的字号档：内容变长时整体降一档，排版自己让位，而不是把字挤到一起。
    private struct ClusterTier {
        let value: CGFloat
        let label: CGFloat
        let unit: CGFloat
    }

    private static let stripTiers = [
        ClusterTier(value: 12.5, label: 8.5, unit: 8.5),
        ClusterTier(value: 11.5, label: 8.0, unit: 8.0),
        ClusterTier(value: 10.5, label: 7.5, unit: 7.5),
    ]

    /// 三个数字共用一条基线（21.1），两条 0.5pt 竖线把 256pt 的内容区切成三栏。
    /// 栏间距用「余额右缘 → 缓存右缘」的剩余空间等分，所以是真正的两端对齐，不靠手调魔法数字。
    /// 剩余空间不够时按 stripTiers 逐档降字号；间距窄到 7pt 以下就不再画竖线（线不压字）。
    private func stripModel(_ data: DeepSeekSnapshot) -> (runs: [TBARun], rules: [TBARule]) {
        let baseline: CGFloat = 21.1
        let hero = heroPieces(data, symbolSize: 19, symbolWeight: .medium, digitSize: 19)
        let heroWidth = groupWidth(hero)

        var today = todayPieces(data, valueSize: 12.5, unitSize: 8.5)
        var cache = cachePieces(data, valueSize: 12.5)
        var gap: CGFloat = 10
        for (index, tier) in Self.stripTiers.enumerated() {
            today = todayPieces(data, valueSize: tier.value, unitSize: tier.unit, labelSize: tier.label)
            cache = cachePieces(data, valueSize: tier.value, labelSize: tier.label)
            let free = Self.rightEdge - Self.textLeft - heroWidth - groupWidth(today) - groupWidth(cache)
            gap = free / 2
            if gap >= 4 || index == Self.stripTiers.count - 1 { break }
        }
        gap = max(4, gap)

        let heroX = Self.textLeft
        let todayX = heroX + heroWidth + gap
        let cacheX = Self.rightEdge - groupWidth(cache)

        var runs = group(hero, x: heroX, baseline: baseline)
        runs += group(today, x: todayX, baseline: baseline)
        runs += group(cache, x: cacheX, baseline: baseline)

        var rules: [TBARule] = []
        if gap >= 7 {
            let top = baseline - 13.0
            let todayEnd = todayX + groupWidth(today)
            rules = [
                rule(id: "stripRule1", x: (heroX + heroWidth + todayX) / 2 - 0.25, y: top, width: 0.5, height: 13.5),
                rule(id: "stripRule2", x: (todayEnd + cacheX) / 2 - 0.25, y: top, width: 0.5, height: 13.5),
            ]
        }
        return (runs, rules)
    }

    // MARK: 方案 2 · 账本 2×2

    /// 两条基线（12.4 / 27.5）+ 一条横细线（15.3）把模块切成「钱的上一格」和「用量的下一格」。
    /// 四格里都是「微标签在左、数值右对齐到格右缘」，数值列因此天然对齐。
    private func ledgerRuns(_ data: DeepSeekSnapshot) -> [TBARun] {
        let row1: CGFloat = 13.0
        let row2: CGFloat = 27.1
        let col1Right: CGFloat = 132
        let col2LabelX: CGFloat = 184
        let col2Right: CGFloat = Self.rightEdge

        // 金额变长时降一档字号：字距可以被压，标签和数值之间的呼吸不能没有。
        let balanceLabel = label("balanceLabel", "余额")
        let spentLabel = label("spentLabel", "累计已花")
        let firstCellValue = fitted({ size in
            [Piece(id: "balanceValue", text: money(data), size: size, weight: .semibold,
                   kern: 0, color: Palette.blue, gap: 0)]
        }, sizes: [15, 13.5, 12],
           maxWidth: col1Right - Self.textLeft - groupWidth([balanceLabel]) - 8)
        let secondCellValue = fitted({ size in
            [Piece(id: "spentValue", text: money(data, starting: true), size: size,
                   weight: .medium, kern: 0, color: Palette.mid, gap: 0)]
        }, sizes: [12, 10.5],
           maxWidth: col2Right - col2LabelX - groupWidth([spentLabel]) - 8)
        let thirdCellValue = [Piece(id: "todayValue", text: tokensShort(data.todayTokens), size: 12,
                                    weight: .semibold, kern: 0, color: Palette.white, gap: 0),
                              Piece(id: "todayUnit", text: "tok", size: 8.5, weight: .medium,
                                    kern: 0.3, color: Palette.mid, gap: 2)]
        let fourthCellValue = [Piece(id: "cacheValue", text: cachePercent(data), size: 12,
                                     weight: .medium, kern: 0, color: Palette.green, gap: 0)]

        var runs = group([balanceLabel], x: Self.textLeft, baseline: row1)
        runs += group(firstCellValue, x: col1Right - groupWidth(firstCellValue), baseline: row1)
        runs += group([spentLabel], x: col2LabelX, baseline: row1)
        runs += group(secondCellValue, x: col2Right - groupWidth(secondCellValue), baseline: row1)
        runs += group([label("todayLabel", "今日")], x: Self.textLeft, baseline: row2)
        runs += group(thirdCellValue, x: col1Right - groupWidth(thirdCellValue), baseline: row2)
        runs += group([label("cacheLabel", "缓存")], x: col2LabelX, baseline: row2)
        runs += group(fourthCellValue, x: col2Right - groupWidth(fourthCellValue), baseline: row2)
        return runs
    }

    private func ledgerRules() -> [TBARule] {
        [rule(id: "ledgerRule", x: Self.textLeft, y: 15.5, width: Self.rightEdge - Self.textLeft)]
    }

    // MARK: 方案 3 · 今日主导

    /// 今日 token 17.5pt 当主角，缓存同线右对齐；横细线（17.0）以下是一行脚注：
    /// 余额（蓝）在左、近 7 日峰值在右，两端对齐，像页脚。
    private func todayRuns(_ data: DeepSeekSnapshot) -> [TBARun] {
        let heroBaseline: CGFloat = 14.6
        let footerBaseline: CGFloat = 27.1
        let cache = cachePieces(data, valueSize: 11, labelSize: 9)
        // 主角号码变长时降一档，缓存率始终留在右缘同一基线上。
        let hero = fitted({ size in
            todayPieces(data, valueSize: size, unitSize: size >= 17 ? 9 : 8, labelSize: 9)
        }, sizes: [17.5, 15.5],
           maxWidth: Self.rightEdge - Self.textLeft - groupWidth(cache) - 12)
        // 脚注两端对齐：先钉右组，左组按剩余宽度降档，永不相撞。
        let footerRight = fitted({ size in
            [label("weekLabel", "7日峰值"),
             Piece(id: "weekValue", text: weekPeakText(), size: size, weight: .medium,
                   kern: 0, color: Palette.mid, gap: 3)]
        }, sizes: [10, 9], maxWidth: 150)
        let footerLeft = fitted({ size in
            [label("balanceLabel", "余额"),
             Piece(id: "balanceValue", text: money(data), size: size, weight: .semibold,
                   kern: 0, color: Palette.blue, gap: 3.5)]
        }, sizes: [11, 10],
           maxWidth: Self.rightEdge - Self.textLeft - groupWidth(footerRight) - 12)

        var runs = group(hero, x: Self.textLeft, baseline: heroBaseline)
        runs += group(cache, x: Self.rightEdge - groupWidth(cache), baseline: heroBaseline)
        runs += group(footerLeft, x: Self.textLeft, baseline: footerBaseline)
        runs += group(footerRight, x: Self.rightEdge - groupWidth(footerRight), baseline: footerBaseline)
        return runs
    }

    private func todayRules() -> [TBARule] {
        [rule(id: "todayRule", x: Self.textLeft, y: 17.0, width: Self.rightEdge - Self.textLeft)]
    }

    // MARK: - 共用片段

    /// 字号阶梯自适应：按 sizes 从大到小试，取第一档宽度放得下的；都放不下就用最小档。
    private func fitted(_ make: (CGFloat) -> [Piece], sizes: [CGFloat], maxWidth: CGFloat) -> [Piece] {
        var smallest = make(sizes[sizes.count - 1])
        for size in sizes {
            let pieces = make(size)
            smallest = pieces
            if groupWidth(pieces) <= maxWidth { return pieces }
        }
        return smallest
    }

    private func label(_ id: String, _ text: String, size: CGFloat = 8.5) -> Piece {
        // 微标签：8.5pt + 0.6 字距。字距让中文标签读起来像「标记」而不是正文。
        Piece(id: id, text: text, size: size, weight: .medium, kern: 0.6, color: Palette.dim, gap: 0)
    }

    private func heroPieces(_ data: DeepSeekSnapshot, symbolSize: CGFloat, symbolWeight: NSFont.Weight = .semibold,
                            digitSize: CGFloat) -> [Piece] {
        let digits = digitsText(data.balance)
        guard digits != "—" else {
            return [Piece(id: "heroValue", text: "—", size: digitSize, weight: .semibold,
                          kern: 0, color: Palette.blue, gap: 0)]
        }
        // 货币符号小一号、和数字共基线：¥ 不该和大数字一样重。
        return [Piece(id: "heroSymbol", text: currencySymbol(data.currency), size: symbolSize,
                      weight: symbolWeight, kern: 0, color: Palette.blue, gap: 0),
                Piece(id: "heroValue", text: digits, size: digitSize, weight: .semibold,
                      kern: 0, color: Palette.blue, gap: 0.8)]
    }

    private func todayPieces(_ data: DeepSeekSnapshot, valueSize: CGFloat, unitSize: CGFloat,
                             labelSize: CGFloat = 8.5) -> [Piece] {
        [label("todayLabel", "今日", size: labelSize),
         Piece(id: "todayValue", text: tokensShort(data.todayTokens), size: valueSize,
               weight: .semibold, kern: 0, color: Palette.white, gap: 3),
         Piece(id: "todayUnit", text: "tok", size: unitSize, weight: .medium,
               kern: 0.3, color: Palette.dim, gap: 2)]
    }

    private func cachePieces(_ data: DeepSeekSnapshot, valueSize: CGFloat, labelSize: CGFloat = 8.5) -> [Piece] {
        [label("cacheLabel", "缓存", size: labelSize),
         Piece(id: "cacheValue", text: cachePercent(data), size: valueSize,
               weight: .medium, kern: 0, color: Palette.green, gap: 4)]
    }

    // MARK: - 数据格式化（只用真实字段，缺失就画 —）

    private func currencySymbol(_ currency: String) -> String {
        switch currency.uppercased() {
        case "CNY": return "¥"
        case "USD": return "$"
        default: return currency.isEmpty ? "¤" : currency
        }
    }

    private func digitsText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }

    private func money(_ data: DeepSeekSnapshot) -> String {
        currencySymbol(data.currency) + digitsText(data.balance)
    }

    /// 累计已花 = 账户累计 − 余额；两者都缺失时不编数字。
    private func money(_ data: DeepSeekSnapshot, starting: Bool) -> String {
        guard let balance = data.balance, let total = data.startingBalance else { return "¥—" }
        return currencySymbol(data.currency) + digitsText(total - balance)
    }

    private func tokensShort(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        return tokensShort(Double(value))
    }

    private func tokensShort(_ value: Double) -> String {
        if value >= 999_995_000 { return String(format: "%.2fB", value / 1_000_000_000) }
        if value >= 999_995 { return String(format: "%.2fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }

    private func cachePercent(_ data: DeepSeekSnapshot) -> String {
        guard let value = data.todayCacheHitPercent, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f%%", min(100, value))
    }

    /// 近 7 日里已记录的最高一天（后两天还没到，记 0，不参与峰值）。
    private func weekPeakText() -> String {
        let peak = weekTokens.max() ?? 0
        return peak > 0 ? tokensShort(peak) : "—"
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawLogo()
        guard let data = snapshot else {
            // 没有数据时只留一句中性提示，不编数字。
            let placeholder = TBARun(id: "placeholder", text: "等待 DSH 数据", x: Self.textLeft,
                                     baseline: 20.4, size: 11, weight: .regular, kern: 0,
                                     color: Palette.dim)
            drawRun(placeholder)
            return
        }
        Palette.rule.setFill()
        for entry in rules(for: data) {
            entry.rect.fill()
        }
        for entry in runs(for: data) {
            drawRun(entry)
        }
    }

    private func drawRun(_ run: TBARun) {
        let point = NSPoint(x: run.x, y: run.baseline - font(run.size, run.weight).ascender)
        (run.text as NSString).draw(at: point, withAttributes: attributes(run.size, run.weight,
                                                                        kern: run.kern, color: run.color))
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: attributes(size, .regular, kern: 0, color: color))
    }

    private func drawLogo() {
        let image: NSImage?
        switch phase {
        case .peak: image = peakLogo
        case .offPeak: image = offPeakLogo
        case .unknown: image = nil
        }
        if let image {
            image.draw(in: Self.logoRect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        } else {
            Palette.blue.setFill()
            NSBezierPath(ovalIn: Self.logoRect.insetBy(dx: 7, dy: 7)).fill()
        }
    }
}
