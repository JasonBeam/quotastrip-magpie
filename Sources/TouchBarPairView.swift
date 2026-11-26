import AppKit

/// Codex、Magpie 实时模块（必选）与 DeepSeek 紧凑模块（可选）合并成一个 item，
/// 把系统相邻 item 的 8pt 间距收到 3pt；各子视图点击手势原样保留。
/// 默认 Codex + Magpie = 603pt；打开 DeepSeek 后 685pt，正好是本机 Touch Bar 可用宽。
///
/// 刻意不在容器上添加手势：中间的 3pt 空白点下去只会命中容器本身（无手势），
/// 各子视图的命中区与视觉区因此完全一致。
final class TouchBarPairView: NSView {
    /// 模块之间的目标间距。
    static let gap: CGFloat = 3
    static let itemHeight: CGFloat = 30
    /// Codex + Magpie（默认）。
    static let baseWidth: CGFloat = QuotaView.viewWidth + gap + MagpieLiveTouchBarView.viewWidth
    /// 再打开 DeepSeek 时的全宽。
    static let fullWidth: CGFloat = baseWidth + gap + DeepSeekPercentView.viewWidth
    /// 兼容旧测试/渲染的别名。
    static let pairWidth: CGFloat = QuotaView.viewWidth + gap + DeepSeekTouchBarView.viewWidth
    static let itemWidth: CGFloat = baseWidth

    let codexView: QuotaView
    let deepSeekView: DeepSeekPercentView
    let magpieView: MagpieLiveTouchBarView
    /// DeepSeek 模块可选：默认不显示（菜单可开）。
    var showsDeepSeek = false {
        didSet {
            guard showsDeepSeek != oldValue else { return }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }
    var currentWidth: CGFloat { showsDeepSeek ? Self.fullWidth : Self.baseWidth }

    init(codex: QuotaView, deepSeek: DeepSeekPercentView, magpie: MagpieLiveTouchBarView) {
        self.codexView = codex
        self.deepSeekView = deepSeek
        self.magpieView = magpie
        super.init(frame: NSRect(x: 0, y: 0, width: Self.baseWidth, height: Self.itemHeight))
        for child in [codex as NSView, magpie as NSView, deepSeek as NSView] {
            child.translatesAutoresizingMaskIntoConstraints = true
            child.autoresizingMask = []
            addSubview(child)
        }
        deepSeek.isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: currentWidth, height: Self.itemHeight) }

    /// 手工摆放子视图：Touch Bar 给的是固定 30pt 高，用 frame 比约束更可预测，
    /// 也保证子视图的点击命中区就是它自己的矩形。宽度不足时按优先级隐藏末模块。
    override func layout() {
        super.layout()
        let height = bounds.height > 0 ? bounds.height : Self.itemHeight
        codexView.frame = NSRect(x: 0, y: 0, width: QuotaView.viewWidth, height: height)
        magpieView.frame = NSRect(x: QuotaView.viewWidth + Self.gap, y: 0,
                                  width: MagpieLiveTouchBarView.viewWidth, height: height)
        deepSeekView.isHidden = !showsDeepSeek
        if showsDeepSeek {
            deepSeekView.frame = NSRect(x: Self.baseWidth + Self.gap, y: 0,
                                        width: DeepSeekPercentView.viewWidth, height: height)
        }
    }

    /// 命中判定，给测试用：传入容器坐标，返回命中的视图（子视图或容器自身）。
    func hitTest(containerPoint: NSPoint) -> NSView? {
        hitTest(containerPoint)
    }
}
