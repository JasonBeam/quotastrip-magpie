// QuotaStrip — show Codex quota on the MacBook Pro Touch Bar.
// Lives in the Touch Bar via the DFR private API (same mechanism as MTMR / Pock);
// data comes from quota.py (bundled in Resources). System Control Strip is kept on the right.
import AppKit
import ServiceManagement

// MARK: - DFR private API

@_silgen_name("DFRElementSetControlStripPresenceForIdentifier")
func DFRElementSetControlStripPresenceForIdentifier(_ identifier: NSString, _ visible: Bool)

@_silgen_name("DFRSystemModalShowsCloseBoxWhenFrontMost")
func DFRSystemModalShowsCloseBoxWhenFrontMost(_ show: Bool)

let trayIdentifier = NSTouchBarItem.Identifier("app.quotastrip.QuotaStrip.tray")

func presentSystemModal(_ bar: NSTouchBar, trayId: NSTouchBarItem.Identifier) {
    // placement=0 keeps the system Control Strip; placement=1 takes over the full width.
    let placementSel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    if let method = class_getClassMethod(NSTouchBar.self, placementSel) {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, Int64, AnyObject?) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        // With the Control Strip kept, the system forces a close box (X) at the far left:
        // tap X to dismiss the panel, tap the gauge icon in the Control Strip to bring it back.
        fn(NSTouchBar.self, placementSel, bar, 0, trayId.rawValue as AnyObject)
        return
    }
    let cls: AnyObject = NSTouchBar.self as AnyObject
    let newSel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    let oldSel = NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:")
    if cls.responds(to: newSel) {
        _ = cls.perform(newSel, with: bar, with: trayId.rawValue)
    } else if cls.responds(to: oldSel) {
        _ = cls.perform(oldSel, with: bar, with: trayId.rawValue)
    }
}

func dismissSystemModal(_ bar: NSTouchBar) {
    let cls: AnyObject = NSTouchBar.self as AnyObject
    for name in ["dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"] {
        let sel = NSSelectorFromString(name)
        if cls.responds(to: sel) {
            _ = cls.perform(sel, with: bar)
            return
        }
    }
}

func addSystemTrayItem(_ item: NSTouchBarItem) {
    let cls: AnyObject = NSTouchBarItem.self as AnyObject
    let sel = NSSelectorFromString("addSystemTrayItem:")
    if cls.responds(to: sel) {
        _ = cls.perform(sel, with: item)
    }
}

// MARK: - Shared paths

enum Paths {
    static let cacheDir = NSHomeDirectory() + "/.cache/quotastrip/"
    static let fetchLog = cacheDir + "fetch.log"
}

// MARK: - Tiny localization (follows the system language)

let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

func L(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

// MARK: - Data model (matches quota.py json output)

struct QuotaWindow: Decodable {
    var pct: Double?   // nil = unknown (window reset but the live value can't be fetched yet)
    var reset: Double?
}

struct QuotaService: Decodable {
    var ok: Bool
    var stale: Bool?
    var five: QuotaWindow?
    var week: QuotaWindow?
    var attention: Bool?
    var source: String?
}

final class QuotaFetcher {
    // quota.py is bundled inside the app, so QuotaStrip.app runs from anywhere.
    private let scriptPath = Bundle.main.path(forResource: "quota", ofType: "py")
    private let appServer = CodexAppServerQuotaProvider()
    private let cacheLock = NSLock()
    private var lastReliable: QuotaService?

    func fetch(force: Bool = false, _ completion: @escaping (QuotaService?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            if force { self.appServer.reset() }
            // Live app-server data wins. A short transient failure must not replace a
            // proven live value with "no data" (or an older session-log snapshot).
            if let service = self.appServer.latestQuota(timeout: 3), self.isReliable(service) {
                self.store(service)
                DispatchQueue.main.async { completion(service) }
                return
            }
            if !force, let cached = self.cachedReliable() {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            // A forced request has already tried a fresh live connection. If it failed,
            // keep a known live snapshot rather than replacing it with an older log.
            if force, let cached = self.cachedReliable(), cached.source == "app-server" {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            guard let scriptPath = self.scriptPath else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let task = Process()
            task.launchPath = "/usr/bin/python3"
            task.arguments = [scriptPath, "codex-json"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let service = try? JSONDecoder().decode(QuotaService.self, from: data)
            guard let service, self.isReliable(service) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.store(service)
            DispatchQueue.main.async { completion(service) }
        }
    }

    private func isReliable(_ service: QuotaService) -> Bool {
        let now = Date().timeIntervalSince1970
        guard service.ok,
              let five = service.five, let week = service.week,
              let fivePct = five.pct, let weekPct = week.pct,
              let fiveReset = five.reset, let weekReset = week.reset,
              fivePct.isFinite, weekPct.isFinite,
              (0...100).contains(fivePct), (0...100).contains(weekPct),
              fiveReset > now, weekReset > now else { return false }
        return true
    }

    private func store(_ service: QuotaService) {
        cacheLock.lock()
        lastReliable = service
        cacheLock.unlock()
    }

    private func cachedReliable() -> QuotaService? {
        cacheLock.lock()
        var cached = lastReliable
        cacheLock.unlock()
        guard let value = cached, isReliable(value) else { return nil }
        cached?.stale = true
        return cached
    }
}

// MARK: - Quota panel view (logo + two rows: 5h / 7d bar + percent + reset time)

final class QuotaView: NSView {
    let icon: NSImage?
    let bundleID: String      // desktop app to launch on tap
    let appName: String       // fallback app path component
    let flagName: String       // attention flag file name
    let fallbackURL: String
    var service: QuotaService? { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?

    static let viewWidth: CGFloat = 300

    // Horizontal layout columns
    private let xLabel: CGFloat = 36
    private let xBar: CGFloat = 58
    private let wBar: CGFloat = 120
    private let hBar: CGFloat = 9
    private let xPctRight: CGFloat = 226
    private let xReset: CGFloat = 232

    init(iconFile: String, bundleID: String, appName: String, flagName: String, fallbackURL: String) {
        self.icon = Bundle.main.path(forResource: iconFile, ofType: "png").flatMap { NSImage(contentsOfFile: $0) }
        self.bundleID = bundleID
        self.appName = appName
        self.flagName = flagName
        self.fallbackURL = fallbackURL
        super.init(frame: NSRect(x: 0, y: 0, width: QuotaView.viewWidth, height: 30))
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        click.allowedTouchTypes = [.direct]
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: QuotaView.viewWidth, height: 30) }

    // Tap: clear the attention flag, then bring the matching desktop app to the front.
    // Note: NSRunningApplication.activate() is refused for background apps on macOS 14+,
    // so we use NSWorkspace.openApplication (= `open -a`), which also fronts a running app.
    @objc private func tapped() {
        try? FileManager.default.createDirectory(atPath: Paths.cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: Paths.cacheDir + flagName)
        // Drop an "acknowledged" marker so the log heuristic won't re-alert for this same wait.
        let ackName = flagName.replacingOccurrences(of: "_attention", with: "_ack")
        FileManager.default.createFile(atPath: Paths.cacheDir + ackName, contents: nil)
        service?.attention = false
        onTap?()  // update the menu-bar badge immediately, don't wait for the next refresh

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        } else {
            let appURL = URL(fileURLWithPath: "/Applications/" + appName)
            if FileManager.default.fileExists(atPath: appURL.path) {
                NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { [fallbackURL] _, error in
                    if error != nil, let u = URL(string: fallbackURL) {
                        DispatchQueue.main.async { NSWorkspace.shared.open(u) }
                    }
                }
            } else if let u = URL(string: fallbackURL) {
                NSWorkspace.shared.open(u)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 透明背景：不画卡片、不铺垫色，直接融入 Touch Bar 的黑底。
        icon?.draw(in: NSRect(x: 4, y: 2, width: 26, height: 26), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        guard let s = service else {
            drawText("…", at: NSPoint(x: xLabel, y: 7), color: .gray, size: 13)
            return
        }
        guard s.ok, let five = s.five, let week = s.week else {
            drawText(L("no data", "暂无数据"), at: NSPoint(x: xLabel, y: 7), color: .gray, size: 13)
            return
        }

        drawRow(top: true, label: "5h", window: five, resetStyle: .clock)
        drawRow(top: false, label: "7d", window: week, resetStyle: .remaining)

        if s.attention == true {
            // Waiting-for-you reminder: red badge with white "!" on the logo's top-right.
            let badge = NSRect(x: 21, y: 0, width: 13, height: 13)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.white,
            ]
            let mark = "!" as NSString
            let size = mark.size(withAttributes: attrs)
            mark.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
                      withAttributes: attrs)
        }

        if s.stale == true {
            // Stale data (usage API rate-limited / failed for >15 min): yellow dot, top-right.
            let dot = NSBezierPath(ovalIn: NSRect(x: bounds.width - 9, y: 3, width: 5, height: 5))
            NSColor.systemYellow.setFill()
            dot.fill()
        }
    }

    private enum ResetStyle { case clock, remaining }

    private func drawRow(top: Bool, label: String, window: QuotaWindow, resetStyle: ResetStyle) {
        let yText: CGFloat = top ? 0.5 : 15.5
        let yBar: CGFloat = top ? 3 : 18

        drawText(label, at: NSPoint(x: xLabel, y: yText + 1.5), color: NSColor(white: 0.78, alpha: 1), size: 11.5)

        // Empty bar track
        let barRect = NSRect(x: xBar, y: yBar, width: wBar, height: hBar)
        NSColor(white: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: hBar / 2, yRadius: hBar / 2).fill()

        // Unknown value (window reset but live data unavailable): show "—", no fill, no reset time.
        guard let raw = window.pct else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor(white: 0.6, alpha: 1),
            ]
            let s = "—" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: xPctRight - sz.width, y: yText), withAttributes: attrs)
            return
        }

        let pct = min(max(raw, 0), 100)
        if pct > 0 {
            let w = max(barRect.width * CGFloat(pct) / 100, hBar)
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: w, height: hBar)
            barColor(pct).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: hBar / 2, yRadius: hBar / 2).fill()
        }

        // Percentage is remaining quota; warn when the remaining value runs low.
        let pctStr = String(format: "%.0f%%", pct)
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: pctColor(pct),
        ]
        let pctSize = (pctStr as NSString).size(withAttributes: pctAttrs)
        (pctStr as NSString).draw(at: NSPoint(x: xPctRight - pctSize.width, y: yText), withAttributes: pctAttrs)

        // Reset time: 5h row shows a clock time (24h), 7d row shows the remaining duration.
        // The 5h clock turns yellow within the last 30 min — a nudge to use up the window.
        let resetStr = resetStyle == .clock ? clockText(window.reset) : remainingText(window.reset)
        var resetColor = NSColor(white: 0.88, alpha: 1)
        if resetStyle == .clock, let r = window.reset {
            let remain = r - Date().timeIntervalSince1970
            if remain > 0 && remain < 1800 { resetColor = .systemYellow }
        }
        drawText(resetStr, at: NSPoint(x: xReset, y: yText + 1.5), color: resetColor, size: 11.5)
    }

    private func barColor(_ pct: Double) -> NSColor {
        if pct <= 20 { return .systemRed }
        if pct <= 50 { return .systemYellow }
        return .systemGreen
    }

    private func pctColor(_ pct: Double) -> NSColor {
        if pct <= 20 { return .systemRed }
        if pct <= 50 { return .systemYellow }
        return .white
    }

    private func clockText(_ reset: Double?) -> String {
        guard let r = reset else { return "" }
        let date = Date(timeIntervalSince1970: r)
        guard date > Date() else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")  // force 24h, no am/pm
        fmt.dateFormat = "HH:mm"
        return "↻" + fmt.string(from: date)
    }

    private func remainingText(_ reset: Double?) -> String {
        guard let r = reset else { return "" }
        let secs = Int(r - Date().timeIntervalSince1970)
        guard secs > 0 else { return "" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "↻\(d)d\(h)h" }
        if h > 0 { return "↻\(h)h\(m)m" }
        return "↻\(m)m"
    }

    private func drawText(_ s: String, at p: NSPoint, color: NSColor, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
}

// MARK: - DeepSeek settings fields

/// LSUIElement apps need explicit editor shortcuts when a modal is opened from a menu.
private final class DeepSeekSettingsField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let editor = currentEditor() {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": editor.paste(nil); return true
            case "a": editor.selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    @objc func pasteValue(_ sender: Any?) {
        window?.makeFirstResponder(self)
        currentEditor()?.paste(sender)
    }
}

// MARK: - App

extension NSTouchBarItem.Identifier {
    static let codexQuota = NSTouchBarItem.Identifier("qs.codex")
    static let deepSeekQuota = NSTouchBarItem.Identifier("qs.deepseek")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let fetcher = QuotaFetcher()
    /// Codex + Magpie 实时模块（必选）+ DeepSeek（可选）合成一个 item，把系统 8pt 间距收到 3pt。
    private lazy var pairView = TouchBarPairView(codex: codexView, deepSeek: deepSeekPercentView, magpie: magpieView)
    private var pairWidthConstraint: NSLayoutConstraint?

    private let codexView = QuotaView(iconFile: "codex-logo", bundleID: "com.openai.codex",
                                      appName: "Codex.app", flagName: "codex_attention",
                                      fallbackURL: "https://chatgpt.com/codex/settings/usage")
    private let deepSeekView = DeepSeekTouchBarView()
    /// Touch Bar 的 DeepSeek 模块：与千问同一套剩余%逻辑，默认隐藏、菜单可开。
    private let deepSeekPercentView = DeepSeekPercentView()
    private static let showDeepSeekTBKey = "touchbar.showDeepSeek"
    private var showsDeepSeekTB: Bool {
        UserDefaults.standard.object(forKey: Self.showDeepSeekTBKey) as? Bool ?? false
    }
    /// Touch Bar 第二模块：Magpie logo + TokenPlan 剩余% + 当前对话模型/缓存/tok/s。
    private let magpieView = MagpieLiveTouchBarView()
    /// Magpie 当前对话实时数据（requests 接口）；只喂 Touch Bar，不进面板。
    private var magpieActivity = MagpieProvider.Activity()
    private let dshBalanceProvider = DSHBalanceProvider()
    private let apiBalanceProvider = DeepSeekBalanceProvider()
    /// 千问 Token Plan：直连 status.jimmycloud.cc 只读用量接口，令牌存钥匙串。
    private let jimmyCloudPlanProvider = JimmyCloudPlanProvider()
    /// Magpie 本机管理层：额度管理视图优先源；每个 provider 独立兜底。
    private let magpieProvider = MagpieProvider()
    private var magpieSnapshot = MagpieProvider.Snapshot()
    private var qwenPlanSnapshot: QwenPlan?
    private var qwenAccountsSnapshot: [QwenPlan] = []
    private var qwenPlanStale = false
    /// 朋友源与 Magpie qwen 的口径差异提示（>1pp 时显示，不自动切源）。
    private var qwenCrossCheckNote: String?
    private var deepSeekSnapshot = DeepSeekSnapshot()
    /// Reason the last tap could not front/launch DeepSeek Harness; surfaced in the menu.
    private var deepSeekActivationMessage: String?
    /// Reason the last panel row click could not be shown in DSH, when it failed.
    private var revealSessionMessage: String?
    private var deepSeekSourceGeneration: UInt64 = 0
    private var settingsDialogOpen = false
    private var deepSeekMenu: NSMenu!
    private var magpieMenu: NSMenu!
    // MARK: Menu-bar panel (shares the same data layer as the Touch Bar)
    private let panelModel = UsagePanelModel()
    private var panelController: UsagePanelController!
    private var statusMenu: NSMenu?
    private let codexUsageProvider = CodexUsageProvider()
    private var codexUsageSnapshot = CodexUsageSnapshot()

    /// 当前 DSH 对话：只读本机 usage-stats 的本会话接口，默认跟随、可关闭。
    private let sessionProvider = DSHSessionProvider()
    private var sessionStatus: DSHSessionStatus = .off
    private var sessionChoices: [DSHSessionChoice] = []
    private static let followSessionKey = "followCurrentSession"
    private static let sessionSelectionKey = "sessionSelection"

    private var followSession: Bool {
        UserDefaults.standard.object(forKey: Self.followSessionKey) as? Bool ?? true
    }

    private var sessionSelection: String? {
        UserDefaults.standard.string(forKey: Self.sessionSelectionKey)
    }
    private var panelTickTimer: Timer?
    private var usesDSH: Bool { UserDefaults.standard.string(forKey: "deepseek.source") != "api" }
    /// Persisted top-up round. `startBalance` is the balance right after the last
    /// deposit (nil until one is observed or entered), `amount` the detected deposit,
    /// `lastSeen` the most recent fresh balance (used to spot the next deposit).
    private struct TopUpRound: Codable {
        var startBalance: String?
        var amount: String?
        var lastSeen: String
        /// `auto` 首次观测自动记录、`topup` 检测到充值、`manual` 手工填写。
        var startSource: String? = nil
    }
    private func roundKey(_ currency: String) -> String { "deepseek.round." + currency.uppercased() }
    private var currentRound: TopUpRound? {
        guard let data = UserDefaults.standard.data(forKey: roundKey(deepSeekSnapshot.currency)) else { return nil }
        return try? JSONDecoder().decode(TopUpRound.self, from: data)
    }
    private func storeRound(_ round: TopUpRound, currency: String? = nil) {
        guard let data = try? JSONEncoder().encode(round) else { return }
        UserDefaults.standard.set(data, forKey: roundKey(currency ?? deepSeekSnapshot.currency))
    }
    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
    /// 菜单里当前模型今日 token 的紧凑写法，与 Touch Bar 同一口径。
    static func compactTokens(_ value: Int64) -> String {
        let n = Double(value)
        if n >= 999_995_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 999_995 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
        return String(value)
    }
    /// The account balance only falls when the account is spent and only rises when it is
    /// topped up or granted, so any rise against the last fresh reading is a new round:
    /// the post-deposit balance becomes the baseline (100%) and the delta its amount.
    /// On a first sighting the current balance becomes the baseline so the bar shows the
    /// share left since then; the menu labels it 自动记录 rather than pretending the user
    /// told us the top-up amount.
    private func updateTopUpRound(balance: Decimal?, stale: Bool) {
        guard let balance = balance, !balance.isNaN, balance >= 0, !stale else { return }
        let round = currentRound
        let lastSeen = round.flatMap { Decimal(string: $0.lastSeen, locale: Locale(identifier: "en_US_POSIX")) }
        guard var round = round, let lastSeen = lastSeen else {
            storeRound(TopUpRound(startBalance: decimalString(balance), amount: nil,
                                  lastSeen: decimalString(balance), startSource: "auto"))
            return
        }
        if round.startBalance == nil {
            round.startBalance = decimalString(balance)
            round.startSource = "auto"
        }
        if balance > lastSeen {
            round.startBalance = decimalString(balance)
            round.amount = decimalString(balance - lastSeen)
            round.startSource = "topup"
        }
        round.lastSeen = decimalString(balance)
        storeRound(round)
    }
    private var currentStartingBalance: Decimal? {
        guard let round = currentRound,
              let starting = Decimal(string: round.startBalance ?? "", locale: Locale(identifier: "en_US_POSIX")),
              starting > 0 else { return nil }
        return starting
    }
    /// A baseline above the current balance is trustworthy; below it means a deposit the
    /// app has not seen yet, so no percentage is shown for that refresh.
    private func effectiveStartingBalance() -> Decimal? {
        guard let starting = currentStartingBalance, let balance = deepSeekSnapshot.balance else { return nil }
        return starting >= balance ? starting : nil
    }
    private var bar: NSTouchBar!
    private var quotaTimer: Timer?
    /// App Nap 会把后台 LSUIElement 的定时器拉长到分钟级（实测 20s 变 ~10min），
    /// 用量/余额就会看起来「冻住」。持有一个 user-initiated activity 保住刷新节奏。
    private var napActivity: NSObjectProtocol?
    private var isPresented = false
    private let codexBundleIdentifier = "com.openai.codex"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 验收用：QS_APPEARANCE=light|dark 只看这个进程的外观，不动系统设置。
        if let appearance = ProcessInfo.processInfo.environment["QS_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        // Single instance: a second copy (e.g. login item + manual launch) would fight
        // over the Touch Bar, so just quit quietly.
        let mine = Bundle.main.bundleIdentifier ?? ""
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: mine)
        if twins.count > 1 {
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        panelModel.icon = { name in
            Bundle.main.path(forResource: name, ofType: "png").flatMap { NSImage(contentsOfFile: $0) }
        }
        panelModel.onRefresh = { [weak self] in
            guard let self else { return }
            self.refreshForced()
            self.refreshCodexUsage(force: true)
            self.refreshQwenPlan(force: true)
        }
        panelModel.onSettings = { [weak self] in self?.showStatusMenu() }
        panelModel.onOpenCodex = { [weak self] in self?.openCodex() }
        panelModel.onOpenDeepSeek = { [weak self] in self?.activateDeepSeekHarness() }
        panelModel.onOpenCredits = { [weak self] in
            guard let self, let url = URL(string: self.codexView.fallbackURL) else { return }
            NSWorkspace.shared.open(url)
        }
        panelModel.onToggleFollow = { [weak self] in self?.setFollowSession(false) }
        panelModel.onSelectSession = { [weak self] id in
            // Keep the Touch Bar following the row, then show that conversation in DSH itself.
            self?.setSessionSelection(id)
            self?.revealSession(id)
        }
        panelModel.onClearSession = { [weak self] in self?.setSessionSelection(nil) }
        panelController = UsagePanelController(model: panelModel)
        codexView.onTap = { [weak self] in self?.syncStatusAttention() }
        deepSeekView.onTap = { [weak self] in
            guard let self else { return }
            self.refreshDeepSeek(force: true)
            self.activateDeepSeekHarness()
        }
        magpieView.onTap = { [weak self] in
            guard let self else { return }
            self.refreshQwenPlan(force: true)
            self.refreshMagpie(force: true)
            self.refreshMagpieActivity(force: true)
        }
        deepSeekPercentView.onTap = { [weak self] in
            guard let self else { return }
            self.refreshDeepSeek(force: true)
            self.activateDeepSeekHarness()
        }
        pairView.showsDeepSeek = showsDeepSeekTB

        bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.codexQuota]

        dshBalanceProvider.endpoint = UserDefaults.standard.string(forKey: "deepseek.dshOrigin").flatMap(URL.init(string:))
        DeepSeekHolidayStore.shared.loadLocal()
        DeepSeekHolidayStore.shared.onChange = { [weak self] in self?.deepSeekView.refreshPricingStatus() }
        DeepSeekHolidayStore.shared.refreshIfNeeded()
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "QuotaStrip keeps quota/balance refresh on its 20s cadence")
        refresh()
        quotaTimer = Timer(timeInterval: 20, target: self,
                           selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(quotaTimer!, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleApplicationLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleApplicationTermination(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        updatePresentationForCodexState()
        // 仅用于截图验收：QS_SHOW_PANEL=1 时自动展开面板，平时不受影响。
        if ProcessInfo.processInfo.environment["QS_SHOW_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showPanel() }
        }
    }

    // MARK: Menu bar

    private var loginItem: NSMenuItem!
    private var followSessionItem: NSMenuItem!
    private var showDeepSeekTBItem: NSMenuItem!
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AppDelegate.gaugeIcon()
        let menu = NSMenu()
        menu.delegate = self   // refresh dynamic item states each time the menu opens
        menu.addItem(NSMenuItem(title: L("Refresh now", "立即刷新"), action: #selector(refreshForced), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: L("Re-show Touch Bar", "重新显示 Touch Bar"), action: #selector(reShowTouchBar), keyEquivalent: "t"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Open Codex usage page", "打开 Codex 用量页"), action: #selector(openCodex), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("View connection log", "查看连接日志"), action: #selector(openLog), keyEquivalent: "l"))
        followSessionItem = NSMenuItem(title: L("Follow current DSH conversation", "跟随当前 DSH 对话"),
                                       action: #selector(toggleFollowSession), keyEquivalent: "")
        menu.addItem(followSessionItem)
        let deepSeekItem = NSMenuItem(title: "DeepSeek", action: nil, keyEquivalent: "")
        deepSeekMenu = NSMenu(title: "DeepSeek")
        deepSeekMenu.delegate = self
        deepSeekItem.submenu = deepSeekMenu
        menu.addItem(deepSeekItem)
        showDeepSeekTBItem = NSMenuItem(title: L("Show DeepSeek on Touch Bar", "Touch Bar 显示 DeepSeek"),
                                        action: #selector(toggleShowDeepSeekTB), keyEquivalent: "")
        menu.addItem(showDeepSeekTBItem)
        let magpieItem = NSMenuItem(title: L("Magpie", "Magpie 管理"), action: nil, keyEquivalent: "")
        magpieMenu = NSMenu(title: "Magpie")
        magpieMenu.delegate = self
        magpieItem.submenu = magpieMenu
        menu.addItem(magpieItem)
        loginItem = NSMenuItem(title: L("Start at login", "开机自启"), action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit QuotaStrip", "退出 QuotaStrip"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Do not depend on an inactive agent app's responder chain for validation.
        for item in menu.items where item.action != nil {
            item.target = item.action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        }
        // Left click opens the overview panel, right/control click keeps the old menu.
        statusMenu = menu
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if secondary {
            showStatusMenu()
        } else if panelController.isShown {
            panelController.close()
            panelTickTimer?.invalidate()
            panelTickTimer = nil
        } else {
            showPanel()
        }
    }

    private func showStatusMenu() {
        guard let menu = statusMenu, let button = statusItem.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        if ProcessInfo.processInfo.environment["QS_SHOW_PANEL"] == "1" {
            panelController.pinForCapture()
        }
        syncPanel()
        panelController.show(relativeTo: button)
        refreshCodexUsage(force: false)
        refreshSession(force: true)
        panelTickTimer?.invalidate()
        panelTickTimer = Timer(timeInterval: 30, target: self,
                               selector: #selector(panelTick), userInfo: nil, repeats: true)
        RunLoop.main.add(panelTickTimer!, forMode: .common)
    }

    @objc private func panelTick() {
        guard panelController.isShown else {
            panelTickTimer?.invalidate()
            panelTickTimer = nil
            return
        }
        refreshCodexUsage(force: false)
        refreshSession(force: false)
    }

    /// 连接/刷新当前对话。关闭跟随时只把状态归零，不发任何请求。
    private func refreshSession(force: Bool) {
        guard followSession else {
            sessionStatus = .off
            sessionChoices = []
            syncPanel()
            return
        }
        if case .off = sessionStatus { sessionStatus = .connecting }
        syncPanel()
        sessionProvider.fetch(force: force, selection: sessionSelection) { [weak self] status, choices in
            guard let self else { return }
            // 关闭跟随之后到达的结果直接丢弃，避免把旧会话写回面板。
            guard self.followSession else { return }
            self.sessionStatus = status
            self.sessionChoices = choices
            self.syncPanel()
        }
    }

    @objc private func toggleFollowSession() {
        setFollowSession(!followSession)
    }

    private func setFollowSession(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.followSessionKey)
        if enabled {
            refreshSession(force: true)
        } else {
            sessionProvider.cancel()
            sessionStatus = .off
            sessionChoices = []
            syncPanel()
        }
        followSessionItem?.state = followSession ? .on : .off
    }

    private func setSessionSelection(_ id: String?) {
        if let id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: Self.sessionSelectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sessionSelectionKey)
        }
        refreshSession(force: true)
    }

    private func refreshCodexUsage(force: Bool) {
        codexUsageProvider.refresh(force: force) { [weak self] snapshot in
            guard let self else { return }
            self.codexUsageSnapshot = snapshot
            self.syncPanel()
        }
    }

    /// 千问 Token Plan 随现有刷新周期走；provider 内部 60s 缓存 + 失败保留旧值标 stale。
    private func refreshQwenPlan(force: Bool) {
        jimmyCloudPlanProvider.fetch(force: force) { [weak self] plan, _, stale in
            guard let self else { return }
            self.qwenPlanSnapshot = plan
            self.qwenAccountsSnapshot = self.jimmyCloudPlanProvider.accounts
            self.qwenPlanStale = stale
            self.updateQwenTouchBar()
            self.syncPanel()
        }
    }

    /// Magpie 管理视图：60s 缓存命中 20s tick；失败只降级 Magpie 行，各卡走各自兜底。
    private func refreshMagpie(force: Bool) {
        magpieProvider.fetch(force: force) { [weak self] snapshot in
            guard let self else { return }
            self.magpieSnapshot = snapshot
            self.updateQwenTouchBar()
            self.syncPanel()
        }
    }

    /// Magpie 当前对话实时视图：15s 缓存命中 20s tick；失败保留上次好值标 stale。
    private func refreshMagpieActivity(force: Bool) {
        magpieProvider.fetchActivity(force: force) { [weak self] activity in
            guard let self else { return }
            self.magpieActivity = activity
            self.updateMagpieLiveView()
            // 今日大数字已改用 Magpie 合并口径，面板也要跟着刷新。
            self.syncPanel()
        }
    }

    /// Touch Bar Magpie 模块：朋友 remaining 主源；朋友失败且 Magpie qwen 可用时用 Magpie；
    /// 都失败显示 lastGood + stale 点。同时做 >1pp 口径交叉核对（只提示，不切源）。
    private func updateQwenTouchBar() {
        qwenCrossCheckNote = nil
        let friendPercent = qwenPlanSnapshot?.monthlyWindow?.remainingPercent
        var magpiePercent: Double?
        if let qwen = magpieSnapshot.quota("qwen"), qwen.isUsable,
           let window = qwen.windows.first, let remaining = window.remaining {
            magpiePercent = remaining
        }
        if let friend = friendPercent, let magpie = magpiePercent, abs(friend - magpie) > 1 {
            qwenCrossCheckNote = L("Qwen sources differ (>1pp): friend \(Int(friend.rounded()))% vs Magpie \(Int(magpie.rounded()))%.",
                                   "千问口径差异（>1pp）：朋友源 \(Int(friend.rounded()))% vs Magpie \(Int(magpie.rounded()))%。")
        }
        updateMagpieLiveView()
    }

    /// 汇总 TokenPlan 剩余% 与 Magpie 实时对话数据，喂给 Touch Bar 第二模块。
    private func updateMagpieLiveView() {
        var value = MagpieLiveTouchBarView.Data()
        let friendPercent = qwenPlanSnapshot?.monthlyWindow?.remainingPercent
        var magpiePercent: Double?
        if let qwen = magpieSnapshot.quota("qwen"), qwen.isUsable,
           let window = qwen.windows.first, let remaining = window.remaining {
            magpiePercent = remaining
        }
        if let friend = friendPercent {
            value.remainingPercent = friend
            value.stale = qwenPlanStale
        } else if let magpie = magpiePercent {
            value.remainingPercent = magpie
            value.stale = magpieSnapshot.stale
        }
        // 今日 token 主源 = Magpie 合并口径（网关实时 + DSH 日志导入，与 Magpie App 一致，
        // Magpie 侧已按 response_id 去重）；Magpie 不可用才回退 DSH 本地读数，两边绝不叠加。
        value.todayTokens = magpieActivity.todayTotal ?? deepSeekSnapshot.todayAllTokens
        value.model = magpieActivity.model
        value.sessionTokens = magpieActivity.sessionTokens
        value.sessionCacheHit = magpieActivity.sessionCacheHit
        value.tokensPerSecond = magpieActivity.tokensPerSecond
        value.requestAt = magpieActivity.requestAt
        value.stale = value.stale || magpieActivity.stale || deepSeekSnapshot.stale
        magpieView.data = value
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = loginEnabled ? .on : .off
        if menu === statusMenu {
            followSessionItem.state = followSession ? .on : .off
            showDeepSeekTBItem.state = showsDeepSeekTB ? .on : .off
        }
        if menu === magpieMenu {
            menu.removeAllItems()
            if !magpieSnapshot.isRunning {
                menu.addItem(NSMenuItem(title: magpieSnapshot.error ?? L("Magpie is not running.", "Magpie 未运行。"), action: nil, keyEquivalent: ""))
            } else {
                let count = magpieSnapshot.accounts.count
                menu.addItem(NSMenuItem(title: L("Magpie · \(count) accounts", "Magpie · \(count) 个账号"), action: nil, keyEquivalent: ""))
                for quota in magpieSnapshot.quotas {
                    let title: String
                    if let error = quota.error {
                        title = quota.name + ": " + error
                    } else if quota.windows.isEmpty, let balance = quota.balance {
                        title = quota.name + ": " + balance
                    } else {
                        let parts = quota.windows.map { window -> String in
                            if let display = window.display { return "\(window.name) \(display)" }
                            guard let remaining = window.remaining else { return window.name }
                            return "\(window.name) \(Int(remaining.rounded()))%"
                        }
                        title = quota.name + ": " + (parts.isEmpty ? "ok" : parts.joined(separator: " · "))
                    }
                    menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
                }
                if let codex = magpieSnapshot.quota("codex") {
                    if codex.resetsCount > 0 {
                        menu.addItem(NSMenuItem(title: L("Rate-limit resets ×\(codex.resetsCount)", "重置券 ×\(codex.resetsCount)"), action: nil, keyEquivalent: ""))
                    }
                    if let balance = codex.balance {
                        menu.addItem(NSMenuItem(title: L("Credits: ", "Credits 余额：") + balance, action: nil, keyEquivalent: ""))
                    }
                }
                if let note = qwenCrossCheckNote {
                    menu.addItem(NSMenuItem(title: note, action: nil, keyEquivalent: ""))
                }
            }
            menu.addItem(.separator())
            let open = NSMenuItem(title: L("Open Magpie", "打开 Magpie"), action: #selector(openMagpie), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let refresh = NSMenuItem(title: L("Refresh Magpie", "刷新 Magpie"), action: #selector(refreshMagpieForced), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
            return
        }
        guard menu === deepSeekMenu else { return }
        menu.removeAllItems()
        let source = NSMenuItem(title: usesDSH ? L("Source: DSH account", "来源：DSH 账户") : L("Source: official API key", "来源：官方 API Key"), action: nil, keyEquivalent: "")
        menu.addItem(source)
        if let message = deepSeekSnapshot.message { menu.addItem(NSMenuItem(title: message, action: nil, keyEquivalent: "")) }
        if let message = deepSeekActivationMessage { menu.addItem(NSMenuItem(title: message, action: nil, keyEquivalent: "")) }
        if let message = revealSessionMessage { menu.addItem(NSMenuItem(title: message, action: nil, keyEquivalent: "")) }
        if deepSeekSnapshot.stale { menu.addItem(NSMenuItem(title: L("Last known balance · not updated", "上次余额 · 尚未更新"), action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        var rows: [(String, Selector)] = [
            (L("Read from DSH account", "从 DSH 账户读取"), #selector(useDSHBalance)),
            (L("Read using API key", "使用 API Key 读取"), #selector(useAPIBalance)),
            (L("Set API key…", "设置 API Key…"), #selector(configureDeepSeekKey))
        ]
        // With the bill denominator in place a manual round would be ignored, so it is not offered.
        if deepSeekSnapshot.startingBalanceSource != "account" {
            rows.append((L("Record top-up balance…", "记录充值后余额…"), #selector(recordTopUp)))
        }
        rows.append((L("Set DSH address…", "设置 DSH 地址…"), #selector(configureDSHAddress)))
        for (title, action) in rows {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if action == #selector(useDSHBalance) { item.state = usesDSH ? .on : .off }
            if action == #selector(useAPIBalance) { item.state = usesDSH ? .off : .on }
            menu.addItem(item)
        }
        let view = deepSeekView.round()
        let detailed: String
        switch (view, currentRound) {
        case (.known(let starting, let percent), let round):
            let accountWide = deepSeekSnapshot.startingBalanceSource == "account"
            let label = accountWide ? L("Account total", "账户累计") : L("Starting balance", "本轮起始余额")
            var line = label + ": " + deepSeekSnapshot.currency + " " + decimalString(starting)
                + " · " + L("remaining", "剩余") + " " + String(percent) + "%"
            if accountWide {
                line += L(" · balance + official spend", " · 余额＋官方累计消费")
            } else {
                switch round?.startSource {
                case "auto": line += L(" · recorded on first sighting", " · 首次观测自动记录")
                case "topup": line += L(" · after top-up", " · 充值后余额")
                case "manual": line += L(" · entered by hand", " · 手工填写")
                default: break
                }
            }
            if let amount = round?.amount, let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")),
               value > 0 {
                line += " · " + L("top-up", "本次充值") + " " + deepSeekSnapshot.currency + " " + decimalString(value)
            }
            detailed = line
        case (.waiting, _):
            detailed = L("Balance is above the recorded start: refresh to open a new round.", "余额高于已记录的起始余额：刷新后开始新一轮。")
        case (.unknown, _):
            let known = currentStartingBalance.map { " " + decimalString($0) } ?? " —"
            detailed = L("Starting balance", "本轮起始余额") + ": " + deepSeekSnapshot.currency + known
                + " · " + L("will be recorded on the next balance refresh", "刷新到余额后会自动开始本轮")
        }
        menu.addItem(NSMenuItem(title: detailed, action: nil, keyEquivalent: ""))
        if let model = deepSeekSnapshot.currentModel {
            var line = L("Current model", "当前模型") + ": " + model
            if let tokens = deepSeekSnapshot.currentModelTokens {
                line += " · " + L("today", "今日") + " " + Self.compactTokens(tokens)
            }
            menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let years = DeepSeekHolidayStore.shared.availableYears()
        let coverage = years.isEmpty ? L("no year loaded", "暂无数据")
            : years.map(String.init).joined(separator: " / ") + L(" ready", " 已就绪")
        menu.addItem(NSMenuItem(title: L("Price calendar", "计费日历") + ": " + coverage, action: nil, keyEquivalent: ""))
        let update = NSMenuItem(title: L("Update price calendar…", "更新计费日历…"), action: #selector(updateHolidayCalendar), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
    }

    @objc private func updateHolidayCalendar() {
        DeepSeekHolidayStore.shared.forceRefresh()
    }

    @objc private func openMagpie() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.yetone.magpie") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func refreshMagpieForced() {
        refreshMagpie(force: true)
    }

    /// DeepSeek 的 Touch Bar 模块是可选的：默认不显示，菜单勾选后才占位。
    @objc private func toggleShowDeepSeekTB() {
        let enabled = !showsDeepSeekTB
        UserDefaults.standard.set(enabled, forKey: Self.showDeepSeekTBKey)
        pairView.showsDeepSeek = enabled
        pairWidthConstraint?.constant = pairView.currentWidth
        pairView.needsLayout = true
        pairView.layoutSubtreeIfNeeded()
        updateDeepSeekPercentView()
        if isPresented { reShowTouchBar() }
    }

    /// DeepSeek 模块与千问同一套剩余%逻辑：本轮起始余额为分母；无可靠分母不猜百分比。
    private func updateDeepSeekPercentView() {
        if case .known(_, let percent) = deepSeekView.round() {
            deepSeekPercentView.remainingPercent = Double(percent)
            deepSeekPercentView.stale = deepSeekSnapshot.stale
            deepSeekPercentView.message = nil
        } else {
            deepSeekPercentView.remainingPercent = nil
            deepSeekPercentView.stale = deepSeekSnapshot.stale
            deepSeekPercentView.message = deepSeekSnapshot.balance != nil
                ? L("No baseline", "无本轮分母") : L("No data", "暂无数据")
        }
    }

    private func switchDeepSeekSource(_ source: String) {
        deepSeekSourceGeneration &+= 1
        UserDefaults.standard.set(source, forKey: "deepseek.source")
        deepSeekSnapshot = DeepSeekSnapshot()
        deepSeekView.update(deepSeekSnapshot)
        refreshDeepSeek(force: true)
    }
    @objc private func useDSHBalance() { switchDeepSeekSource("dsh") }
    @objc private func useAPIBalance() { switchDeepSeekSource("api") }

    private func refreshDeepSeek(force: Bool) {
        let generation = deepSeekSourceGeneration
        if usesDSH {
            dshBalanceProvider.fetch(force: force) { [weak self] snapshot in
                guard let self, generation == self.deepSeekSourceGeneration else { return }
                guard snapshot.stale else { self.acceptDeepSeek(snapshot); return }
                self.apiBalanceProvider.fetch(force: force) { [weak self] balance, message, stale in
                    guard let self, generation == self.deepSeekSourceGeneration else { return }
                    var fallback = snapshot
                    if let entry = balance?.balance_infos.first,
                       let amount = Decimal(string: entry.total_balance, locale: Locale(identifier: "en_US_POSIX")), !stale {
                        fallback.balance = amount
                        fallback.currency = entry.currency
                        fallback.todayTokens = nil
                        fallback.todayCacheHitPercent = nil
                        // 用量整体退回 API 余额视图时，趋势也不应继续显示旧的 DSH 快照。
                        fallback.recentDayLabels = []
                        fallback.recentDayTokens = []
                        fallback.startingBalance = nil
                        fallback.startingBalanceSource = nil
                        // 余额此时来自 API，与 DSH 平台账单的 totalHeld 不再同源：
                        // 不要让“累计已花”用两个来源相减。
                        fallback.accountTotalHeld = nil
                        fallback.stale = false
                        fallback.message = L("Balance from DeepSeek API; DSH usage unavailable.", "余额来自 DeepSeek API；DSH 用量暂不可用。")
                    } else if let message = message {
                        fallback.message = (snapshot.message ?? "DSH unavailable") + " · " + message
                    }
                    self.acceptDeepSeek(fallback)
                }
            }
        } else {
            apiBalanceProvider.fetch(force: force) { [weak self] balance, message, stale in
                guard let self, generation == self.deepSeekSourceGeneration else { return }
                var snapshot = DeepSeekSnapshot()
                snapshot.message = message
                snapshot.stale = stale
                if let entry = balance?.balance_infos.first {
                    snapshot.balance = Decimal(string: entry.total_balance, locale: Locale(identifier: "en_US_POSIX"))
                    snapshot.currency = entry.currency
                }
                self.acceptDeepSeek(snapshot)
            }
        }
    }
    /// Same behaviour as the Codex item: front the desktop app, or launch it once if needed.
    private func activateDeepSeekHarness() {
        DeepSeekHarnessApp.activate { [weak self] reason in
            guard let self else { return }
            if let reason {
                NSLog("QuotaStrip: %@", reason)
                self.deepSeekActivationMessage = reason
            } else {
                self.deepSeekActivationMessage = nil
            }
        }
    }

    /// Show one conversation in DSH, then bring the app forward.
    ///
    /// The bridge only carries the id: the plugin's browser half does the switch
    /// through `uiWorkspace.openSession`, so no UI is scripted from here.
    private func revealSession(_ id: String) {
        DSHOpenSession.request(sessionId: id) { [weak self] reason in
            guard let self else { return }
            if let reason {
                NSLog("QuotaStrip: reveal session failed: %@", reason)
                self.revealSessionMessage = reason
            } else {
                self.revealSessionMessage = nil
            }
            self.activateDeepSeekHarness()
        }
    }

    private func acceptDeepSeek(_ snapshot: DeepSeekSnapshot) {
        var value = snapshot
        // The top-up round is still recorded (the menu shows it), but the platform bill wins when
        // it is available: its denominator is the whole account, not just what this Mac has seen.
        updateTopUpRound(balance: snapshot.balance, stale: snapshot.stale)
        if snapshot.startingBalanceSource == "account", snapshot.startingBalance != nil {
            // keep the provider's account-wide denominator
        } else {
            value.startingBalance = effectiveStartingBalance()
        }
        deepSeekSnapshot = value
        deepSeekView.update(value)
        updateDeepSeekPercentView()
        updateMagpieLiveView()
        syncPanel()
    }

    /// Defer until the status menu finishes tracking; never access the clipboard ourselves.
    private func showDeepSeekSettings(_ body: @escaping () -> Void) {
        guard !settingsDialogOpen else { return }
        settingsDialogOpen = true
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            defer { self?.settingsDialogOpen = false }
            NSApp.activate(ignoringOtherApps: true)
            body()
        }
    }
    /// Locks the currency before presenting so a refresh cannot change which key is written.
    private func parseAmount(_ value: String) -> Decimal? {
        guard value.range(of: #"^[0-9]+(?:\.[0-9]{1,8})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN, amount > 0 else { return nil }
        return amount
    }
    /// Stores a manually entered baseline. The currency is captured before the modal runs so
    /// a refresh in the meantime cannot write the amount into a different currency's record.
    private func presentStartingBalanceDialog(title: String, message: String, prefill: Decimal?) {
        showDeepSeekSettings { [weak self] in
            guard let self else { return }
            let currency = self.deepSeekSnapshot.currency
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message + " " + L("Currency", "币种") + ": " + currency
                + L(". Leave blank to clear the bar.", "。留空清除进度条。")
            alert.addButton(withTitle: L("Save", "保存")); alert.addButton(withTitle: L("Cancel", "取消"))
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            field.placeholderString = "20.00"
            field.stringValue = prefill.map(self.decimalString) ?? ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            alert.window.makeFirstResponder(nil)
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = self.roundKey(currency)
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
                self.deepSeekSnapshot.startingBalance = nil
                self.deepSeekView.update(self.deepSeekSnapshot)
                return
            }
            guard let starting = self.parseAmount(value) else {
                self.deepSeekError(L("Enter a positive amount.", "请输入有效的正数金额。")); return
            }
            let balance = self.deepSeekSnapshot.balance ?? starting
            self.storeRound(TopUpRound(startBalance: self.decimalString(starting),
                                       amount: nil,
                                       lastSeen: self.decimalString(balance)),
                            currency: currency)
            self.deepSeekSnapshot.startingBalance = starting
            self.deepSeekView.update(self.deepSeekSnapshot)
        }
    }
    @objc private func recordTopUp() {
        // A deposit is best described by the balance it produced: 充值 ¥20 后余额 ¥20 → 100%，
        // 消耗到 ¥10 → 50%。Asking for the amount alone would need the pre-top-up balance
        // to reconstruct the same number, so the one unambiguous input is used for both.
        presentStartingBalanceDialog(
            title: L("Record a top-up", "记录一次充值"),
            message: L("Enter the balance right after the deposit. The bar then shows how much of it is left: ¥20 → 100%, ¥10 → 50%.",
                       "填写充值后的账户余额。进度条按这笔金额显示剩余比例：¥20 → 100%，消耗到 ¥10 → 50%。"),
            prefill: nil)
    }
    @objc private func configureDSHAddress() {
        showDeepSeekSettings { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = L("DSH local address", "DSH 本机地址")
            alert.informativeText = L("Leave blank for automatic discovery. Only http://127.0.0.1:port is accepted; no tokens or credentials.", "留空自动发现。仅接受 http://127.0.0.1:端口，不填写 Token 或登录凭据。")
            alert.addButton(withTitle: L("Save", "保存")); alert.addButton(withTitle: L("Cancel", "取消"))
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
            field.stringValue = UserDefaults.standard.string(forKey: "deepseek.dshOrigin") ?? ""
            alert.accessoryView = field; alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            alert.window.makeFirstResponder(nil)
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { UserDefaults.standard.removeObject(forKey: "deepseek.dshOrigin") }
            else if let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" {
                UserDefaults.standard.set("http://127.0.0.1:\(port)", forKey: "deepseek.dshOrigin")
            } else { self.deepSeekError(L("Use a loopback HTTP origin only.", "请仅填写本机 HTTP 地址。")); return }
            self.dshBalanceProvider.endpoint = UserDefaults.standard.string(forKey: "deepseek.dshOrigin").flatMap(URL.init(string:))
            self.switchDeepSeekSource("dsh")
        }
    }
    @objc private func configureDeepSeekKey() {
        showDeepSeekSettings { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = L("DeepSeek API key", "DeepSeek API Key")
            alert.informativeText = L("Stored only in macOS Keychain. DSH account mode does not need this key.", "仅保存到 macOS 钥匙串。DSH 账户模式无需此密钥。")
            alert.addButton(withTitle: L("Save", "保存")); alert.addButton(withTitle: L("Cancel", "取消"))
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 28))
            let field = DeepSeekSettingsField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            let paste = NSButton(title: L("Paste", "粘贴"), target: field, action: #selector(DeepSeekSettingsField.pasteValue(_:)))
            paste.frame = NSRect(x: 366, y: 0, width: 84, height: 28)
            box.addSubview(field); box.addSubview(paste)
            alert.accessoryView = box; alert.window.initialFirstResponder = field
            defer { field.stringValue = "" }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            alert.window.makeFirstResponder(nil)
            do { try self.apiBalanceProvider.saveAPIKey(field.stringValue); self.switchDeepSeekSource("api") }
            catch { self.deepSeekError(error.localizedDescription) }
        }
    }
    private func deepSeekError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message; alert.runModal()
    }

    /// Icon: two bars of different length (a usage gauge); template image adapts to light/dark.
    static func gaugeIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            let rows: [(y: CGFloat, fill: CGFloat)] = [(9.5, 14), (3.5, 8)]
            for row in rows {
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: NSRect(x: 1, y: row.y, width: 18, height: 4.5),
                             xRadius: 2.25, yRadius: 2.25).fill()
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 1, y: row.y, width: row.fill, height: 4.5),
                             xRadius: 2.25, yRadius: 2.25).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func updateStatusAttention(_ attention: Bool) {
        guard let button = statusItem.button else { return }
        if attention {
            button.attributedTitle = NSAttributedString(
                string: " !",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.boldSystemFont(ofSize: 14)])
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
        }
    }

    // MARK: Login item (SMAppService, macOS 13+)

    private var loginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else {
            let a = NSAlert()
            a.messageText = L("Start at login needs macOS 13 or later.", "开机自启需要 macOS 13 或更高版本。")
            a.runModal()
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            let a = NSAlert()
            a.messageText = L("Could not change the login item: ", "无法更改登录项：") + error.localizedDescription
            a.runModal()
        }
    }

    // MARK: Touch Bar presentation

    @objc func present() {
        guard shouldShowTouchBar, !isPresented else { return }
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        let tray = NSCustomTouchBarItem(identifier: trayIdentifier)
        tray.view = NSButton(image: AppDelegate.gaugeIcon(), target: self, action: #selector(reShowTouchBar))
        addSystemTrayItem(tray)
        DFRElementSetControlStripPresenceForIdentifier(trayIdentifier.rawValue as NSString, true)
        presentSystemModal(bar, trayId: trayIdentifier)
        isPresented = true
        // Re-disable the left close box after presenting (setting it beforehand gets reset).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        }
    }

    private func hide() {
        guard isPresented else { return }
        dismissSystemModal(bar)
        DFRElementSetControlStripPresenceForIdentifier(trayIdentifier.rawValue as NSString, false)
        isPresented = false
    }

    /// macOS does not notify this private API when the user closes the modal bar.
    /// Reset our local state first so a deliberate re-show can present it again.
    @objc private func reShowTouchBar() {
        guard shouldShowTouchBar else { return }
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.present()
        }
    }

    private func codexIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == codexBundleIdentifier }
    }

    private var shouldShowTouchBar: Bool {
        codexIsRunning() || DeepSeekHarnessApp.isRunning()
    }

    private func updatePresentationForCodexState() {
        if shouldShowTouchBar { present() } else { hide() }
    }

    @objc private func handleWake() {
        updatePresentationForCodexState()
        refresh()
    }

    @objc private func handleApplicationLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier == codexBundleIdentifier || app.bundleIdentifier == DeepSeekHarnessApp.bundleIdentifier else { return }
        present()
    }

    @objc private func handleApplicationTermination(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == codexBundleIdentifier || app.bundleIdentifier == DeepSeekHarnessApp.bundleIdentifier else { return }
        updatePresentationForCodexState()
    }

    // MARK: Panel data

    /// Builds the panel snapshot from the exact values the Touch Bar already shows,
    /// so both surfaces can never disagree.
    private func syncPanel() {
        var snapshot = UsageSnapshot()
        let service = codexView.service
        snapshot.codexStale = service?.stale == true
        if let service, !service.ok {
            snapshot.codexMessage = L("Codex quota unavailable right now", "Codex 配额暂时读不到")
        }
        if let five = service?.five {
            snapshot.codexRows.append(quotaRow(label: "5h", window: five, clockStyle: true,
                                               windowSeconds: 5 * 3600))
        }
        if let week = service?.week {
            snapshot.codexRows.append(quotaRow(label: "7d", window: week, clockStyle: false,
                                               windowSeconds: 7 * 86400))
        }
        snapshot.todayOutputTokens = codexUsageSnapshot.todayOutputTokens
        snapshot.cacheHitPercent = codexUsageSnapshot.cacheHitPercent
        snapshot.codexRecentDayLabels = codexUsageSnapshot.recentDayLabels
        snapshot.codexRecentDayTokens = codexUsageSnapshot.recentDayTokens
        if let credits = codexUsageSnapshot.credits {
            let age = Date().timeIntervalSince(credits.observedAt)
            if age <= 7 * 86400 {
                snapshot.creditsText = credits.unlimited
                    ? L("Unlimited", "无限")
                    : Self.shortDecimal(credits.balance)
                snapshot.creditsNote = L("last seen ", "最近记录 ") + Self.shortTime(credits.observedAt)
            }
        }
        if let message = codexUsageSnapshot.message {
            snapshot.codexMessage = snapshot.codexMessage.map { $0 + " · " + message } ?? message
        }

        if let balance = deepSeekSnapshot.balance {
            // 余额只显示两位小数：账户返回 7.30076432，面板上应是 ¥7.30。
            snapshot.balanceText = Self.currencySymbol(deepSeekSnapshot.currency) + Self.money(balance)
        }
        if case .known(_, let percent) = deepSeekView.round() {
            snapshot.balancePercent = percent
        }
        // 累计已花 = 平台账单 totalHeld − 当前余额；缺任一真实字段就不猜，显示 “—”。
        snapshot.deepSeekSpentText = Self.spentText(balance: deepSeekSnapshot.balance,
                                                    totalHeld: deepSeekSnapshot.accountTotalHeld,
                                                    currency: deepSeekSnapshot.currency)
        snapshot.deepSeekTotalHeldText = deepSeekSnapshot.accountTotalHeld.map {
            Self.currencySymbol(deepSeekSnapshot.currency) + Self.money($0)
        }
        // 折线图主源 = Magpie 合并 series（与今日大数字同口径）；Magpie 无近 7 天
        // 数据才回退 DSH 的 deepseek 口径，两边不叠加。
        if !magpieActivity.recentDayTokens.isEmpty {
            snapshot.recentDayLabels = magpieActivity.recentDayLabels
            snapshot.recentDayTokens = magpieActivity.recentDayTokens
        } else {
            snapshot.recentDayLabels = deepSeekSnapshot.recentDayLabels
            snapshot.recentDayTokens = deepSeekSnapshot.recentDayTokens
        }
        snapshot.deepSeekTodayTokens = deepSeekSnapshot.todayTokens
        snapshot.deepSeekMonthTokens = deepSeekSnapshot.monthTokens
        snapshot.deepSeekCacheHitPercent = deepSeekSnapshot.todayCacheHitPercent
        snapshot.deepSeekStale = deepSeekSnapshot.stale
        // 今日按模型拆分：Codex 侧取 openai/*，DeepSeek 侧取 deepseek-*，各自最多三行。
        snapshot.codexModelRows = Self.modelRows(deepSeekSnapshot.todayByModel, prefixes: ["openai/"])
        snapshot.deepSeekModelRows = Self.modelRows(deepSeekSnapshot.todayByModel,
                                                    prefixes: ["deepseek-account/", "deepseek-official/"])
        // 千帆走 baidu-pzt 前缀；qwen/ 的本地读数改由 Magpie 展示，面板不再画「今日本地」行。
        snapshot.qianfanModelRows = Self.modelRows(deepSeekSnapshot.todayByModel,
                                                    prefixes: ["baidu-pzt/"])
        snapshot.qianfanTodayTokens = deepSeekSnapshot.todayProviderTokens["baidu-pzt"]
        // 面板「AI 用量」大数字与 Touch Bar 同源：Magpie 合并口径优先，DSH 只作兜底，不叠加。
        snapshot.todayAllTokens = magpieActivity.todayTotal ?? deepSeekSnapshot.todayAllTokens
        snapshot.weekAllTokens = magpieActivity.weekTotal
        // Magpie 面板扩展：千问供应商今日消耗 / 近 30 天热力图 / 今日会话数 / 最近请求时刻。
        snapshot.magpieQwenToday = magpieActivity.qwenToday
        snapshot.magpieHeatDays = magpieActivity.heatDays
        snapshot.magpieFxRate = magpieActivity.fxRate
        snapshot.magpieTodaySessions = magpieActivity.todaySessions
        snapshot.magpieRequestAt = magpieActivity.requestAt
        // 会话标题不在用量接口里（title 恒为 null），从 DSH 的会话缓存只读取一次并缓存 60s。
        if !deepSeekSnapshot.usageSessions.isEmpty {
            snapshot.todaySessionCount = deepSeekSnapshot.usageSessions.filter { session in
                session.lastAt.map { Calendar.current.isDateInToday($0) } ?? false
            }.count
            let titles = DSHSessionTitles.shared.titles(for: deepSeekSnapshot.usageSessions.map { $0.id })
            snapshot.usageSessions = deepSeekSnapshot.usageSessions.map { session in
                UsageSessionRow(id: session.id, title: titles[session.id],
                                tokens: session.tokens, models: session.models, lastAt: session.lastAt)
            }
        }
        snapshot.deepSeekMessage = deepSeekSnapshot.message
        snapshot.followSession = followSession
        snapshot.sessionStatus = followSession ? sessionStatus : .off
        snapshot.sessionChoices = sessionChoices
        snapshot.sessionSelection = sessionSelection
        snapshot.qwenPlan = qwenPlanSnapshot
        snapshot.qwenAccounts = qwenAccountsSnapshot
        snapshot.qwenPlanStale = qwenPlanStale
        // Magpie 管理行 + Codex 重置券/credits + 千问口径差异提示。
        snapshot.magpieRunning = magpieSnapshot.isRunning
        snapshot.magpieError = magpieSnapshot.error
        snapshot.magpieAccountCount = magpieSnapshot.accounts.count
        snapshot.magpieProviders = magpieSnapshot.quotas.map { quota in
            UsageMagpieProviderRow(provider: quota.provider, name: quota.name,
                                   error: quota.error,
                                   summary: Self.magpieSummary(quota))
        }
        if let codex = magpieSnapshot.quota("codex"), magpieSnapshot.isRunning {
            snapshot.codexResetsCount = codex.resetsCount
            snapshot.codexCreditsText = codex.balance
        }
        snapshot.qwenCrossCheckNote = qwenCrossCheckNote
        snapshot.updatedAt = Date()
        panelModel.snapshot = snapshot
        panelController.update(snapshot)
    }

    /// 菜单/面板共用的 provider 摘要：窗口剩余或余额字符串；error 由调用方单独展示。
    private static func magpieSummary(_ quota: MagpieQuota) -> String {
        if quota.error != nil { return "" }
        if quota.windows.isEmpty { return quota.balance ?? "" }
        return quota.windows.map { window in
            if let display = window.display { return "\(window.name) \(display)" }
            guard let remaining = window.remaining else { return window.name }
            return "\(window.name) \(Int(remaining.rounded()))%"
        }.joined(separator: " · ")
    }

    private func quotaRow(label: String, window: QuotaWindow, clockStyle: Bool,
                          windowSeconds: TimeInterval? = nil) -> UsageQuotaRow {
        let percent = window.pct.map { Int(min(max($0, 0), 100).rounded()) }
        let reset = window.reset.map { Date(timeIntervalSince1970: $0) }
        let text: String
        if clockStyle {
            text = UsageFormat.clock(reset)
        } else if let reset, reset > Date() {
            text = Self.remainingText(reset)
        } else {
            text = ""
        }
        return UsageQuotaRow(label: label, remainingPercent: percent, resetText: text,
                             resetAt: reset, windowSeconds: windowSeconds)
    }

    private static func remainingText(_ date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        guard secs > 0 else { return "" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        return d > 0 ? "\(d)d\(h)h" : "\(h)h\((secs % 3600) / 60)m"
    }

    /// 金额固定两位小数：7.3 → "7.30"。
    private static func money(_ value: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: value).doubleValue)
    }

    private static func currencySymbol(_ currency: String) -> String {
        ["CNY": "¥", "USD": "$"][currency.uppercased()] ?? currency.uppercased() + " "
    }

    /// 累计已花 = 累计持有(totalHeld) − 当前余额。两个都是账户接口的真实字段；
    /// 任一缺失或 totalHeld < balance 时返回 nil，界面显示 “—”，绝不写死。
    /// 把 "provider/model" 的今日 token 拆到面板的两个 lane 上，保留前三行。
    private static func modelRows(_ items: [String: Int64], prefixes: [String]) -> [UsageModelRow] {
        items.compactMap { key, tokens -> UsageModelRow? in
            guard let prefix = prefixes.first(where: { key.hasPrefix($0) }) else { return nil }
            let name = String(key.dropFirst(prefix.count))
            guard !name.isEmpty, tokens > 0 else { return nil }
            return UsageModelRow(name: name, tokens: tokens)
        }
        .sorted { $0.tokens > $1.tokens }
        .prefix(3)
        .map { $0 }
    }

    private static func spentText(balance: Decimal?, totalHeld: Decimal?,
                                  currency: String) -> String? {
        guard let balance, let totalHeld, !balance.isNaN, !totalHeld.isNaN,
              totalHeld >= balance else { return nil }
        let spent = totalHeld - balance
        guard !spent.isNaN, spent >= 0 else { return nil }
        return currencySymbol(currency) + money(spent)
    }

    private static func shortDecimal(_ raw: String) -> String {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return raw }
        var rounded = Decimal()
        var input = value
        NSDecimalRound(&rounded, &input, 2, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Data refresh

    /// Force a fresh Codex quota read.
    @objc func refreshForced() {
        doRefresh(force: true)
    }

    @objc func refresh() {
        deepSeekView.refreshPricingStatus()
        DeepSeekHolidayStore.shared.refreshIfNeeded()
        doRefresh(force: false)
    }

    private func doRefresh(force: Bool) {
        refreshDeepSeek(force: force)
        refreshQwenPlan(force: force)
        refreshMagpieActivity(force: force)
        // Magpie 作 Codex 额度的管理视图优先源；它失败/未运行时走现 app-server 链。
        // 60s 缓存命中时 magpieService 直接给出上次好值，不重复触网。
        magpieProvider.fetch(force: force) { [weak self] snapshot in
            guard let self else { return }
            self.magpieSnapshot = snapshot
            self.updateQwenTouchBar()
            if let service = Self.magpieCodexService(snapshot) {
                self.codexView.service = service
                self.syncStatusAttention()
                self.syncPanel()
                return
            }
            self.fetcher.fetch(force: force) { [weak self] service in
                guard let self, let service else { return }
                self.codexView.service = service
                self.syncStatusAttention()
                self.syncPanel()
            }
        }
    }

    /// Magpie codex 订阅窗口 → QuotaService。要求 5h/7d 两窗都有真实 remaining 与
    /// 未来重置时刻；缺任一即 nil（回退 app-server），绝不把 Unknown 当数字。
    static func magpieCodexService(_ snapshot: MagpieProvider.Snapshot) -> QuotaService? {
        guard snapshot.isRunning, !snapshot.stale,
              let codex = snapshot.quota("codex"), codex.error == nil else { return nil }
        func window(_ name: String) -> QuotaWindow? {
            guard let raw = codex.window(named: name), raw.display == nil,
                  let remaining = raw.remaining, remaining.isFinite,
                  let reset = raw.resetsAt, reset > Date() else { return nil }
            return QuotaWindow(pct: min(max(remaining, 0), 100),
                               reset: reset.timeIntervalSince1970)
        }
        guard let five = window("5 hours"), let week = window("7 days") else { return nil }
        return QuotaService(ok: true, stale: false, five: five, week: week,
                            attention: false, source: "magpie")
    }

    private func syncStatusAttention() {
        let attention = codexView.service?.attention == true
        updateStatusAttention(attention)
    }

    @objc private func openCodex() { NSWorkspace.shared.open(URL(string: codexView.fallbackURL)!) }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.fetchLog) {
            try? FileManager.default.createDirectory(atPath: Paths.cacheDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Paths.fetchLog, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.fetchLog))
    }

    // MARK: NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case .codexQuota:
            // 一个 item 里放两个模块：系统只会在 item 之间加那 8pt，内部由我们自己摆 3pt。
            item.view = pairView
            if let constraint = pairWidthConstraint {
                constraint.constant = pairView.currentWidth
                constraint.isActive = true
            } else {
                let constraint = pairView.widthAnchor.constraint(equalToConstant: pairView.currentWidth)
                constraint.isActive = true
                pairWidthConstraint = constraint
            }
        case .deepSeekQuota:
            // 合并后不再需要第二个 item；保留这个 identifier 只为兜底。
            return nil
        default:
            return nil
        }
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
