import AppKit

/// Money is shown as money, never as a made-up quota percentage.
final class DeepSeekBalanceView: NSView {
    static let viewWidth: CGFloat = 210
    private let icon = Bundle.main.path(forResource: "deepseek-logo", ofType: "png").flatMap { NSImage(contentsOfFile: $0) }
    var balance: DeepSeekBalance? { didSet { needsDisplay = true } }
    var message: String? { didSet { needsDisplay = true } }
    var stale = false { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: 30))
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        click.allowedTouchTypes = [.direct]
        addGestureRecognizer(click)
        setAccessibilityLabel(L("DeepSeek API balance", "DeepSeek API 余额"))
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.viewWidth, height: 30) }
    @objc private func tapped() { onTap?() }

    static func amount(_ raw: String, currency: String) -> String {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        // Keep tiny positive balances visibly distinct from an exhausted balance.
        if value > 0 && value < Decimal(string: "0.01")! {
            return currency + " <0.01"
        }
        return currency + " " + (formatter.string(from: NSDecimalNumber(decimal: value)) ?? raw)
    }

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: NSRect(x: 4, y: 2, width: 26, height: 26), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if stale {
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 9, y: 3, width: 5, height: 5)).fill()
        }
        guard let balance else {
            text(L("Balance", "余额"), y: 2, color: NSColor(white: 0.78, alpha: 1), size: 11.5)
            text(message ?? L("Loading…", "查询中…"), y: 17, color: .gray, size: 11)
            return
        }
        let color: NSColor = balance.is_available ? .white : .systemRed
        for (index, entry) in balance.balance_infos.prefix(2).enumerated() {
            row(label: balance.balance_infos.count > 1 ? entry.currency : L("Balance", "余额"),
                value: Self.amount(entry.total_balance, currency: entry.currency), top: index == 0, color: color)
        }
        if balance.balance_infos.count == 1, let entry = balance.balance_infos.first {
            row(label: L("Grant", "赠送"), value: Self.amount(entry.granted_balance, currency: entry.currency),
                top: false, color: NSColor(white: 0.78, alpha: 1))
        }
        let amounts = balance.balance_infos.map { Self.amount($0.total_balance, currency: $0.currency) }.joined(separator: " / ")
        setAccessibilityValue("DeepSeek \(amounts) \(message ?? "")")
    }

    private func row(label: String, value: String, top: Bool, color: NSColor) {
        let y: CGFloat = top ? 0.5 : 15.5
        text(label, y: y + 1.5, color: NSColor(white: 0.78, alpha: 1), size: 11.5, width: 48)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: NSRect(x: 85, y: y, width: 113, height: 15), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    private func text(_ value: String, y: CGFloat, color: NSColor, size: CGFloat,
                      x: CGFloat = 36, width: CGFloat = 164) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 15), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}
