import AppKit

/// 与 Codex item 同一节奏的余额条目：26pt 图标、两行、120pt 圆角进度条。
///
/// 图标随 DeepSeek 计费时段切换：高峰用 DSH App 的白色圆角底＋黑色鲸鱼，
/// 闲时用蓝色鲸鱼，年份节假日未知时退化为中性图标。
/// 进度条严格按“本轮充值后的余额”计算，基准未知时不画填充，而不是假装 0%。
final class DeepSeekTouchBarView: NSView {
    static let viewWidth: CGFloat = 300

    var onTap: (() -> Void)?

    private(set) var snapshot: DeepSeekSnapshot?
    private(set) var phase: DeepSeekPricePhase = DeepSeekPricingClock.phase()

    /// 闲时沿用 QuotaStrip 自带的蓝色鲸鱼。
    private let offPeakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo", ofType: "png")
        .flatMap { NSImage(contentsOfFile: $0) }
    /// 高峰用 DSH Dock 图标；构建时已从 App 的 icon.png 提取为 52×52。
    private lazy var peakLogo: NSImage? = Bundle.main.path(forResource: "deepseek-logo-peak", ofType: "png")
        .flatMap { NSImage(contentsOfFile: $0) } ?? Self.loadDSHDockIcon()

    private static let blue = NSColor(calibratedRed: 0.26, green: 0.48, blue: 1.0, alpha: 1)
    private static let green = NSColor(calibratedRed: 0.36, green: 0.83, blue: 0.64, alpha: 1)
    private static let smallAmount = Decimal(string: "0.01")!

    /// 一套常量管完整个排版，避免散落的魔法数字各改各的。
    /// 列节奏与 Codex 的 QuotaView 相同：36 起标签、76 起内容、292 收右边界。
    enum Layout {
        static let viewWidth: CGFloat = 300
        static let viewHeight: CGFloat = 30

        static let logoX: CGFloat = 4
        static let logoY: CGFloat = 2
        static let logoSize: CGFloat = 26

        static let labelX: CGFloat = 36

        /// 进度条与第二行 token 共用这个起点，视觉上才是一条竖线。
        /// 66 = 标签左缘 36 + 「余额」实测宽 22.8 + Codex 的 7.6pt 留白，
        /// 也就是沿用 Codex「标签→进度条」的视觉间距，只是标签本身更宽。
        static let contentX: CGFloat = 66
        static let barX: CGFloat = contentX

        /// Codex 的 QuotaView 实测：进度条起点 58、条长 120、百分比右边界 226。
        /// 也就是进度条 120pt 长，条尾到“百分比右边界”固定 48pt。
        /// DeepSeek 只是把标签→条形的留白对齐到 Codex，条长与“条尾→百分比”沿用同一组数值，
        /// 两边百分比与进度条之间的视觉留白因此完全一致。
        static let codexBarWidth: CGFloat = 120
        static let codexBarToPercent: CGFloat = 48
        static let barWidth: CGFloat = codexBarWidth
        static let barHeight: CGFloat = 9
        static let barY: CGFloat = 3

        static let tokenX: CGFloat = contentX
        /// 第一行最右侧列与第二行缓存共用这条右边界。
        static let rightEdge: CGFloat = 292

        /// 第一行现在是 [进度条] [金额] [百分比]：金额挪到原来百分比的位置，
        /// 百分比挪到最右列（原来是金额的位置），两者直接对调。
        static let amountRight: CGFloat = contentX + codexBarWidth + codexBarToPercent
        static let percentRight: CGFloat = rightEdge

        /// 金额与进度条之间至少留的间距。
        static let amountMinGap: CGFloat = 4

        static let firstRowY: CGFloat = 0.5
        static let secondRowY: CGFloat = 15.5
        static let minGap: CGFloat = 8

        static let staleDotSize: CGFloat = 5
        static let staleDotX: CGFloat = viewWidth - 6
        static let staleDotY: CGFloat = 1

        /// 两行的数值字号必须一致（用户要求「余额在上、今日在下，字体一样大」）。
        static let valueSize: CGFloat = 14
        /// 右侧的次要指标（缓存命中率 / 本月累计）。
        static let sideSize: CGFloat = 10.5
        static let valueX: CGFloat = contentX

        static let labelSize: CGFloat = 11.5
        static let percentSize: CGFloat = 13
        static let balanceSize: CGFloat = 11.5
        static let tokenSize: CGFloat = 13
        static let cacheSize: CGFloat = 11.5
    }

    init() {
        precondition(Thread.isMainThread)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: 30))
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        click.allowedTouchTypes = [.direct]
        addGestureRecognizer(click)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("DeepSeek 余额")
        setAccessibilityValue("余额 —，今日 tokens —，缓存命中率 —")
        setAccessibilityHelp("点击刷新 DeepSeek 余额与今日用量")
        toolTip = "点击刷新 DeepSeek 余额与今日用量"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    /// 卡片圆角要让 Touch Bar 的黑底透出来，所以这里必须是非不透明。
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.viewWidth, height: 30) }

    // MARK: - 数据更新

    func update(_ snapshot: DeepSeekSnapshot) {
        precondition(Thread.isMainThread)
        self.snapshot = snapshot
        var value = "余额 " + Self.amount(snapshot.balance, currency: snapshot.currency)
            + "，今日 tokens " + Self.tokens(usageTokens(snapshot))
            + "，本月 " + Self.tokens(snapshot.monthTokens)
            + "，缓存命中率 " + Self.cache(usageCache(snapshot))
        switch round() {
        case .known(let starting, let percent):
            value += "，本轮起始 " + Self.amount(starting, currency: snapshot.currency)
                + "，剩余 " + String(percent) + "%"
        case .waiting:
            value += "，余额高于已记录的起始余额"
        case .unknown:
            value += "，起始余额 —"
        }
        if snapshot.stale { value += "，数据可能已过期" }
        if let message = snapshot.message, !message.isEmpty { value += "，\(message)" }
        setAccessibilityValue(value)
        toolTip = value + "；点击刷新"
        needsDisplay = true
    }

    /// 由既有刷新定时器调用；只有时段真的变化时才重绘。
    func refreshPricingStatus(now: Date = Date()) {
        precondition(Thread.isMainThread)
        let current = DeepSeekPricingClock.phase(at: now)
        guard current != phase else { return }
        phase = current
        needsDisplay = true
    }

    @objc private func tapped() {
        precondition(Thread.isMainThread)
        onTap?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let action = onTap else { return false }
        action()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if let onTap = onTap {
            onTap()
        } else {
            super.mouseDown(with: event)
        }
    }

    // MARK: - 格式化

    /// 金额格式化保持 Decimal 精度；Double 只用于几何与比例。
    private static func amount(_ value: Decimal?, currency: String) -> String {
        guard var value = value, !value.isNaN else { return "—" }
        let prefix: String
        switch currency.uppercased() {
        case "CNY": prefix = "¥"
        case "USD": prefix = "$"
        default: prefix = currency.isEmpty ? "¤" : currency
        }
        if value != 0 && value < smallAmount && value > -smallAmount {
            return prefix + NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
        }
        // 千位以上压成 1.23K / 1.23M：百分比列已经占掉右边 48pt，四位数金额
        // 用原样的小数写法会压到百分比上。
        let magnitude = NSDecimalNumber(decimal: value).doubleValue
        if magnitude >= 1_000_000 { return prefix + String(format: "%.2fM", magnitude / 1_000_000) }
        if magnitude >= 100_000 { return prefix + String(format: "%.1fK", magnitude / 1_000) }
        if magnitude >= 1_000 { return prefix + String(format: "%.2fK", magnitude / 1_000) }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let rendered = formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
        return prefix + rendered
    }

    private static func tokens(_ value: Int64?) -> String {
        guard let value = value, value >= 0 else { return "—" }
        let n = Double(value)
        // 999,999,999 不能被写成 “1000.00M”：先按四舍五入判断是否该进位到更大的单位。
        if n >= 999_995_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 999_995 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
        return String(value)
    }

    /// DSH 用量页面的口径：命中率 = 缓存读取 /（输入 + 缓存读取）；缺失显示「—」。
    private static func cache(_ value: Double?) -> String {
        guard let value = value, value.isFinite, value >= 0 else { return "缓存 —" }
        return String(format: "缓存 %.1f%%", min(100, value))
    }

    /// 本月累计 token；缺失显示「本月 —」，绝不把未知写成 0。
    private static func month(_ value: Int64?) -> String {
        guard let value = value, value >= 0 else { return "本月 —" }
        return "本月 " + tokens(value)
    }

    // MARK: - 充值轮次

    enum Round {
        /// 基准可信：剩余百分比。
        case known(Decimal, Int)
        /// 余额高于基准：检测到尚未观察到的充值，本次不画进度条。
        case waiting
        case unknown
    }

    /// 本轮充值后的余额；未知时为 nil。
    private func effectiveStartingBalance() -> Decimal? {
        guard let value = snapshot?.startingBalance, !value.isNaN, value > 0 else { return nil }
        return value
    }

    func round() -> Round {
        guard let snapshot = snapshot,
              let balance = snapshot.balance, !balance.isNaN,
              let starting = effectiveStartingBalance() else { return .unknown }
        if starting < balance { return .waiting }
        let percent: Int
        if balance <= 0 {
            percent = 0
        } else if balance >= starting {
            percent = 100
        } else {
            let scaled = (balance * 100 / starting) as NSDecimalNumber
            percent = min(100, max(0, Int(scaled.doubleValue.rounded(.down))))
        }
        return .known(starting, percent)
    }

    /// nil 表示不画填充：未知轮次不能看起来像空（0%）进度。
    private var remainingRatio: Decimal? {
        switch round() {
        case .known(let starting, _):
            guard let balance = snapshot?.balance, balance > 0 else { return 0 }
            if balance >= starting { return 1 }
            var numerator = balance
            var denominator = starting
            var result = Decimal()
            let error = NSDecimalDivide(&result, &numerator, &denominator, .plain)
            guard error == .noError || error == .lossOfPrecision, !result.isNaN else { return nil }
            return result
        case .waiting, .unknown:
            return nil
        }
    }

    /// 低余额是警示色，其它情况保持 DeepSeek 蓝。
    private func accent(for percent: Int) -> NSColor {
        if percent <= 10 { return .systemRed }
        if percent <= 25 { return .systemYellow }
        return Self.blue
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        precondition(Thread.isMainThread)
        // 透明背景：整条 Touch Bar 统一黑底，模块只画自己的内容和进度条底轨。
        drawLogo()
        guard let snapshot = snapshot else {
            drawText("等待 DSH 数据…", at: NSPoint(x: Layout.labelX, y: 8), color: .gray, size: 12)
            return
        }

        drawBalanceRow(snapshot)
        drawUsageRow(snapshot)

        if snapshot.stale {
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: Layout.staleDotX, y: Layout.staleDotY,
                                       width: Layout.staleDotSize, height: Layout.staleDotSize)).fill()
        }
    }

    private func drawLogo() {
        let rect = NSRect(x: Layout.logoX, y: Layout.logoY,
                          width: Layout.logoSize, height: Layout.logoSize)
        switch phase {
        case .peak:
            if let icon = peakLogo {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            } else {
                drawPeakFallback(in: rect)
            }
        case .offPeak:
            if let icon = offPeakLogo {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            } else {
                drawText("◈", at: NSPoint(x: Layout.logoX + 2, y: 3), color: Self.blue, size: 19, weight: .bold)
            }
        case .unknown:
            drawText("◈", at: NSPoint(x: Layout.logoX + 2, y: 3), color: .systemGray, size: 19, weight: .bold)
        }
    }

    /// 打包资源缺失时，退回读正在运行的 DSH App 图标。
    private static func loadDSHDockIcon() -> NSImage? {
        let running = NSWorkspace.shared.runningApplications.first { app in
            let name = (app.localizedName ?? "").lowercased()
            return name.contains("deepseek") && name.contains("harness")
        }
        if let url = running?.bundleURL { return NSWorkspace.shared.icon(forFile: url.path) }
        for path in ["/Applications/DeepSeek Harness.app", NSHomeDirectory() + "/Applications/DeepSeek Harness.app"]
        where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }

    private func drawPeakFallback(in rect: NSRect) {
        NSColor(white: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        drawText("DS", at: NSPoint(x: rect.minX + 5, y: rect.minY + 7), color: .black,
                 size: 11, weight: .bold)
    }

    // MARK: 第一行：余额

    /// 第一行：余额（主数值，左对齐 66）+ 右侧缓存命中率。
    private func drawBalanceRow(_ data: DeepSeekSnapshot) {
        drawRow(row: Layout.firstRowY,
                label: "余额",
                value: Self.amount(data.balance, currency: data.currency),
                valueColor: Self.blue,
                side: Self.cache(usageCache(data)),
                sideColor: Self.green)
    }

    /// 第二行：优先跟随「当前模型」的今日 token，右侧标出模型短名；
    /// 当前模型未知时回退到今日总量 + 本月累计，绝不把未知写成 0。
    private func drawUsageRow(_ data: DeepSeekSnapshot) {
        let side = usageSide(data)
        drawRow(row: Layout.secondRowY,
                label: "今日",
                value: Self.tokens(usageTokens(data)) + " tok",
                valueColor: NSColor(white: 0.95, alpha: 1),
                side: side.text,
                sideColor: side.color)
    }

    /// 第二行主数值：当前模型已知就用它的今日 token，否则用今日总量。
    private func usageTokens(_ data: DeepSeekSnapshot) -> Int64? {
        if data.currentModel != nil, let count = data.currentModelTokens { return count }
        return data.todayTokens
    }

    /// 第一行右侧缓存命中率：当前模型已知就用它的缓存（全 provider 口径），
    /// 否则回退 DeepSeek 今日口径；这样切到非 DeepSeek 模型时缓存列不会空。
    private func usageCache(_ data: DeepSeekSnapshot) -> Double? {
        if let model = data.currentModel, let hit = data.todayModelCacheHit[model] { return hit }
        return data.todayCacheHitPercent
    }

    /// 第二行右侧：保持原来的本月累计（不在 Touch Bar 上露模型名）；
    /// 「跟随当前模型」只体现在左侧主数值（usageTokens），不改变排版。
    private func usageSide(_ data: DeepSeekSnapshot) -> (text: String, color: NSColor) {
        return (Self.month(data.monthTokens), NSColor(white: 0.62, alpha: 1))
    }

    /// 两行共用同一套列：标签 36、数值 66、右侧指标右对齐 292。
    private func drawRow(row: CGFloat, label: String, value: String,
                         valueColor: NSColor, side: String, sideColor: NSColor) {
        drawLabel(label, row: row)
        let sideLeft = Layout.rightEdge - textWidth(side, size: Layout.sideSize, weight: .medium)
        let valueWidth = fitted(value, sizes: Self.valueSizes,
                                maxWidth: max(0, sideLeft - Layout.minGap - Layout.valueX),
                                weight: .semibold).size
        drawText(value, at: NSPoint(x: Layout.valueX,
                                    y: alignedY(row, size: valueWidth, weight: .semibold)),
                 color: valueColor, size: valueWidth, weight: .semibold)
        rightText(side, right: Layout.rightEdge,
                  y: alignedY(row, size: Layout.sideSize, weight: .medium),
                  color: sideColor, size: Layout.sideSize, weight: .medium)
    }

    // MARK: 自检：实际文字宽度与列间距

    struct LayoutReport {
        let labelToValue: CGFloat
        let valueToSide: CGFloat
        var minimumGap: CGFloat { min(labelToValue, valueToSide) }
        var fits: Bool { minimumGap >= 4 }
    }

    /// 数值允许缩到的字号，从大到小；放不下时先缩字号，绝不截断数字。
    private static let valueSizes: [CGFloat] = [Layout.valueSize, 12, 11]

    /// 在候选字号里挑第一个放得进 maxWidth 的；都不行就用最小的（再由绘制端夹住左界）。
    private func fitted(_ value: String, sizes: [CGFloat], maxWidth: CGFloat,
                        weight: NSFont.Weight) -> (size: CGFloat, width: CGFloat) {
        for size in sizes {
            let width = textWidth(value, size: size, weight: weight)
            if width <= maxWidth { return (size, width) }
        }
        let size = sizes[sizes.count - 1]
        return (size, textWidth(value, size: size, weight: weight))
    }

    /// 给测试用：用 NSString.size(withAttributes:) 量真实宽度，而不是相信坐标。
    func layoutReport(for data: DeepSeekSnapshot) -> LayoutReport {
        precondition(Thread.isMainThread)
        let labelWidth = textWidth("余额", size: Layout.labelSize, weight: .regular)
        let balance = fitted(Self.amount(data.balance, currency: data.currency),
                             sizes: Self.valueSizes, maxWidth: .greatestFiniteMagnitude,
                             weight: .semibold)
        let cacheWidth = textWidth(Self.cache(usageCache(data)),
                                   size: Layout.sideSize, weight: .medium)
        let token = fitted(Self.tokens(usageTokens(data)) + " tok",
                           sizes: Self.valueSizes, maxWidth: .greatestFiniteMagnitude,
                           weight: .semibold)
        let sideWidth = textWidth(usageSide(data).text, size: Layout.sideSize, weight: .medium)
        return LayoutReport(
            labelToValue: Layout.valueX - (Layout.labelX + labelWidth),
            valueToSide: min((Layout.rightEdge - cacheWidth) - (Layout.valueX + balance.width),
                             (Layout.rightEdge - sideWidth) - (Layout.valueX + token.width))
        )
    }

    // MARK: 文字绘制

    private func attributes(color: NSColor, size: CGFloat, weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
    }

    private func textWidth(_ value: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (value as NSString).size(withAttributes: attributes(color: .white, size: size, weight: weight)).width
    }

    /// 同一行里不同字号共用一个基线：以 13pt 百分比为基准，其他字号按 ascender 差下移。
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

    /// 在 minX..right 之间右对齐，按候选字号从大到小选第一个放得下的。
    private func rightTextFitting(_ value: String, right: CGFloat, minX: CGFloat, y: CGFloat,
                                  color: NSColor, sizes: [CGFloat], weight: NSFont.Weight) {
        for size in sizes {
            let attrs = attributes(color: color, size: size, weight: weight)
            let width = (value as NSString).size(withAttributes: attrs).width
            if width <= right - minX || size == sizes.last {
                (value as NSString).draw(at: NSPoint(x: max(minX, right - width), y: y), withAttributes: attrs)
                return
            }
        }
    }

    private func rightText(_ value: String, right: CGFloat, y: CGFloat, color: NSColor,
                           size: CGFloat, weight: NSFont.Weight = .regular) {
        let attrs = attributes(color: color, size: size, weight: weight)
        let width = (value as NSString).size(withAttributes: attrs).width
        (value as NSString).draw(at: NSPoint(x: max(0, right - width), y: y), withAttributes: attrs)
    }
}
