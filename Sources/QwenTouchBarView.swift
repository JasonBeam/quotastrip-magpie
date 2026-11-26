import AppKit

/// 紧凑「剩余百分比」Touch Bar 模块：✦/品牌徽标 + 标签 + 剩余% 大数字。
/// 千问与 DeepSeek 共用同一套显示逻辑（剩余%、>50 白 / 21–50 黄 / ≤20 红、stale 黄点）。
class PercentTouchBarView: NSView {
    /// 紧凑宽：603pt 双模块 + 3 + 79 = 685pt，正好放进本机 Touch Bar 可用宽度。
    static let viewWidth: CGFloat = 79
    static let viewHeight: CGFloat = 30

    /// 模块标签（千问 / DeepSeek）。
    var label: String { didSet { needsDisplay = true } }
    /// 徽标颜色；nil 时画四角星。
    var badgeColor: NSColor { didSet { needsDisplay = true } }
    var badgeImage: NSImage? { didSet { needsDisplay = true } }
    /// 剩余百分比；nil = 暂无数据（显示 —，不猜 100）。
    var remainingPercent: Double? { didSet { needsDisplay = true } }
    var stale = false { didSet { needsDisplay = true } }
    var message: String? { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?

    init(label: String, badgeColor: NSColor, badgeImage: NSImage? = nil) {
        self.label = label
        self.badgeColor = badgeColor
        self.badgeImage = badgeImage
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        click.allowedTouchTypes = [.direct]
        addGestureRecognizer(click)
        setAccessibilityLabel(label + " " + L("remaining", "剩余"))
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.viewWidth, height: Self.viewHeight) }
    @objc private func tapped() { onTap?() }

    /// 与 Codex/DeepSeek 模块一致的颜色语义：>50 白、21–50 黄、≤20 红。
    static func color(for percent: Double) -> NSColor {
        if percent > 50 { return .white }
        if percent > 20 { return .systemYellow }
        return .systemRed
    }

    override func draw(_ dirtyRect: NSRect) {
        if let badgeImage {
            badgeImage.draw(in: NSRect(x: 3, y: 7, width: 16, height: 16), from: .zero,
                            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            // ✦ 徽标（画出来的四角星，不依赖图片资源）。
            let star = NSBezierPath()
            let cx: CGFloat = 11, cy: CGFloat = 15, outer: CGFloat = 7.5, inner: CGFloat = 2.7
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4 - .pi / 2
                let radius = index % 2 == 0 ? outer : inner
                let point = NSPoint(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
                if index == 0 { star.move(to: point) } else { star.line(to: point) }
            }
            star.close()
            badgeColor.setFill()
            star.fill()
        }

        if stale {
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 9, y: 3, width: 5, height: 5)).fill()
        }

        text(label, y: 2, color: NSColor(white: 0.78, alpha: 1), size: 10)
        guard let percent = remainingPercent else {
            text(message ?? L("No data", "暂无数据"), y: 15, color: .gray, size: 11)
            setAccessibilityValue(message ?? "no data")
            return
        }
        let value = String(Int(min(max(percent, 0), 100).rounded())) + "%"
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        (value as NSString).draw(in: NSRect(x: 24, y: 12, width: Self.viewWidth - 28, height: 17),
                                 withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
            .foregroundColor: Self.color(for: percent),
            .paragraphStyle: style,
        ])
        setAccessibilityValue("\(label) \(value)")
    }

    private func text(_ value: String, y: CGFloat, color: NSColor, size: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: NSRect(x: 24, y: y, width: Self.viewWidth - 27, height: 13),
                                 withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}

/// 千问 Token Plan 模块：朋友只读接口 remaining 主源。
final class QwenTouchBarView: PercentTouchBarView {
    init() {
        super.init(label: L("Qwen", "千问"),
                   badgeColor: NSColor(calibratedRed: 0.45, green: 0.35, blue: 1, alpha: 1))
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// DeepSeek 模块：与千问同一套剩余%逻辑（本轮起始余额为分母）；可选显示。
final class DeepSeekPercentView: PercentTouchBarView {
    init() {
        let logo = Bundle.main.path(forResource: "deepseek-logo", ofType: "png")
            .flatMap { NSImage(contentsOfFile: $0) }
        super.init(label: "DeepSeek",
                   badgeColor: NSColor(calibratedRed: 0.26, green: 0.48, blue: 1, alpha: 1),
                   badgeImage: logo)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Magpie 实时模块：套用 DSH 余额模板（DeepSeekTouchBarView 同一套列节奏），
/// 换 Magpie logo（与 Codex 图标同尺寸 26pt）、换数据源，不画进度条。
/// 第一行：剩余% 大数字（一位小数，直接对接 TokenPlan 剩余）+ 今日 token；
/// 第二行：当前对话 tok/s（DSH 口径：输出÷解码时长）+ 模型 + 缓存命中率。
/// 数据来自 Magpie 本机只读接口；DSH 服务与数据管线原样保留，只是不画在这个模块上。
final class MagpieLiveTouchBarView: NSView {
    static let viewWidth: CGFloat = 300
    static let viewHeight: CGFloat = 30

    struct Data {
        /// TokenPlan 剩余百分比（朋友源主、Magpie qwen 兜底）；nil = 暂无数据。
        var remainingPercent: Double?
        /// 今日 token（DSH 用量口径，经 Magpie requests 交叉核对一致）。
        var todayTokens: Int64?
        /// 当前对话最近一次成功请求。
        var model: String?
        var sessionTokens: Int64?
        var sessionCacheHit: Double?
        /// DSH 口径 tok/s；无计时数据时为 nil，显示「—」。
        var tokensPerSecond: Double?
        var requestAt: Date?
        var stale = false
    }

    var data = Data() { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?

    private let logo: NSImage? = Bundle.main.path(forResource: "magpie-logo", ofType: "png")
        .flatMap { NSImage(contentsOfFile: $0) }

    /// 列节奏与 DeepSeekTouchBarView / Codex QuotaView 一致：
    /// logo 4/2/26、标签 36、内容 66、右边界 292；两行基线 0.5 / 15.5。
    private enum Layout {
        static let logoX: CGFloat = 4
        static let logoY: CGFloat = 2
        static let logoSize: CGFloat = 26
        static let labelX: CGFloat = 36
        static let contentX: CGFloat = 66
        static let sideRight: CGFloat = 292
        static let firstRowY: CGFloat = 0.5
        static let secondRowY: CGFloat = 15.5
        static let labelSize: CGFloat = 11.5
        /// 余额大数字：与 DSH 模板主数值同档（14），一位小数。
        static let percentSize: CGFloat = 14
        static let valueSize: CGFloat = 13
        static let sideSize: CGFloat = 10.5
        static let minGap: CGFloat = 6
    }

    init() {
        precondition(Thread.isMainThread)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        click.allowedTouchTypes = [.direct]
        addGestureRecognizer(click)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Magpie " + L("quota", "额度"))
        toolTip = L("Tap to refresh Magpie / Token Plan", "点击刷新 Magpie / Token Plan")
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.viewWidth, height: Self.viewHeight) }

    @objc private func tapped() { onTap?() }
    override func accessibilityPerformPress() -> Bool {
        guard let action = onTap else { return false }
        action()
        return true
    }
    override func mouseDown(with event: NSEvent) {
        if let onTap { onTap() } else { super.mouseDown(with: event) }
    }

    /// 与 Codex/DeepSeek 模块一致的颜色语义：>50 白、21–50 黄、≤20 红。
    static func color(for percent: Double) -> NSColor {
        PercentTouchBarView.color(for: percent)
    }

    override func draw(_ dirtyRect: NSRect) {
        precondition(Thread.isMainThread)
        if let logo {
            logo.draw(in: NSRect(x: Layout.logoX, y: Layout.logoY,
                                 width: Layout.logoSize, height: Layout.logoSize),
                      from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        } else {
            drawText("◆", at: NSPoint(x: Layout.logoX + 4, y: 5),
                     color: NSColor(calibratedRed: 0.45, green: 0.35, blue: 1, alpha: 1),
                     size: 18, weight: .bold)
        }

        drawPlanRow()
        drawSessionRow()

        if data.stale {
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: Self.viewWidth - 6, y: 1, width: 5, height: 5)).fill()
        }
        setAccessibilityValue(accessibilitySummary())
    }

    // MARK: 第一行：余额 = 剩余% 大数字（无条形图）+ 今日 token

    private func drawPlanRow() {
        drawLabel(L("Plan", "剩余"), row: Layout.firstRowY)
        let side = L("今日 ", "今日 ") + Self.tokensShort(data.todayTokens)
        let sideLeft = Layout.sideRight - textWidth(side, size: Layout.sideSize, weight: .medium)
        if let percent = data.remainingPercent {
            let clamped = min(max(percent, 0), 100)
            let value = String(format: "%.1f%%", clamped)
            let size = fitted(value, sizes: [Layout.percentSize, 13, 12],
                              maxWidth: max(0, sideLeft - Layout.minGap - Layout.contentX),
                              weight: .bold)
            drawText(value, at: NSPoint(x: Layout.contentX,
                                        y: alignedY(Layout.firstRowY, size: size, weight: .bold)),
                     color: Self.color(for: clamped), size: size, weight: .bold)
        } else {
            drawText("—", at: NSPoint(x: Layout.contentX,
                                      y: alignedY(Layout.firstRowY, size: Layout.percentSize, weight: .bold)),
                     color: .gray, size: Layout.percentSize, weight: .bold)
        }
        rightText(side, right: Layout.sideRight,
                  y: alignedY(Layout.firstRowY, size: Layout.sideSize, weight: .medium),
                  color: NSColor(white: 0.62, alpha: 1), size: Layout.sideSize, weight: .medium)
    }

    // MARK: 第二行：当前对话 tok/s + 模型 + 缓存

    private func drawSessionRow() {
        drawLabel(L("Now", "对话"), row: Layout.secondRowY)
        let rate = Self.formatTps(data.tokensPerSecond)
        let side = sessionSideText()
        let sideLeft = Layout.sideRight - textWidth(side, size: Layout.sideSize, weight: .medium)
        let fittedSize = fitted(rate, sizes: [Layout.valueSize, 12, 11],
                                maxWidth: max(0, sideLeft - Layout.minGap - Layout.contentX),
                                weight: .semibold)
        drawText(rate, at: NSPoint(x: Layout.contentX,
                                   y: alignedY(Layout.secondRowY, size: fittedSize, weight: .semibold)),
                 color: NSColor(white: 0.95, alpha: 1), size: fittedSize, weight: .semibold)
        rightText(side, right: Layout.sideRight,
                  y: alignedY(Layout.secondRowY, size: Layout.sideSize, weight: .medium),
                  color: NSColor(white: 0.62, alpha: 1), size: Layout.sideSize, weight: .medium)
    }

    /// DSH formatTokensPerSecond 口径：≥10 取整、<10 一位小数；缺失「—」。
    static func formatTps(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let number = value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return number + " tok/s"
    }

    /// 右侧：模型短名 + 该请求缓存命中率；模型未知时只显示缓存或占位。
    private func sessionSideText() -> String {
        var parts: [String] = []
        if let model = data.model, !model.isEmpty { parts.append(model) }
        if let hit = data.sessionCacheHit, hit.isFinite {
            parts.append(L("cache ", "缓存 ") + String(format: "%.0f%%", min(100, max(0, hit))))
        }
        return parts.isEmpty ? L("no session", "无对话") : parts.joined(separator: " · ")
    }

    private func accessibilitySummary() -> String {
        var parts: [String] = []
        if let percent = data.remainingPercent {
            parts.append(L("remaining ", "剩余 ") + String(format: "%.1f%%", percent))
        } else {
            parts.append(L("no plan data", "暂无额度数据"))
        }
        parts.append(L("today ", "今日 ") + Self.tokensShort(data.todayTokens))
        if let model = data.model { parts.append(model) }
        if let tps = data.tokensPerSecond { parts.append(String(format: "%.1f tok/s", tps)) }
        if let hit = data.sessionCacheHit { parts.append(String(format: "cache %.0f%%", hit)) }
        return parts.joined(separator: ", ")
    }

    // MARK: 格式化 / 文字绘制（与 DeepSeekTouchBarView 同一套算法）

    /// Touch Bar 侧列用紧凑单位（与面板「万」口径一致）：4719万、1.2亿。
    static func tokensShort(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        let n = Double(value)
        if n >= 99_995_000 { return String(format: "%.1f亿", n / 100_000_000) }
        if n >= 10_000 { return String(format: "%.0f万", n / 10_000) }
        return String(value)
    }

    private func attributes(color: NSColor, size: CGFloat, weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
         .foregroundColor: color]
    }

    private func textWidth(_ value: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (value as NSString).size(withAttributes: attributes(color: .white, size: size, weight: weight)).width
    }

    private func fitted(_ value: String, sizes: [CGFloat], maxWidth: CGFloat, weight: NSFont.Weight) -> CGFloat {
        for size in sizes where textWidth(value, size: size, weight: weight) <= maxWidth { return size }
        return sizes[sizes.count - 1]
    }

    private func alignedY(_ row: CGFloat, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let reference = NSFont.monospacedDigitSystemFont(ofSize: Layout.percentSize, weight: .bold)
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return row + (reference.ascender - font.ascender)
    }

    private func drawLabel(_ value: String, row: CGFloat) {
        drawText(value, at: NSPoint(x: Layout.labelX,
                                    y: alignedY(row, size: Layout.labelSize, weight: .regular)),
                 color: NSColor(white: 0.78, alpha: 1), size: Layout.labelSize)
    }

    private func drawText(_ value: String, at point: NSPoint, color: NSColor,
                          size: CGFloat, weight: NSFont.Weight = .regular) {
        (value as NSString).draw(at: point, withAttributes: attributes(color: color, size: size, weight: weight))
    }

    private func rightText(_ value: String, right: CGFloat, y: CGFloat, color: NSColor,
                           size: CGFloat, weight: NSFont.Weight = .regular) {
        let attrs = attributes(color: color, size: size, weight: weight)
        let width = (value as NSString).size(withAttributes: attrs).width
        (value as NSString).draw(at: NSPoint(x: max(0, right - width), y: y), withAttributes: attrs)
    }
}
