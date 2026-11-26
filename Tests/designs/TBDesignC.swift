import AppKit

/// 设计评审用，不参与正式构建：DeepSeek 模块「环境光 / 极简氛围式」三个变体。
///
/// 300×30、透明背景、不画进度条、不出现「剩余百分比」、不发明数据。
/// 三个变体共用一套几何与词汇（左图标 26×26 @(4,2)、标签列 36、内容列 66、右边界 292），
/// 只在「氛围通道」上不同：
///   C1 余晖：7 日微光带（体积=蓝光，最后一段=当下时段）
///   C2 静读：纯亮度层级 + 已花（唯一的彩色是 logo 与状态点）
///   C3 一言：单行 + 时段词（一句安静的话）
///
/// 布局由 `TBCEngine.build` 纯函数产出图元数组，绘制与自检共用同一份几何，
/// 因此 Tests/render-tb-design-c.py 检查的就是实际画出来的东西。
enum TBCStyle: Int, CaseIterable {
    case afterglow = 1
    case quiet = 2
    case whisper = 3

    var title: String {
        switch self {
        case .afterglow: return "C1 余晖"
        case .quiet: return "C2 静读"
        case .whisper: return "C3 一言"
        }
    }

    var note: String {
        switch self {
        case .afterglow: return "7 日微光带"
        case .quiet: return "亮度层级 + 已花"
        case .whisper: return "单行 + 时段词"
        }
    }
}

// MARK: - 输入

/// 与 DeepSeekSnapshot 对齐的设计用输入；week 是近 7 日（旧→新）token，
/// todayIndex 指出「今天」落在哪一格，之后的格子还没发生、不画。
struct TBCData {
    var balance: Decimal? = nil
    var startingBalance: Decimal? = nil
    var todayTokens: Int64? = nil
    var todayCache: Double? = nil
    var week: [Int64] = []
    var todayIndex: Int = 6
    var phase: DeepSeekPricePhase = .offPeak
    var stale: Bool = false
    var currency: String = "CNY"
}

// MARK: - 词汇

enum TBCPalette {
    static let primary = NSColor(calibratedWhite: 0.95, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.72, alpha: 1)
    static let tertiary = NSColor(calibratedWhite: 0.50, alpha: 1)
    static let label = NSColor(calibratedWhite: 0.44, alpha: 1)
    static let faint = NSColor(calibratedWhite: 0.32, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.26, green: 0.50, blue: 1.0, alpha: 1)
    static let coolLED = NSColor(calibratedRed: 0.47, green: 0.59, blue: 0.72, alpha: 1)
    /// 微光带的线色：比品牌蓝弱一档，避免在主数字旁边抢注意力。
    static let traceBlue = NSColor(calibratedRed: 0.52, green: 0.64, blue: 0.82, alpha: 1)
    static let amber = NSColor(calibratedRed: 0.90, green: 0.68, blue: 0.42, alpha: 1)
    static let neutralLED = NSColor(calibratedWhite: 0.52, alpha: 1)
}

// MARK: - 图元

struct TBCMark {
    enum Kind { case logo, text, trace, dot }

    var kind: Kind
    var role: String
    var group: String
    var row: Int
    var box: NSRect
    var text: String = ""
    var font: NSFont = NSFont.systemFont(ofSize: 10)
    var color: NSColor = .white
    var baseline: CGFloat = 0
    var diameter: CGFloat = 0
    /// 折线按「无记录」断开的段；每段至少 1 个点。
    var segments: [[NSPoint]] = []
    var baseY: CGFloat = 0
    var terminal: NSPoint? = nil
}

// MARK: - 排版引擎

enum TBCEngine {
    static let width: CGFloat = 300
    static let height: CGFloat = 30
    static let logoRect = NSRect(x: 4, y: 2, width: 26, height: 26)
    static let labelX: CGFloat = 36
    static let contentX: CGFloat = 66
    static let rightEdge: CGFloat = 292

    /// 两行基线：第一行给 15.5pt 主数字，第二行给 11.5pt 用量。
    static let baseline1: CGFloat = 12.5
    static let baseline2: CGFloat = 26.9
    /// 单行（C3）的基线，让 16.5pt 数字在 30pt 高度里垂直居中。
    static let baselineSingle: CGFloat = 20.7

    /// 状态光点：贴右上角，2.2pt，几乎所有变体共用。
    static let ledSize: CGFloat = 2.6
    static let ledRight: CGFloat = 292
    static let ledCenterY: CGFloat = 7.3

    /// C1 微光带的范围；右端留 18pt 给状态光点。
    /// 第二列起点：C1 的微光带、C2 的「已花」都从这里起，两个变体共用同一条列线。
    static let secondColumnX: CGFloat = 168
    static let traceLeft: CGFloat = 168
    static let traceRight: CGFloat = 274
    static let traceTop: CGFloat = 2.6
    static let traceBase: CGFloat = 11.4

    /// C3 的固定列：状态词右对齐 292、缓存右端 252、用量右端 190——右侧不随数据搬动。
    static let whisperCacheRight: CGFloat = 252
    static let whisperTokenRight: CGFloat = 190
    static let whisperTokenMaxWidth: CGFloat = 52
    /// C3 没有标签列，主数字不必落在 66 的内容栅格上。
    static let whisperContentX: CGFloat = 46

    static let minGap: CGFloat = 5.5

    // MARK: 字体与测量

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: 格式

    static func currencySymbol(_ code: String) -> String {
        switch code.uppercased() {
        case "CNY": return "¥"
        case "USD": return "$"
        default: return code.isEmpty ? "¤" : code
        }
    }

    /// 两位小数、不加千位分隔符：300pt 宽的面板里逗号只会挤压数字列。
    static func money(_ value: Decimal?, currency: String) -> String {
        guard let value = value, !value.isNaN else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let rendered = formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
        return currencySymbol(currency) + rendered
    }

    /// 只有极端位数放不下时才用的压缩写法（1.23K / 1.23M），不是默认显示。
    static func compactMoney(_ value: Decimal?, currency: String) -> String {
        guard let value = value, !value.isNaN else { return "—" }
        let n = NSDecimalNumber(decimal: value).doubleValue
        let symbol = currencySymbol(currency)
        if n >= 1_000_000 { return symbol + String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return symbol + String(format: "%.1fK", n / 1_000) }
        return money(value, currency: currency)
    }

    static func tokens(_ value: Int64?) -> String {
        guard let value = value, value >= 0 else { return "—" }
        let n = Double(value)
        if n >= 999_995_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 999_995 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
        return String(value)
    }

    static func cacheText(_ value: Double?) -> String {
        guard let value = value, value.isFinite, value >= 0 else { return "缓存 —" }
        return String(format: "缓存 %.1f%%", min(100, value))
    }

    struct Fitted {
        var text: String
        var size: CGFloat
        var width: CGFloat
    }

    static func fitMoney(_ value: Decimal?, currency: String, maxWidth: CGFloat,
                         sizes: [CGFloat], weight: NSFont.Weight) -> Fitted {
        let raw = money(value, currency: currency)
        for size in sizes {
            let w = textWidth(raw, font: mono(size, weight))
            if w <= maxWidth { return Fitted(text: raw, size: size, width: w) }
        }
        let compact = compactMoney(value, currency: currency)
        for size in sizes {
            let w = textWidth(compact, font: mono(size, weight))
            if w <= maxWidth { return Fitted(text: compact, size: size, width: w) }
        }
        let size = sizes[sizes.count - 1]
        return Fitted(text: compact, size: size, width: textWidth(compact, font: mono(size, weight)))
    }

    // MARK: 图元构造

    static func logoMark() -> TBCMark {
        TBCMark(kind: .logo, role: "logo", group: "logo", row: 0, box: logoRect)
    }

    static func text(_ role: String, _ group: String, _ value: String, x: CGFloat? = nil,
                     right: CGFloat? = nil, baseline: CGFloat, font: NSFont, color: NSColor,
                     row: Int, cjk: Bool = false) -> TBCMark {
        let w = textWidth(value, font: font)
        let x0 = right.map { $0 - w } ?? (x ?? 0)
        let inkTop = baseline - (cjk ? font.pointSize * 0.88 : font.capHeight)
        let inkBottom = baseline + (cjk ? font.pointSize * 0.12 : font.pointSize * 0.02)
        var mark = TBCMark(kind: .text, role: role, group: group, row: row,
                           box: NSRect(x: x0, y: inkTop, width: w, height: inkBottom - inkTop))
        mark.text = value
        mark.font = font
        mark.color = color
        mark.baseline = baseline
        return mark
    }

    static func dot(_ role: String, _ group: String, center: NSPoint, diameter: CGFloat,
                    color: NSColor, row: Int) -> TBCMark {
        var mark = TBCMark(kind: .dot, role: role, group: group, row: row,
                           box: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                       width: diameter, height: diameter))
        mark.color = color
        mark.diameter = diameter
        return mark
    }

    // MARK: 状态

    enum Status {
        case noData, stale, offPeak, peak, unknown

        var word: String? {
            switch self {
            case .noData: return "无数据"
            case .stale: return "过期"
            case .offPeak: return "闲时"
            case .peak: return "高峰"
            case .unknown: return "未知"
            }
        }

        var ledColor: NSColor {
            switch self {
            case .noData: return TBCPalette.neutralLED
            case .stale, .peak: return TBCPalette.amber
            case .offPeak: return TBCPalette.coolLED
            case .unknown: return TBCPalette.neutralLED
            }
        }

        var wordColor: NSColor {
            switch self {
            case .noData: return TBCPalette.tertiary
            case .stale, .peak: return TBCPalette.amber
            case .offPeak: return TBCPalette.coolLED
            case .unknown: return TBCPalette.tertiary
            }
        }
    }

    static func status(of data: TBCData) -> Status {
        if data.balance == nil { return .noData }
        if data.stale { return .stale }
        switch data.phase {
        case .peak: return .peak
        case .offPeak: return .offPeak
        case .unknown: return .unknown
        }
    }

    // MARK: 构建

    static func build(_ data: TBCData, style: TBCStyle) -> [TBCMark] {
        var marks: [TBCMark] = [logoMark()]
        switch style {
        case .afterglow: buildAfterglow(data, &marks)
        case .quiet: buildQuiet(data, &marks)
        case .whisper: buildWhisper(data, &marks)
        }
        if data.stale || status(of: data) == .noData {
            // 过期/无数据不是「删掉数字」，而是「让数字退后」：整体按比例压暗，状态词保持本色。
            for index in marks.indices where marks[index].kind != .logo && marks[index].role != "status" {
                marks[index].color = dimmed(marks[index].color)
            }
        }
        return marks
    }

    /// 保持色相、整体压低一档；用于过期状态，避免每处单独写三元表达式。
    static func dimmed(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        let factor: CGFloat = 0.70
        return NSColor(calibratedRed: rgb.redComponent * factor,
                       green: rgb.greenComponent * factor,
                       blue: rgb.blueComponent * factor,
                       alpha: rgb.alphaComponent)
    }

    /// C1 余晖：主数字 + 7 日微光带 + 一行安静的用量。
    private static func buildAfterglow(_ data: TBCData, _ marks: inout [TBCMark]) {
        let amount = fitMoney(data.balance, currency: data.currency,
                              maxWidth: traceLeft - 10 - contentX,
                              sizes: [15.5, 14, 12.5, 11], weight: .semibold)
        marks.append(text("label.balance", "label", "余额", x: labelX, baseline: baseline1,
                          font: ui(10, .medium), color: TBCPalette.label, row: 1, cjk: true))
        marks.append(text("value.balance", "balance", amount.text, x: contentX, baseline: baseline1,
                          font: mono(amount.size, .semibold),
                          color: TBCPalette.primary, row: 1))
        if let trace = traceMark(data) { marks.append(trace) }
        usageRow(data, &marks)
        statusCorner(data, &marks)
    }

    /// C2 静读：只有亮度层级；已花作为主数字的副标题；没有图形。
    private static func buildQuiet(_ data: TBCData, _ marks: inout [TBCMark]) {
        let spent = spendText(data)
        // 已花固定在第二列起点；主数字的最大宽度也固定，这样「已花」出现/消失时主数字不跳。
        let amountMax = secondColumnX - 12 - contentX
        let amount = fitMoney(data.balance, currency: data.currency,
                              maxWidth: amountMax,
                              sizes: [15.5, 14, 12.5, 11], weight: .semibold)
        marks.append(text("label.balance", "label", "余额", x: labelX, baseline: baseline1,
                          font: ui(10, .medium), color: TBCPalette.label, row: 1, cjk: true))
        marks.append(text("value.balance", "balance", amount.text, x: contentX, baseline: baseline1,
                          font: mono(amount.size, .semibold),
                          color: TBCPalette.primary, row: 1))
        if let spent = spent {
            marks.append(text("value.spent", "spent", spent,
                              x: secondColumnX, baseline: baseline1,
                              font: ui(9.5, .medium),
                              color: TBCPalette.tertiary, row: 1,
                              cjk: true))
        }
        usageRow(data, &marks)
        statusCorner(data, &marks)
    }

    /// C3 一言：一行；右端一句话说明现在贵不贵。
    /// 右侧全部是固定列（状态词 292 / 缓存右端 252 / 用量右端 190），
    /// 所以金额位数变化只会改变主数字自己的字号，永远不会推动右侧任何一列。
    private static func buildWhisper(_ data: TBCData, _ marks: inout [TBCMark]) {
        let state = status(of: data)
        let word = state.word ?? "未知"
        let wordFont = ui(9.5, .medium)
        marks.append(text("status", "status", word, right: rightEdge, baseline: baselineSingle,
                          font: wordFont, color: state.wordColor, row: 1, cjk: true))

        let cache = cacheText(data.todayCache)
        marks.append(text("value.cache", "cache", cache, right: whisperCacheRight,
                          baseline: baselineSingle, font: ui(9, .medium),
                          color: TBCPalette.tertiary, row: 1, cjk: true))

        let tokenValue = tokens(data.todayTokens)
        let tokenFont = mono(11, .medium)
        let unit = " tok"
        let unitFont = mono(8.5, .regular)
        let numberWidth = textWidth(tokenValue, font: tokenFont)
        let unitWidth = textWidth(unit, font: unitFont)
        let numberRight = whisperTokenRight - unitWidth - 1.5
        marks.append(text("value.today", "today", tokenValue, right: numberRight,
                          baseline: baselineSingle, font: tokenFont,
                          color: data.todayTokens == nil ? TBCPalette.tertiary : TBCPalette.secondary,
                          row: 1))
        if data.todayTokens != nil {
            marks.append(text("todayUnit", "today", unit, x: numberRight + 1.5,
                              baseline: baselineSingle, font: unitFont,
                              color: NSColor(calibratedWhite: 0.45, alpha: 1), row: 1))
        }
        _ = numberWidth

        let amount = fitMoney(data.balance, currency: data.currency,
                              maxWidth: whisperTokenRight - whisperTokenMaxWidth - 12 - whisperContentX,
                              sizes: [16.5, 15, 13.5, 12.5, 11.5], weight: .semibold)
        marks.append(text("value.balance", "balance", amount.text, x: whisperContentX,
                          baseline: baselineSingle, font: mono(amount.size, .semibold),
                          color: TBCPalette.primary, row: 1))
    }

    /// 两行变体共用的第二行：今日 tok + 缓存命中率。
    private static func usageRow(_ data: TBCData, _ marks: inout [TBCMark]) {
        marks.append(text("label.today", "label", "今日", x: labelX, baseline: baseline2,
                          font: ui(10, .medium), color: TBCPalette.label, row: 2, cjk: true))
        let tokenValue = tokens(data.todayTokens)
        let tokenFont = mono(11.5, .medium)
        marks.append(text("value.today", "today", tokenValue, x: contentX, baseline: baseline2,
                          font: tokenFont,
                          color: data.todayTokens == nil ? TBCPalette.tertiary : TBCPalette.secondary,
                          row: 2))
        if data.todayTokens != nil {
            marks.append(text("todayUnit", "today", " tok",
                              x: contentX + textWidth(tokenValue, font: tokenFont) + 1.5,
                              baseline: baseline2, font: mono(8.5, .regular),
                              color: TBCPalette.faint, row: 2))
        }
        marks.append(text("value.cache", "cache", cacheText(data.todayCache), right: rightEdge,
                          baseline: baseline2, font: ui(10, .medium),
                          color: TBCPalette.tertiary, row: 2, cjk: true))
    }

    /// 右端恒占一个位置：静息时是一颗时段光点（冷蓝=闲时，琥珀=高峰，灰=未知），
    /// 过期/无数据时光点熄灭、换成同样右对齐在 292 的词——异常必须说人话，不能靠猜。
    private static func statusCorner(_ data: TBCData, _ marks: inout [TBCMark]) {
        let state = status(of: data)
        if state == .stale || state == .noData, let word = state.word {
            marks.append(text("status", "status", word, right: rightEdge, baseline: baseline1,
                              font: ui(9.5, .medium), color: state.wordColor, row: 1, cjk: true))
            return
        }
        marks.append(dot("led", "led", center: NSPoint(x: rightEdge - ledSize / 2, y: ledCenterY),
                         diameter: ledSize, color: state.ledColor, row: 1))
    }

    /// 近 7 日微光带：只画到今天，未来的格子不画；0 视为「无记录」并断开折线。
    static func traceMark(_ data: TBCData) -> TBCMark? {
        guard !data.stale, !data.week.isEmpty else { return nil }
        let last = min(data.todayIndex, data.week.count - 1)
        guard last >= 0 else { return nil }
        let values = Array(data.week[0...last])
        guard values.contains(where: { $0 > 0 }) else { return nil }
        let peak = Double(values.max() ?? 0)
        guard peak > 0 else { return nil }

        let span = traceRight - traceLeft
        let step = values.count > 1 ? span / CGFloat(values.count - 1) : 0
        var segments: [[NSPoint]] = []
        var current: [NSPoint] = []
        var lastPoint: NSPoint? = nil
        for (index, value) in values.enumerated() {
            guard value > 0 else {
                if current.count > 0 { segments.append(current); current = [] }
                continue
            }
            let ratio = CGFloat((Double(value) / peak).squareRoot())
            let point = NSPoint(x: traceLeft + CGFloat(index) * step,
                                y: traceBase - max(1.2, (traceBase - traceTop) * ratio))
            current.append(point)
            lastPoint = point
        }
        if current.count > 0 { segments.append(current) }
        guard !segments.isEmpty else { return nil }

        var mark = TBCMark(kind: .trace, role: "trace", group: "trace", row: 1,
                           box: NSRect(x: traceLeft, y: traceTop, width: span,
                                       height: traceBase - traceTop))
        mark.segments = segments
        mark.baseY = traceBase
        mark.terminal = lastPoint
        mark.color = TBCPalette.traceBlue
        return mark
    }

    static func spendText(_ data: TBCData) -> String? {
        guard let balance = data.balance, let starting = data.startingBalance,
              starting >= balance else { return nil }
        let spent = starting - balance
        let limit = rightEdge - ledSize - 12 - secondColumnX
        let raw = "已花 " + money(spent, currency: data.currency)
        if textWidth(raw, font: ui(9.5, .medium)) <= limit { return raw }
        return "已花 " + compactMoney(spent, currency: data.currency)
    }
}

// MARK: - 视图

final class TBCView: NSView {
    var style: TBCStyle = .afterglow
    var data = TBCData()

    private lazy var peakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_PEAK_LOGO"] ?? "")
    private lazy var offPeakLogo: NSImage? = NSImage(contentsOfFile: ProcessInfo.processInfo.environment["QS_LOGO"] ?? "")

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: TBCEngine.width, height: TBCEngine.height) }

    override func draw(_ dirtyRect: NSRect) {
        let marks = TBCEngine.build(data, style: style)
        for mark in marks {
            switch mark.kind {
            case .logo: drawLogo()
            case .text: drawText(mark)
            case .dot: drawDot(mark)
            case .trace: drawTrace(mark)
            }
        }
    }

    private func drawLogo() {
        let image = data.phase == .peak ? peakLogo : offPeakLogo
        if let image = image {
            image.draw(in: TBCEngine.logoRect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        }
    }

    private func drawText(_ mark: TBCMark) {
        let attrs: [NSAttributedString.Key: Any] = [.font: mark.font, .foregroundColor: mark.color]
        (mark.text as NSString).draw(at: NSPoint(x: mark.box.minX, y: mark.baseline - mark.font.ascender),
                                     withAttributes: attrs)
    }

    private func drawDot(_ mark: TBCMark) {
        // 一点极淡的光晕，让它读成一颗「指示灯」而不是一个像素点；
        // 和微光带端点同一套语言，形状/颜色都不再额外表达别的含义。
        mark.color.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: mark.box.insetBy(dx: -1.3, dy: -1.3)).fill()
        mark.color.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: mark.box).fill()
    }

    private func drawTrace(_ mark: TBCMark) {
        guard !mark.segments.isEmpty else { return }
        // 光带底部一条极淡的地平线，让折线有落点，而不是浮在空气里。
        let base = NSRect(x: mark.box.minX, y: mark.baseY, width: mark.box.width, height: 0.6)
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        base.fill()

        for segment in mark.segments where segment.count >= 2 {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: segment[0].x, y: mark.baseY))
            for point in segment { area.line(to: point) }
            area.line(to: NSPoint(x: segment[segment.count - 1].x, y: mark.baseY))
            area.close()
            mark.color.withAlphaComponent(0.05).setFill()
            area.fill()
        }

        for segment in mark.segments {
            guard segment.count >= 2 else { continue }
            let halo = NSBezierPath()
            halo.lineWidth = 4.2
            halo.lineJoinStyle = .round
            halo.move(to: segment[0])
            for point in segment.dropFirst() { halo.line(to: point) }
            mark.color.withAlphaComponent(0.06).setStroke()
            halo.stroke()

            let line = NSBezierPath()
            line.lineWidth = 1
            line.lineJoinStyle = .round
            line.move(to: segment[0])
            for point in segment.dropFirst() { line.line(to: point) }
            mark.color.withAlphaComponent(0.55).setStroke()
            line.stroke()
        }

        if let terminal = mark.terminal,
           let last = mark.segments.last, last.count >= 1 {
            let color = mark.color
            color.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: NSRect(x: terminal.x - 3.2, y: terminal.y - 3.2,
                                        width: 6.4, height: 6.4)).fill()
            color.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: terminal.x - 1.4, y: terminal.y - 1.4,
                                        width: 2.8, height: 2.8)).fill()
        }
    }
}

// MARK: - 自检（布局越界 / 重叠 / 位数与状态切换稳定性）

enum TBCSelfCheck {
    struct Sample {
        var name: String
        var data: TBCData
    }

    static let week: [Int64] = [8_969_898, 106_515_375, 103_088_154, 6_774_405, 3_570_277, 0, 0]

    static func base(_ name: String) -> Sample {
        var data = TBCData()
        data.balance = Decimal(string: "50.95", locale: Locale(identifier: "en_US_POSIX"))
        data.startingBalance = Decimal(string: "71.11", locale: Locale(identifier: "en_US_POSIX"))
        data.todayTokens = 3_570_277
        data.todayCache = 78.6
        data.week = week
        data.todayIndex = 4
        data.phase = .offPeak
        return Sample(name: name, data: data)
    }

    static func money(_ value: String) -> Decimal? {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    static var samples: [Sample] {
        var list: [Sample] = [base("real-offpeak")]
        var peak = base("real-peak"); peak.data.phase = .peak; list.append(peak)
        var stale = base("real-stale"); stale.data.stale = true; list.append(stale)
        var unknown = base("real-unknown"); unknown.data.phase = .unknown; list.append(unknown)

        var digits100 = base("digits-100"); digits100.data.balance = money("100.00")
        digits100.data.startingBalance = money("200.00"); list.append(digits100)
        var digits95 = base("digits-9.5"); digits95.data.balance = money("9.50"); list.append(digits95)
        var digits1234 = base("digits-1234.56"); digits1234.data.balance = money("1234.56")
        digits1234.data.startingBalance = money("2000.00"); list.append(digits1234)
        var digitsBig = base("money-123456.78"); digitsBig.data.balance = money("123456.78")
        digitsBig.data.startingBalance = money("200000.00"); list.append(digitsBig)
        var zero = base("money-0.00"); zero.data.balance = money("0.00")
        zero.data.startingBalance = money("2000.00"); list.append(zero)
        var topup = base("topup"); topup.data.balance = money("80.00")
        topup.data.startingBalance = money("71.11"); list.append(topup)

        var tokensB = base("tokens-1b"); tokensB.data.todayTokens = 1_000_000_000
        tokensB.data.todayCache = 100; list.append(tokensB)
        var tokensSmall = base("tokens-999"); tokensSmall.data.todayTokens = 999
        tokensSmall.data.todayCache = 0; list.append(tokensSmall)
        var tokensNil = base("tokens-nil"); tokensNil.data.todayTokens = nil
        tokensNil.data.todayCache = nil; list.append(tokensNil)

        var weekOne = base("week-single"); weekOne.data.week = [5_000_000]
        weekOne.data.todayIndex = 0; list.append(weekOne)
        var weekGap = base("week-gap")
        weekGap.data.week = [5_000_000, 0, 3_000_000, 0, 2_000_000, 0, 0]
        weekGap.data.todayIndex = 4; list.append(weekGap)
        var weekEmpty = base("week-empty"); weekEmpty.data.week = []
        weekEmpty.data.todayIndex = 6; list.append(weekEmpty)

        var noData = Sample(name: "nodata", data: TBCData())
        noData.data.week = []; noData.data.todayIndex = 6; list.append(noData)
        var noDataStale = Sample(name: "nodata-stale", data: TBCData())
        noDataStale.data.stale = true; noDataStale.data.week = []; noDataStale.data.todayIndex = 6
        list.append(noDataStale)

        var usd = base("usd"); usd.data.currency = "USD"; list.append(usd)
        return list
    }

    private static func f(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    private static func signature(_ marks: [TBCMark], skipping: Set<String>) -> String {
        marks.filter { !skipping.contains($0.role) }
            .map { "\($0.role)@\(f($0.box.minX)),\(f($0.box.minY)),\(f($0.box.width)),\(f($0.box.height))#\($0.text)" }
            .joined(separator: "|")
    }

    static func inspect(_ marks: [TBCMark], style: TBCStyle, tag: String) -> (issues: [String], minGap: CGFloat) {
        var issues: [String] = []
        var minGap = CGFloat.greatestFiniteMagnitude

        guard let logo = marks.first, logo.kind == .logo else {
            return (["\(tag) 缺少 logo 图元"], 0)
        }
        if logo.box != TBCEngine.logoRect {
            issues.append("\(tag) logo 几何被改动 \(logo.box)")
        }

        for mark in marks where mark.kind != .logo {
            if mark.box.isNull || mark.box.isInfinite || mark.box.width.isNaN || mark.box.height.isNaN {
                issues.append("\(tag) \(mark.role) 图元矩形非法")
                continue
            }
            if mark.box.minX < 33.5 {
                issues.append("\(tag) \(mark.role) 左越界 x=\(f(mark.box.minX))")
            }
            if mark.box.maxX > 292.6 {
                issues.append("\(tag) \(mark.role) 右越界 x=\(f(mark.box.maxX))")
            }
            if mark.box.minY < 0.35 || mark.box.maxY > 29.65 {
                issues.append("\(tag) \(mark.role) 纵向越界 y=\(f(mark.box.minY))..\(f(mark.box.maxY))")
            }
            if mark.kind == .text {
                if mark.text.isEmpty { issues.append("\(tag) \(mark.role) 文本为空") }
                let measured = TBCEngine.textWidth(mark.text, font: mark.font)
                if abs(measured - mark.box.width) > 0.02 {
                    issues.append("\(tag) \(mark.role) 文本宽度与实测不符 \(f(measured)) vs \(f(mark.box.width))")
                }
            }
            if mark.kind == .dot && mark.box.width < 1.5 {
                issues.append("\(tag) \(mark.role) 光点过小")
            }
        }

        let body = marks.filter { $0.kind != .logo }
        for i in 0..<body.count {
            for j in (i + 1)..<body.count {
                let a = body[i], b = body[j]
                if a.box.insetBy(dx: 0.05, dy: 0.05).intersects(b.box.insetBy(dx: 0.05, dy: 0.05)) {
                    issues.append("\(tag) \(a.role) 与 \(b.role) 重叠")
                }
                let vOverlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
                guard vOverlap > 0.5, a.group != b.group else { continue }
                let gap: CGFloat
                if a.box.maxX <= b.box.minX {
                    gap = b.box.minX - a.box.maxX
                } else if b.box.maxX <= a.box.minX {
                    gap = a.box.minX - b.box.maxX
                } else {
                    gap = -1
                }
                if gap < 0 {
                    issues.append("\(tag) \(a.role) 与 \(b.role) 同排交叠")
                } else {
                    minGap = min(minGap, gap)
                }
            }
        }

        // 固定锚点：位数变化只能往左/右长，不能挪动右对齐列。
        if style != .whisper {
            if let cache = marks.first(where: { $0.role == "value.cache" }), abs(cache.box.maxX - 292) > 0.05 {
                issues.append("\(tag) 缓存列右端 = \(f(cache.box.maxX))，应为 292")
            }
        }
        if let word = marks.first(where: { $0.role == "status" }), abs(word.box.maxX - 292) > 0.05 {
            issues.append("\(tag) 状态词右端 = \(f(word.box.maxX))，应为 292")
        }
        let corner = marks.filter { $0.role == "led" || $0.role == "status" }
        if corner.count > 1 {
            issues.append("\(tag) 右端同时出现光点和状态词")
        }
        if corner.isEmpty {
            issues.append("\(tag) 右端没有状态通道")
        }
        if let led = marks.first(where: { $0.role == "led" }), abs(led.box.maxX - 292) > 0.05 {
            issues.append("\(tag) 状态光点右端 = \(f(led.box.maxX))，应为 292")
        }
        if let label = marks.first(where: { $0.role == "label.balance" }), abs(label.box.minX - 36) > 0.05 {
            issues.append("\(tag) 标签列 = \(f(label.box.minX))，应为 36")
        }
        if style == .quiet, let spent = marks.first(where: { $0.role == "value.spent" }) {
            if abs(spent.box.minX - TBCEngine.secondColumnX) > 0.05 {
                issues.append("\(tag) 已花列 = \(f(spent.box.minX))，应为 168")
            }
            if spent.box.maxX > TBCEngine.rightEdge - TBCEngine.ledSize - 6 {
                issues.append("\(tag) 已花挤到右端状态位")
            }
        }
        if let balance = marks.first(where: { $0.role == "value.balance" }) {
            let anchor = style == .whisper ? TBCEngine.whisperContentX : 66
            if abs(balance.box.minX - anchor) > 0.05 {
                issues.append("\(tag) 主数字左端 = \(f(balance.box.minX))，应为 \(f(anchor))")
            }
            if balance.text.contains("%") {
                issues.append("\(tag) 主数字出现百分比字符")
            }
        } else {
            issues.append("\(tag) 缺少主数字")
        }

        // 状态必须显式，不能靠猜（由 run() 统一检查）。
        if minGap == .greatestFiniteMagnitude { minGap = 999 }
        return (issues, minGap)
    }

    struct Report {
        var issues: [String]
        var rows: [(String, CGFloat, String, CGFloat)]
        var digits: [String]
        var layouts: Int
    }

    static func run() -> Report {
        var issues: [String] = []
        var rows: [(String, CGFloat, String, CGFloat)] = []
        var digits: [String] = []
        var layouts = 0

        for sample in samples {
            for style in TBCStyle.allCases {
                let tag = "\(sample.name)/\(style.title)"
                let marks = TBCEngine.build(sample.data, style: style)
                layouts += 1
                let result = inspect(marks, style: style, tag: tag)
                issues.append(contentsOf: result.issues)
                let balance = marks.first { $0.role == "value.balance" }
                rows.append((tag, result.minGap, balance?.text ?? "-", balance?.font.pointSize ?? 0))

                // 状态必须始终显式：无数据 / 过期 时必须有状态词。
                let state = TBCEngine.status(of: sample.data)
                if state == .noData || state == .stale {
                    let hasWord = marks.contains { $0.role == "status" }
                    if !hasWord { issues.append("\(tag) 缺少状态词") }
                }
                if state == .noData {
                    let dashes = marks.filter { $0.kind == .text && $0.role.hasPrefix("value.") }
                    if !dashes.allSatisfy({ $0.text == "—" || $0.text.hasPrefix("缓存 —") }) {
                        issues.append("\(tag) 无数据时仍渲染了数字")
                    }
                }
                // 有过期标记时，不能同时假装数据是新鲜的（暖色实心点 = 高峰）。
                if state == .stale {
                    if marks.contains(where: { $0.role == "led" }) {
                        issues.append("\(tag) 过期时仍亮着时段光点")
                    }
                    if !marks.contains(where: { $0.role == "status" }) {
                        issues.append("\(tag) 过期时没有状态词")
                    }
                }
            }

            // 时段切换不能挪动任何数字列。
            if sample.data.balance != nil {
                for style in TBCStyle.allCases {
                    var signatures: [String] = []
                    for phase in [DeepSeekPricePhase.peak, .offPeak, .unknown] {
                        var data = sample.data
                        data.phase = phase
                        signatures.append(signature(TBCEngine.build(data, style: style),
                                                    skipping: ["led", "status"]))
                    }
                    if Set(signatures).count != 1 {
                        issues.append("\(sample.name)/\(style.title) 时段切换导致布局位移")
                    }
                }
            }

            // 过期切换不能挪动数字列（C1 的微光带按设计隐藏，不参与比较）。
            if sample.data.balance != nil, !sample.data.stale {
                var staleData = sample.data
                staleData.stale = true
                for style in TBCStyle.allCases {
                    let fresh = signature(TBCEngine.build(sample.data, style: style),
                                          skipping: ["led", "status", "trace"])
                    let stale = signature(TBCEngine.build(staleData, style: style),
                                          skipping: ["led", "status", "trace"])
                    if fresh != stale {
                        issues.append("\(sample.name)/\(style.title) 过期切换导致布局位移")
                    }
                    if style == .afterglow, TBCEngine.traceMark(staleData) != nil {
                        issues.append("\(sample.name)/\(style.title) 过期时仍绘制微光带")
                    }
                }
            }
        }
        // 位数变化：9.50 → 100.00 → 1234.56，右侧所有列必须完全不动，只有主数字自己让步。
        let digitNames = ["digits-9.5", "digits-100", "digits-1234.56"]
        for style in TBCStyle.allCases {
            var signatures: [String] = []
            var sizes: [String] = []
            for name in digitNames {
                guard let sample = samples.first(where: { $0.name == name }) else { continue }
                let marks = TBCEngine.build(sample.data, style: style)
                signatures.append(signature(marks, skipping: ["value.balance", "value.spent"]))
                let balance = marks.first { $0.role == "value.balance" }
                let label = name.replacingOccurrences(of: "digits-", with: "")
                sizes.append("\(label)=\(balance?.text ?? "-")@\(f(balance?.font.pointSize ?? 0))")
            }
            if Set(signatures).count != 1 {
                issues.append("\(style.title) 金额位数变化导致右侧列位移")
            }
            digits.append("\(style.title) " + sizes.joined(separator: "  "))
        }
        return Report(issues: issues, rows: rows, digits: digits, layouts: layouts)
    }
}
