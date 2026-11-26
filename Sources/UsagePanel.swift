import AppKit
import SwiftUI

// MARK: - Shared data layer

/// 面板「按模型」行：provider/model 的短名 + 今天的 token 数。
struct UsageModelRow: Equatable {
    var name: String
    var tokens: Int64
}

/// 用量接口里的一个会话：累计 token、模型、最后活动时间；标题由 DSH 会话缓存补上。
struct UsageSessionRow: Equatable {
    var id: String
    var title: String?
    var tokens: Int64
    var models: [String]
    var lastAt: Date?
}

/// One quota window rendered in the menu-bar panel (remaining share, never "used").
struct UsageQuotaRow: Equatable {
    var label: String
    var remainingPercent: Int?
    var resetText: String
    /// 窗口重置时刻与窗口长度：用来画 Glance 那条「时间已过」竖刻度。
    /// 任一未知就不画刻度，绝不按“已过一半”之类的假设补位。
    var resetAt: Date? = nil
    var windowSeconds: TimeInterval? = nil

    /// 窗口已经过去的比例（0…1）；未知返回 nil。
    var elapsedShare: Double? {
        guard let resetAt, let windowSeconds, windowSeconds > 0 else { return nil }
        let remaining = resetAt.timeIntervalSinceNow
        guard remaining.isFinite else { return nil }
        let elapsed = windowSeconds - remaining
        return min(max(elapsed / windowSeconds, 0), 1)
    }
}

/// Normalised numbers for the panel. Touch Bar and menu bar both read from here,
/// so the two surfaces can never disagree about what today's usage was.
struct UsageSnapshot: Equatable {
    /// 是否跟随当前 DSH 对话。关闭时整个「当前对话」卡片不出现。
    var followSession = false
    var sessionStatus: DSHSessionStatus = .off
    var sessionChoices: [DSHSessionChoice] = []
    var sessionSelection: String?
    var codexRows: [UsageQuotaRow] = []
    var codexStale = false
    var codexMessage: String?
    var todayOutputTokens: Int64?
    var cacheHitPercent: Double?
    var creditsText: String?
    var creditsNote: String?
    var balanceText: String?
    var balancePercent: Int?
    var deepSeekTodayTokens: Int64?
    /// 本月 1 号到今天（含）的 DeepSeek token 合计；未知为 nil。
    var deepSeekMonthTokens: Int64?
    var deepSeekCacheHitPercent: Double?
    var deepSeekStale = false
    var deepSeekMessage: String?
    /// DeepSeek 近 7 日（旧→新）本地日期 "yyyy-MM-dd" 与对应 token 总量。
    /// 数组为空表示“这一侧没有可用数据”；无记录的那天 token 为 0，界面画成槽位。
    var recentDayLabels: [String] = []
    var recentDayTokens: [Int64] = []
    /// Codex 侧独立的近 7 日数据（口径：input_tokens + output_tokens）。
    var codexRecentDayLabels: [String] = []
    var codexRecentDayTokens: [Int64] = []
    /// 今日按模型拆分的 token（Codex 侧与 DeepSeek 侧分开），面板的「按模型」行用。
    var codexModelRows: [UsageModelRow] = []
    var deepSeekModelRows: [UsageModelRow] = []
    /// 千帆（baidu-pzt）今天的模型行；面板第二行右侧那张卡用。
    var qianfanModelRows: [UsageModelRow] = []
    var qianfanTodayTokens: Int64?
    /// 今天所有 provider 的 token 合计：面板「AI 用量」大数字用它，跟 dsh-usage-stats 一致。
    var todayAllTokens: Int64?
    /// 本周（周一至今）全 provider 合并合计（Magpie 口径）：Codex 卡右上角小字。
    var weekAllTokens: Int64?
    /// 用量接口里的会话清单（累计 token），面板「会话」卡的数据源。
    var usageSessions: [UsageSessionRow] = []
    /// 今天有活动的会话数（用量接口 lastAt 落在今天），「今日共 N 个」用它。
    var todaySessionCount: Int?
    /// 账户累计已花 = 账户累计持有 − 当前余额。缺任一真实字段时为 nil。
    var deepSeekSpentText: String?
    var deepSeekTotalHeldText: String?
    /// 千问 Token Plan 月度额度（直连只读用量接口）；nil 时整卡隐藏。
    var qwenPlan: QwenPlan?
    var qwenAccounts: [QwenPlan] = []
    var qwenPlanStale = false
    /// Magpie 千问供应商今日消耗（provider=qwen）；nil 时该卡隐藏。
    var magpieQwenToday: MagpieDecode.QwenUsage?
    /// Magpie Kimi Code 供应商今日消耗（by.provider.kimi）；nil 时该卡隐藏。
    var magpieKimiToday: MagpieDecode.QwenUsage?
    /// 整段按日明细（Magpie App 热力图同窗口，旧→新）；nil/全 0 时热力图卡隐藏。
    var magpieHeatDays: [MagpieDecode.HeatDay] = []
    /// App 同款 USD→CNY 汇率；nil 时 tooltip 显示 US$。
    var magpieFxRate: Double?
    /// 今日活跃会话数（Magpie 网关口径）；nil 时回退 DSH 读数。
    var magpieTodaySessions: Int?
    /// 最近一条真实对话请求的时刻（Magpie rows）；「N 个会话进行中」判活跃用。
    var magpieRequestAt: Date?
    /// Magpie 管理行：未运行时只显示「Magpie 未运行」，各卡走兜底。
    var magpieRunning = false
    var magpieError: String?
    var magpieAccountCount = 0
    var magpieProviders: [UsageMagpieProviderRow] = []
    /// Codex 重置券与 credits（来自 Magpie quotas，字符串原样）。
    var codexResetsCount = 0
    var codexCreditsText: String?
    /// 朋友源与 Magpie qwen 的口径差异提示（>1pp）。
    var qwenCrossCheckNote: String?
    var updatedAt: Date?
}

/// Magpie 行里的一个 provider 状态 chip。
struct UsageMagpieProviderRow: Equatable {
    var provider: String
    var name: String
    var error: String?
    var summary: String
}

final class UsagePanelModel: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    /// 会话卡默认展开，收起状态记在 UserDefaults 里，下次打开保持。
    @Published var sessionsExpanded: Bool =
        UserDefaults.standard.object(forKey: "panelSessionsExpanded") as? Bool ?? true

    func toggleSessions() {
        sessionsExpanded.toggle()
        UserDefaults.standard.set(sessionsExpanded, forKey: "panelSessionsExpanded")
    }

    var icon: (String) -> NSImage? = { _ in nil }
    var onRefresh: () -> Void = {}
    var onSettings: () -> Void = {}
    var onOpenCodex: () -> Void = {}
    var onOpenDeepSeek: () -> Void = {}
    var onOpenCredits: () -> Void = {}
    var onToggleFollow: () -> Void = {}
    var onSelectSession: (String) -> Void = { _ in }
    var onClearSession: () -> Void = {}
}

// MARK: - Formatting

/// DeepSeek 品牌蓝。macOS 11 没有 NSColor 转 SwiftUI Color 的初始化器，只能用 sRGB 常量。
let usageDeepSeekBlue = Color(red: 0.26, green: 0.48, blue: 1)

enum UsageFormat {
    static func tokens(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        let n = Double(value)
        if n >= 999_995_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 999_995 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1_000 {
            // 999,994 不能写成 “1000.0K”，进位到 M。
            let k = n / 1_000
            if k >= 999.95 { return String(format: "%.2fM", n / 1_000_000) }
            return String(format: "%.1fK", k)
        }
        return String(value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", min(max(value, 0), 100))
    }

    static func remaining(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)%"
    }

    static func clock(_ date: Date?) -> String {
        guard let date, date > Date() else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return "↻" + formatter.string(from: date)
    }

    /// "2026-11-13" → "13"，趋势条下方只标日。格式不合法时返回空串。
    static func dayLabel(_ isoDay: String) -> String {
        let parts = isoDay.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, Int(parts[0]) != nil,
              let month = Int(parts[1]), month >= 1, month <= 12,
              let day = Int(parts[2]), day >= 1, day <= 31 else { return "" }
        return String(day)
    }
}
// MARK: - Glance board
//
// 面板按 Glance（MIT，Copyright (c) 2026 lulu-loopp）的 AI 用量面板 1:1 排布：
// 度量取自 src/ui/view/ai.rs（GAP 14 / ROW_GAP 6 / BAR_BAND 14 / WINDOW 46 / SESSION 44 /
// MODELS_BAR 6 / MODELS_BAR_GAP 10 / PLOT 40）与 src/ui/theme.rs 的 Glass 皮肤
// （pad 18·14·14、lane_gap 8、radius 24、meter 6 r3、Inter 13/12/13/40/15/13）。
// 数字写法同样是它的：万/亿、千分位、「2 小时 10 分后重置」、¥ 两位小数。
// 数据仍全部来自 QuotaStrip 自己的 provider，没有搬运它的数据模型或资源。

enum PanelStyle {
    /// 用户 2026-11-23 要求「缩一个三分之一的宽度」：720 → 480。
    static let width: CGFloat = 480
    /// 窄版下会话改单列，两列各 212pt 会把标题截得太狠。
    static var singleColumnSessions: Bool { width < 560 }
    /// 卡片之间：Glance 的 lane_gap。
    static let cardGap: CGFloat = 8
    /// 卡片内边距：Glance 的 pad_x / pad_top / pad_bottom。
    static let pad: CGFloat = 18
    static let padTop: CGFloat = 14
    static let padBottom: CGFloat = 14
    static let radius: CGFloat = 24

    static let line: CGFloat = 16          // LINE
    static let rowGap: CGFloat = 6          // ROW_GAP
    static let blockGap: CGFloat = 14       // GAP
    static let sourceGap: CGFloat = 22      // SOURCE_GAP
    static let head: CGFloat = 17           // HEAD
    static let plot: CGFloat = 40           // PLOT
    static let barBand: CGFloat = 14        // BAR_BAND
    static let window: CGFloat = line + barBand + line   // 46
    static let windowGap: CGFloat = 16      // WINDOW_GAP
    static let modelsBar: CGFloat = 4       // MODELS_BAR
    /// macOS 26 起有系统的 Liquid Glass 视图；有就用真的，没有才退回 NSVisualEffectView。
    static var nativeGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    static let modelsBarGap: CGFloat = 10   // MODELS_BAR_GAP
    static let session: CGFloat = line + 2 + line + 10   // 44
    static let sessionGap: CGFloat = 10     // SESSION_GAP
    static let columnGap: CGFloat = 16      // 列间距（Glance 的 windows/pairs 用 (width-16)/2）
    static let meter: CGFloat = 6           // Glass meter_height
    static let meterRadius: CGFloat = 3     // Glass meter_radius
    static let hot: Double = 0.9            // HOT

    static let figure: CGFloat = 36
    static let unit: CGFloat = 13
    static let small: CGFloat = 12
    static let body: CGFloat = 13
    static let title: CGFloat = 13
    static let value: CGFloat = 13

    /// 720 − 左右 18 − 中间 8 = 686，两列各 343（Glance 的 Board 只有一层内边距）。
    static let sectionGap: CGFloat = 18
    static let boardGap: CGFloat = 20
    static let laneWidth: CGFloat = (width - 2 * pad - boardGap) / 2
    static let laneInner: CGFloat = laneWidth
    static let fullInner: CGFloat = width - 2 * pad
}

/// Glance 的两套配色：暗色是白字 95/68/46%，浅色是黑字 86/58/42%。
struct PanelSkin {
    var dark: Bool

    var text: Color { dark ? Color.white.opacity(0.95) : Color.black.opacity(0.86) }
    var text2: Color { dark ? Color.white.opacity(0.70) : Color.black.opacity(0.66) }
    var text3: Color { dark ? Color.white.opacity(0.50) : Color.black.opacity(0.48) }
    var rule: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }
    var track: Color { dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10) }
    var signal: Color {
        dark ? Color(red: 1.0, green: 0.412, blue: 0.380)
             : Color(red: 1.0, green: 0.231, blue: 0.188)
    }
    /// 整块面板只有一层磨砂底，卡片不再单独铺底；这里只留一条 1pt 外框。
    var outline: Color { dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10) }

    func ink(_ brand: PanelBrand) -> Color {
        switch brand {
        case .codex:
            return dark ? Color(red: 0.310, green: 0.757, blue: 0.706)
                        : Color(red: 0.122, green: 0.561, blue: 0.518)
        case .deepSeek:
            return dark ? Color(red: 0.482, green: 0.569, blue: 1.0)
                        : Color(red: 0.302, green: 0.420, blue: 0.996)
        case .ai:
            return dark ? Color(red: 0.239, green: 0.608, blue: 1.0)
                        : Color(red: 0.039, green: 0.478, blue: 1.0)
        }
    }
}

enum PanelBrand {
    case codex
    case deepSeek
    case ai
}

/// Glance 的数字写法（ai.rs 的 tokens / figure / short / money / left_in）。
enum GlanceFormat {
    /// 千分位整数。
    static func grouped(_ value: Int64) -> String {
        let negative = value < 0
        var digits = String(value.magnitude)
        var out = ""
        while digits.count > 3 {
            out = "," + digits.suffix(3) + out
            digits = String(digits.dropLast(3))
        }
        out = digits + out
        return negative ? "-" + out : out
    }

    /// 大数字：小于 10 保留一位小数，否则四舍五入后加千分位。
    static func figure(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        if value < 10 { return String(format: "%.1f", value) }
        return grouped(Int64(value.rounded()))
    }

    /// 今日大数字 + 单位：63,680,000 → ("6,368", "万 tokens")。
    static func tokensFigure(_ value: Int64?) -> (figure: String, unit: String) {
        guard let value, value > 0 else { return ("0", L("tokens", "tokens")) }
        let n = Double(value)
        if n >= 99_999_500 { return (figure(n / 100_000_000), L("100M tokens", "亿 tokens")) }
        if n >= 9_999.5 { return (figure(n / 10_000), L("10K tokens", "万 tokens")) }
        return (figure(n), L("tokens", "tokens"))
    }

    /// 行内短数字：6,368 万 / 1,038 万 / 512。
    static func short(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        let n = Double(value)
        if n >= 99_999_500 { return figure(n / 100_000_000) + L("B", " 亿") }
        if n >= 9_999.5 { return figure(n / 10_000) + L("K", " 万") }
        return grouped(value)
    }

    /// 金额：¥ 两位小数。
    static func money(_ text: String?, currency: String = "CNY") -> String {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "—" }
        let symbol = (raw.contains("USD") || raw.hasPrefix("$")) ? "$" : "¥"
        let digits = raw.filter { "0123456789.".contains($0) }
        guard let value = Double(digits) else { return "—" }
        return symbol + String(format: "%.2f", value)
    }

    /// 「2 小时 10 分」「4 天 16 小时」「3 分钟」：保留两个非零档。
    static func leftIn(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        guard seconds > 0 else { return L("now", "现在") }
        let minutes = max(1, (seconds + 59) / 60)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 {
            return hours > 0 ? "\(days) \(L("days", "天")) \(hours) \(L("hours", "小时"))"
                             : "\(days) \(L("days", "天"))"
        }
        if hours > 0 {
            return mins > 0 ? "\(hours) \(L("hours", "小时")) \(mins) \(L("minutes", "分"))"
                            : "\(hours) \(L("hours", "小时"))"
        }
        return "\(minutes) \(L("minutes", "分钟"))"
    }

    /// 窗口名：5h / 7d 直接用短标签（用户要求），其余保留中文全称。
    static func windowName(_ label: String) -> String {
        switch label.lowercased() {
        case "5h", "5 h": return "5h"
        case "1h": return L("1 hour", "1 小时")
        case "24h", "1d", "daily", "day": return L("Daily", "每天")
        case "7d", "week", "weekly": return "7d"
        case "30d", "month", "monthly": return L("Monthly", "每月")
        default: return label
        }
    }

    /// 重置时刻的「实际钟点」：5h 窗口只给 HH:mm，长窗口给 MM-dd HH:mm。
    /// 用户要的是「几点重置」，不是「还剩多久」——倒计时会和钟点混淆。
    static func resetClock(_ date: Date, label: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let short = ["5h", "5 h", "1h"].contains(label.lowercased())
        formatter.dateFormat = short ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date) + " " + L("reset", "重置")
    }

    /// 「3 分钟前」「1 天前」。
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return L("just now", "刚刚") }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) " + L("min ago", "分钟前") }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) " + L("h ago", "小时前") }
        return "\(hours / 24) " + L("d ago", "天前")
    }
}

struct UsagePanelView: View {
    @ObservedObject var model: UsagePanelModel
    @Environment(\.colorScheme) private var scheme

    private var skin: PanelSkin { PanelSkin(dark: scheme == .dark) }

    var body: some View {
        let rowHeight = max(todayCardHeight, codexCardHeight)
        return VStack(alignment: .leading, spacing: PanelStyle.sectionGap) {
            HStack(alignment: .top, spacing: PanelStyle.boardGap) {
                // 顶对齐 + 底行前留弹性 spacer：两列底行（workingRow / pairs）落在同一 y。
                todayCard.frame(width: PanelStyle.laneWidth, height: rowHeight, alignment: .top)
                codexCard.frame(width: PanelStyle.laneWidth, height: rowHeight, alignment: .top)
            }
            // 千帆不是另一张卡：它的用量直接接在 DeepSeek 的模型行下面。
            deepSeekCard
            // 千问 Token Plan：没有数据时整卡不出现，不留空卡。
            if model.snapshot.qwenPlan != nil {
                qwenPlanCard
            }
            // Magpie 千问供应商消耗（今日，provider=qwen）：跟在 Token Plan 卡下面。
            if model.snapshot.magpieQwenToday != nil {
                magpieQwenCard
            }
            if model.snapshot.magpieKimiToday != nil {
                magpieKimiCard
            }
            // Magpie 用量热力图（整段历史、一天一格，与 App 同窗口）：无数据时整卡不出现。
            if model.snapshot.magpieHeatDays.contains(where: { $0.tokens > 0 }) {
                heatmapCard(model.snapshot.magpieHeatDays)
            }
            // 会话卡与千问「今日本地」行已按用户要求下线（Magpie 已覆盖这两块读数）；
            // 会话卡实现保留在下方，需要时把 sessionsCard 加回这里即可。
        }
        .padding(.horizontal, PanelStyle.pad)
        .padding(.vertical, PanelStyle.padTop)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: PanelStyle.width, alignment: .leading)
        // 一整块连续磨砂底：桌面从背后透上来，区块靠留白分层。
        .background(Group {
            if PanelStyle.nativeGlass {
                // 背景由窗口里的 NSGlassEffectView 实时折射，SwiftUI 这边必须是全透明，
                // 否则等于在玻璃上又糊一层色板。
                Color.clear
            } else {
                ZStack {
                    VisualEffectBackground()
                    panelWash
                }
            }
        })
        // 系统玻璃的边缘高光在无边框面板里偏弱，补一层很薄的受光/内阴影，
        // 压在白色窗口上时也能读出「这是一块玻璃」而不是白卡片。
        .overlay(GlassSheen(dark: skin.dark, strong: PanelStyle.nativeGlass))
        .clipShape(RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous))
        // 玻璃边缘：上沿受光更亮、下沿更暗，1pt 的渐变描边把「厚度」读出来。
        .overlay(RoundedRectangle(cornerRadius: PanelStyle.radius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(skin.dark ? 0.28 : 0.85), location: 0.0),
                        .init(color: skin.outline, location: 0.45),
                        .init(color: (skin.dark ? Color.white : Color.black).opacity(skin.dark ? 0.10 : 0.12), location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1))
    }

    /// 参考图里整块 Board 都带着一层很淡的品牌色渐变（Claude 那边的暖色、
    /// ChatGPT 那边的青色），但它是铺在同一个平面上的，不是每张卡自己铺底。
    private var panelWash: some View {
        let indigo = skin.ink(.deepSeek)
        let teal = skin.ink(.codex)
        return LinearGradient(stops: [
            .init(color: indigo.opacity(skin.dark ? 0.10 : 0.075), location: 0.0),
            .init(color: indigo.opacity(skin.dark ? 0.045 : 0.035), location: 0.38),
            .init(color: teal.opacity(skin.dark ? 0.075 : 0.055), location: 0.72),
            .init(color: Color.clear, location: 1.0),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: 卡片高度（两侧同高，和 Glance 的一行两卡一致）

    private var todayCardHeight: CGFloat {
        PanelStyle.head + PanelStyle.blockGap + PanelStyle.plot
            + PanelStyle.sourceGap + PanelStyle.line
    }

    private var codexCardHeight: CGFloat {
        var height = PanelStyle.head + PanelStyle.blockGap
            + PanelStyle.window + PanelStyle.blockGap + PanelStyle.line
        let models = model.snapshot.codexModelRows.count
        if models > 0 {
            height += PanelStyle.blockGap + PanelStyle.modelsBar + PanelStyle.modelsBarGap
            height += CGFloat(models) * PanelStyle.line + CGFloat(max(0, models - 1)) * PanelStyle.rowGap
        }
        // Magpie 重置券/credits 行：有内容才占高度，避免与今日输出行重叠。
        if model.snapshot.codexResetsCount > 0 || model.snapshot.codexCreditsText != nil {
            height += PanelStyle.blockGap + PanelStyle.line
        }
        return height
    }

    // MARK: 卡片外壳

    /// 区块外壳。Glance 的 Board 只有一整块磨砂面板，区块之间靠留白分隔，
    /// 所以这里只保留内边距，不再给每个区块铺底色或描边。
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 标题行（mark 16 + 7 + title + 8 + device + 右对齐 aside）

    private func head(title: String, device: String? = nil, aside: String? = nil,
                      brand: PanelBrand? = nil, icon: String? = nil,
                      symbol: String? = nil,
                      trailing: AnyView? = nil) -> some View {
        HStack(spacing: 0) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(skin.text2)
                    .frame(width: 16, height: 16)
                Spacer().frame(width: 7)
            } else if let icon, let image = model.icon(icon) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 16, height: 16)
                Spacer().frame(width: 7)
            } else if let brand {
                RoundedRectangle(cornerRadius: 5)
                    .fill(skin.ink(brand))
                    .frame(width: 16, height: 16)
                Spacer().frame(width: 7)
            }
            Text(title)
                .font(.system(size: PanelStyle.title, weight: .semibold))
                .foregroundColor(skin.text)
                .lineLimit(1)
            if let device, !device.isEmpty {
                Spacer().frame(width: 8)
                Text(device)
                    .font(.system(size: PanelStyle.small, weight: .medium))
                    .foregroundColor(skin.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let aside, !aside.isEmpty {
                Text(aside)
                    .font(.system(size: PanelStyle.small, weight: .medium))
                    .foregroundColor(skin.text3)
                    .lineLimit(1)
            }
            if let trailing {
                trailing
            }
        }
        .frame(height: PanelStyle.head)
    }

    // MARK: 今日卡（Glance 的 Today 块 + Working 块）

    private var todayCard: some View {
        let tokens = GlanceFormat.tokensFigure(model.snapshot.todayAllTokens
                                               ?? model.snapshot.deepSeekTodayTokens)
        return card {
            VStack(alignment: .leading, spacing: 0) {
                head(title: L("AI usage", "AI 用量"),
                     aside: L("Today", "今日"))
                Spacer().frame(height: PanelStyle.blockGap)
                HStack(alignment: .bottom, spacing: 0) {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(tokens.figure)
                            .font(.system(size: PanelStyle.figure, weight: .semibold))
                            .kerning(PanelStyle.figure * -0.035)
                            .foregroundColor(skin.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(tokens.unit)
                            .font(.system(size: PanelStyle.unit, weight: .medium))
                            .foregroundColor(skin.text2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    UsageAreaChart(values: model.snapshot.recentDayTokens, tint: skin.ink(.ai))
                        .frame(width: 72, height: PanelStyle.plot)
                        .help(L("Last 7 days", "近 7 日"))
                }
                .frame(height: PanelStyle.plot, alignment: .bottom)
                Spacer(minLength: PanelStyle.sourceGap)
                workingRow
            }
        }
    }

    private var workingRow: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(skin.ink(.ai))
                .frame(width: 3.5, height: 3.5)
            Spacer().frame(width: 8)
            Text(workingText)
                .font(.system(size: PanelStyle.small, weight: .medium))
                .foregroundColor(skin.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(todayTotalText)
                .font(.system(size: PanelStyle.small, weight: .medium))
                .foregroundColor(skin.text3)
                .lineLimit(1)
        }
        .frame(height: PanelStyle.line)
    }

    private var workingText: String {
        // Magpie 主源：最近 120s 内有真实对话请求就算「1 个会话进行中」
        //（rows 只反映最新一条，多会话并发无法从 limit=100 精确判定，不猜 N）。
        if let at = model.snapshot.magpieRequestAt, Date().timeIntervalSince(at) <= 120 {
            return L("1 session at work", "1 个会话进行中")
        }
        if model.snapshot.magpieRunning {
            return L("No session at work", "没有进行中的会话")
        }
        // Magpie 不可用才回退 DSH 跟随状态。
        if case .live = model.snapshot.sessionStatus {
            return L("1 session at work", "1 个会话进行中")
        }
        let count = model.snapshot.sessionChoices.count
        return count > 0 ? L("\(count) sessions at work", "\(count) 个会话进行中")
                         : L("No session at work", "没有进行中的会话")
    }

    private var todayTotalText: String {
        // 「今日共 N 个」主源 = Magpie 今日活跃会话；nil 才回退 DSH。
        let count = model.snapshot.magpieTodaySessions
            ?? model.snapshot.todaySessionCount
            ?? model.snapshot.sessionChoices.count
        return count > 0 ? L("\(count) today", "今日共 \(count) 个") : ""
    }

    // MARK: Codex 卡（Windows / Models / Pairs）

    private var codexCard: some View {
        // 右上角小字：本周总用量（Magpie 合并口径，周一至今），不再显示 Codex 单日数。
        let weekAside = model.snapshot.weekAllTokens.map { L("Week ", "本周 ") + GlanceFormat.short($0) }
        return card {
            VStack(alignment: .leading, spacing: 0) {
                head(title: "Codex",
                     aside: weekAside,
                     icon: "codex-logo")
                Spacer().frame(height: PanelStyle.blockGap)
                windows(model.snapshot.codexRows, brand: .codex)
                if !model.snapshot.codexModelRows.isEmpty {
                    Spacer().frame(height: PanelStyle.blockGap)
                    models(model.snapshot.codexModelRows, brand: .codex)
                }
                // Magpie 侧的重置券与 credits 余额（字符串原样，不换算）。
                if model.snapshot.codexResetsCount > 0 || model.snapshot.codexCreditsText != nil {
                    Spacer().frame(height: PanelStyle.blockGap)
                    HStack(spacing: 8) {
                        if model.snapshot.codexResetsCount > 0 {
                            Text(L("Resets ×\(model.snapshot.codexResetsCount)", "重置券 ×\(model.snapshot.codexResetsCount)"))
                                .font(.system(size: PanelStyle.small, weight: .medium))
                                .foregroundColor(skin.text2)
                                .lineLimit(1)
                        }
                        if let credits = model.snapshot.codexCreditsText {
                            Text(credits)
                                .font(.system(size: PanelStyle.small, weight: .medium))
                                .foregroundColor(skin.text3)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: PanelStyle.line)
                }
                // 弹性间距：AI 卡更高时把 pairs 压到卡底，与左列 workingRow 同基线。
                Spacer(minLength: PanelStyle.blockGap)
                pairs([(L("Output today", "今日输出"),
                        model.snapshot.todayOutputTokens.map { GlanceFormat.short($0) } ?? "—"),
                       (L("Cached input", "输入缓存"),
                        UsageFormat.percent(model.snapshot.cacheHitPercent))])
            }
        }
    }

    // MARK: DeepSeek 卡（Head / Pairs）

    private var deepSeekCard: some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                head(title: "DeepSeek",
                     device: "API",
                     aside: GlanceFormat.relative(model.snapshot.updatedAt),
                     icon: "deepseek-logo")
                if !sourceModelRows.isEmpty {
                    Spacer().frame(height: PanelStyle.blockGap)
                    mixedModels(sourceModelRows)
                }
                Spacer().frame(height: PanelStyle.blockGap)
                pairs([(L("Balance", "余额"),
                        GlanceFormat.money(model.snapshot.balanceText)),
                       (L("Spent", "累计已花"),
                        model.snapshot.deepSeekSpentText.map { GlanceFormat.money($0) } ?? "—")])
            }
        }
    }

    /// DeepSeek 官方行在前，千帆（baidu-pzt）紧接下一行，同一条份额条里按品牌着色。
    private var sourceModelRows: [(UsageModelRow, PanelBrand)] {
        let deepSeek = model.snapshot.deepSeekModelRows.map { ($0, PanelBrand.deepSeek) }
        let qianfan = model.snapshot.qianfanModelRows.map { ($0, PanelBrand.ai) }
        // deepseek-account 与 deepseek-official 会报同一个模型名（如 deepseek-flash），
        // 直接拼接会出现两行同名不同数字；这里按显示名合并，品牌取贡献更大的那一路。
        var merged: [String: (UsageModelRow, PanelBrand)] = [:]
        for (row, brand) in deepSeek + qianfan {
            let key = mixedModelName(row.name, brand: brand)
            if let existing = merged[key] {
                let total = existing.0.tokens + row.tokens
                let winner = row.tokens > existing.0.tokens ? brand : existing.1
                merged[key] = (UsageModelRow(name: key, tokens: total), winner)
            } else {
                merged[key] = (UsageModelRow(name: key, tokens: row.tokens), brand)
            }
        }
        return merged.values.sorted { $0.0.tokens > $1.0.tokens }
    }

    private func mixedModels(_ rows: [(UsageModelRow, PanelBrand)]) -> some View {
        let top = Array(rows.prefix(4))
        let total = max(top.reduce(Int64(0)) { $0 + max(0, $1.0.tokens) }, 1)
        return VStack(alignment: .leading, spacing: 0) {
            sharesMixed(top, total: total)
                .frame(height: PanelStyle.modelsBar)
            Spacer().frame(height: PanelStyle.modelsBarGap)
            ForEach(Array(top.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(skin.ink(item.1).opacity(1 - Double(index) * 0.12))
                        .frame(width: 8, height: 8)
                    Spacer().frame(width: 14)
                    Text(mixedModelName(item.0.name, brand: item.1))
                        .font(.system(size: PanelStyle.small, weight: .medium))
                        .foregroundColor(skin.text2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(GlanceFormat.short(item.0.tokens))
                        .font(.system(size: PanelStyle.small, weight: .medium))
                        .foregroundColor(skin.text)
                        .lineLimit(1)
                }
                .frame(height: PanelStyle.line)
                .padding(.bottom, index == top.count - 1 ? 0 : PanelStyle.rowGap)
            }
        }
    }

    private func sharesMixed(_ rows: [(UsageModelRow, PanelBrand)], total: Int64) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(skin.track)
                HStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                        Rectangle()
                            .fill(skin.ink(item.1).opacity(1 - Double(index) * 0.12))
                            .frame(width: max(0, CGFloat(max(0, item.0.tokens)) / CGFloat(total)) * proxy.size.width)
                    }
                }
                .clipShape(Capsule())
            }
        }
    }

    /// 千帆的行前面带一个「千帆 · 」，读者一眼知道它来自另一个供应商。
    private func mixedModelName(_ name: String, brand: PanelBrand) -> String {
        let short = shortModelName(name)
        return brand == .ai ? short : short
    }

    // MARK: 千问 Token Plan 卡（月度额度；nil 时由 body 整卡隐藏）

    private var qwenPlanCard: some View {
        // 多账号：accounts 端点有几个池子画几块；旧单账号形状退回一块。
        let plans = model.snapshot.qwenAccounts.isEmpty
            ? [model.snapshot.qwenPlan].compactMap { $0 }
            : model.snapshot.qwenAccounts
        let firstStale = model.snapshot.qwenPlanStale || (plans.first?.isStale() ?? false)
        return card {
            VStack(alignment: .leading, spacing: 0) {
                head(title: L("Qwen Token Plan", "千问 Token Plan"),
                     aside: qwenPlanAside(plans.first, stale: firstStale),
                     symbol: "sparkles")
                ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
                    Spacer().frame(height: PanelStyle.blockGap)
                    qwenAccountBlock(plan, showLabel: plans.count > 1)
                }
                if let note = model.snapshot.qwenCrossCheckNote {
                    Spacer().frame(height: 2)
                    Text(note)
                        .font(.system(size: PanelStyle.small, weight: .medium))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
            }
        }
    }

    /// 单个账号块：剩余% + 上限/重置；models/keys 非空才加明细行（空数组兼容）。
    private func qwenAccountBlock(_ plan: QwenPlan, showLabel: Bool) -> some View {
        let window = plan.monthlyWindow
        let stale = model.snapshot.qwenPlanStale || plan.isStale()
        return VStack(alignment: .leading, spacing: 2) {
            if showLabel && !plan.label.isEmpty {
                Text(plan.label)
                    .font(.system(size: PanelStyle.small, weight: .semibold))
                    .foregroundColor(skin.text2)
                    .lineLimit(1)
            }
            if let window {
                HStack(alignment: .bottom, spacing: 0) {
                    Text(UsageFormat.percent(window.remainingPercent))
                        .font(.system(size: PanelStyle.figure, weight: .semibold))
                        .kerning(PanelStyle.figure * -0.035)
                        .foregroundColor(skin.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(stale ? 0.45 : 1)
                    Spacer().frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(qwenPlanLimitLine(window))
                            .font(.system(size: PanelStyle.small, weight: .medium))
                            .foregroundColor(skin.text2)
                            .lineLimit(1)
                        if let resetText = qwenPlanResetText(window) {
                            Text(resetText)
                                .font(.system(size: PanelStyle.small, weight: .medium))
                                .foregroundColor(skin.text3)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: PanelStyle.plot, alignment: .bottom)
            }
            if !plan.models.isEmpty {
                Text(qwenUsageLineText(L("Models", "模型"), plan.models))
                    .font(.system(size: PanelStyle.small, weight: .medium))
                    .foregroundColor(skin.text3)
                    .lineLimit(2)
            }
            if !plan.keys.isEmpty {
                Text(qwenUsageLineText(L("Keys", "钥匙"), plan.keys))
                    .font(.system(size: PanelStyle.small, weight: .medium))
                    .foregroundColor(skin.text3)
                    .lineLimit(2)
            }
        }
    }

    /// 「模型：qwen4-max 62% · flash 38%」；有 share 用 share，否则用 used 整数。
    private func qwenUsageLineText(_ title: String, _ lines: [QwenUsageLine]) -> String {
        let parts = lines.prefix(3).map { line -> String in
            if let share = line.share { return line.label + " " + UsageFormat.percent(share) }
            if let used = line.used { return line.label + " " + GlanceFormat.grouped(Int64(used.rounded())) }
            return line.label
        }
        return title + "：" + parts.joined(separator: " · ")
    }

    /// aside：套餐 · 状态（· 过期）。
    private func qwenPlanAside(_ plan: QwenPlan?, stale: Bool) -> String {
        guard let plan else { return "" }
        var parts: [String] = []
        if !plan.plan.isEmpty { parts.append(plan.plan) }
        if !plan.status.isEmpty { parts.append(plan.status) }
        if stale { parts.append(L("Stale", "过期")) }
        return parts.joined(separator: " · ")
    }

    /// 「月度 Credits · 上限 80,000」；没有 limit 时只显示窗口名。
    private func qwenPlanLimitLine(_ window: QwenPlanWindow) -> String {
        let label = window.label.isEmpty ? L("Monthly Credits", "月度 Credits") : window.label
        guard let limit = window.limit else { return label }
        return label + " · " + L("cap ", "上限 ") + GlanceFormat.grouped(Int64(limit.rounded()))
    }

    /// 「12-16 重置」；没有 reset 时间就不占这一行。
    private func qwenPlanResetText(_ window: QwenPlanWindow) -> String? {
        guard let reset = window.resetAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: reset) + " " + L("reset", "重置")
    }

    // MARK: Magpie 千问供应商卡（今日消耗 + 按模型；跟在 Token Plan 卡下方）

    private var magpieQwenCard: some View {
        magpieProviderCard(title: L("Qwen via Magpie", "千问 · Magpie"),
                           usage: model.snapshot.magpieQwenToday)
    }

    private var magpieKimiCard: some View {
        magpieProviderCard(title: L("Kimi Code via Magpie", "Kimi Code · Magpie"),
                           usage: model.snapshot.magpieKimiToday)
    }

    private func magpieProviderCard(title: String, usage: MagpieDecode.QwenUsage?) -> some View {
        // 按模型行复用 Codex 卡的 models 组件：份额条 + 名称 + token 短数字。
        let rows = (usage?.models ?? [])
            .map { UsageModelRow(name: $0.name, tokens: $0.tokens) }
        return card {
            VStack(alignment: .leading, spacing: 0) {
                head(title: title,
                     aside: L("Today", "今日"),
                     icon: "magpie-logo")
                if !rows.isEmpty {
                    Spacer().frame(height: PanelStyle.blockGap)
                    models(rows, brand: .ai)
                }
                // 用户 2026-11-27：汇总四行与模型行信息重复，只留份额条 + 按模型数字；
                // 数据仍解码保留（Touch Bar/后续可用）。
            }
        }
    }

    // MARK: Magpie 用量热力图（App 同款：整段历史、月份表头、周一…周日七行）

    private func heatmapCard(_ days: [MagpieDecode.HeatDay]) -> some View {
        HeatmapCard(days: days, skin: skin, content: heatmapCardContent)
    }

    private func heatmapCardContent(_ days: [MagpieDecode.HeatDay], skin: PanelSkin) -> some View {
        let peak = max(days.map { $0.tokens }.max() ?? 1, 1)
        let total = days.reduce(Int64(0)) { $0 + $1.tokens }
        let active = days.filter { $0.tokens > 0 }.count
        // 按周分列（周一开头），一列一周、七行；数据范围外的格留空槽。
        let columns = heatColumns(days)
        // 格子尺寸按列数自适应：444pt 里去掉左侧星期标签后铺满整行。
        let labelWidth: CGFloat = 30
        let gap: CGFloat = 3
        let available = PanelStyle.fullInner - labelWidth - 8
        let cell = max(6, min(14, (available - CGFloat(columns.count - 1) * gap) / CGFloat(max(columns.count, 1))))
        return card {
            VStack(alignment: .leading, spacing: 0) {
                head(title: L("Usage heatmap", "用量热力图"),
                     aside: L("\(active) active days", "\(active) 个活跃天"),
                     icon: "magpie-logo",
                     trailing: AnyView(heatLegend))
                Spacer().frame(height: 8)
                // 月份表头：每列周首日跨月时标「N月」，与 App 一致。
                HStack(spacing: gap) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        Text(heatMonthLabel(columns, index))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(skin.text3)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: cell, alignment: .leading)
                    }
                }
                .padding(.leading, labelWidth + 8)
                Spacer().frame(height: 4)
                HStack(alignment: .top, spacing: 8) {
                    // 左侧星期标签：周一/周三/周五/周日（App 同款隔行标）。
                    VStack(alignment: .trailing, spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(heatWeekday(row))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(skin.text3)
                                .frame(width: labelWidth, height: cell, alignment: .trailing)
                        }
                    }
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: gap) {
                                ForEach(Array(column.enumerated()), id: \.offset) { _, item in
                                    if let item {
                                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                            .fill(heatColor(value: item.tokens, peak: peak))
                                            .frame(width: cell, height: cell)
                                            .background(HeatCellHover(day: item))
                                    } else {
                                        Color.clear.frame(width: cell, height: cell)
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                Spacer().frame(height: PanelStyle.blockGap)
                pairs([(L("Total", "合计"), GlanceFormat.short(total)),
                       (L("Peak day", "峰值日"), peakDayText(days))])
            }
        }
    }

    struct HeatHover {
        var get: () -> MagpieDecode.HeatDay?
        var set: (MagpieDecode.HeatDay?) -> Void
    }

    struct HeatHoverKey: EnvironmentKey {
        static let defaultValue = HeatHover(get: { nil }, set: { _ in })
    }

    private struct HeatCellHover: NSViewRepresentable {
        let day: MagpieDecode.HeatDay
        @Environment(\.heatHover) private var hover

        func makeNSView(context: Context) -> HeatTrackingView {
            let view = HeatTrackingView()
            view.onHover = { entered in hover.set(entered ? day : nil) }
            return view
        }

        func updateNSView(_ view: HeatTrackingView, context: Context) {
            view.onHover = { entered in hover.set(entered ? day : nil) }
        }
    }

    private final class HeatTrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 仅监听悬停，不能吃掉面板的滚动和点击。
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }

    /// 系统 .help 在这个非激活玻璃面板里收不到 hover，改由 AppKit tracking area
    /// 直接上报格子坐标；浮层画在面板内部，不额外开窗口。
    private struct HeatmapCard<Content: View>: View {
        let days: [MagpieDecode.HeatDay]
        let skin: PanelSkin
        @ViewBuilder let content: ([MagpieDecode.HeatDay], PanelSkin) -> Content
        @State private var hovered: MagpieDecode.HeatDay?

        var body: some View {
            ZStack(alignment: .top) {
                content(days, skin)
                if let day = hovered {
                    HeatTooltipBubble(day: day)
                        .padding(.top, PanelStyle.head + 8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .environment(\.heatHover, HeatHover(get: { hovered }, set: { day in
                guard day != hovered else { return }
                withAnimation(.easeInOut(duration: 0.08)) { hovered = day }
            }))
        }
    }

    private struct HeatTooltipBubble: View {
        let day: MagpieDecode.HeatDay

        var body: some View {
            let lines = UsagePanelView.heatTooltipLines(day)
            VStack(alignment: .leading, spacing: 4) {
                Text(lines.0)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                Text(lines.1)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
    }

    /// 标题行右侧图例：少 □□□□□ 多（App 同款，横排省高度）。
    private var heatLegend: some View {
        HStack(spacing: 4) {
            Text(L("Less", "少"))
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(skin.text3)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(skin.track).frame(width: 9, height: 9)
            ForEach([0.35, 0.55, 0.78, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(skin.ink(.ai).opacity(level)).frame(width: 9, height: 9)
            }
            Text(L("More", "多"))
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(skin.text3)
        }
        .padding(.leading, 10)
    }

    /// 该列周首日的月份；只在与上一列不同月时显示（第一列必显）。
    private func heatMonthLabel(_ columns: [[MagpieDecode.HeatDay?]], _ index: Int) -> String {
        guard let first = columns[index].compactMap({ $0 }).first else { return "" }
        let month = String(first.label.dropFirst(5).prefix(2))
        if index > 0, let prev = columns[index - 1].compactMap({ $0 }).first,
           String(prev.label.dropFirst(5).prefix(2)) == month {
            return ""
        }
        return month.hasPrefix("0") ? String(month.dropFirst()) + L("", "月") : month + L("", "月")
    }

    /// 把按日明细铺进「周一开头」的周列；不在序列里的格是 nil（空槽）。
    private func heatColumns(_ days: [MagpieDecode.HeatDay]) -> [[MagpieDecode.HeatDay?]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var cells: [(row: Int, week: Int, cell: MagpieDecode.HeatDay)] = []
        var anchor: Date?
        for item in days {
            guard let date = formatter.date(from: item.label) else { continue }
            if anchor == nil {
                anchor = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            }
            guard let start = anchor else { continue }
            let day = calendar.startOfDay(for: date)
            let row = calendar.component(.weekday, from: day) // 周日=1…周六=7
            let mondayRow = (row + 5) % 7                     // 周一=0…周日=6
            let week = calendar.dateComponents([.day], from: start, to: day).day.map { $0 / 7 } ?? 0
            cells.append((mondayRow, week, item))
        }
        let weeks = (cells.map { $0.week }.max() ?? 0) + 1
        var columns = Array(repeating: Array<MagpieDecode.HeatDay?>(repeating: nil, count: 7), count: weeks)
        for item in cells where item.week >= 0 && item.week < weeks {
            columns[item.week][item.row] = item.cell
        }
        return columns
    }

    /// 周一=0…周日=6 的标签；隔行显示（App 同款），其余留空保持格高。
    private func heatWeekday(_ row: Int) -> String {
        switch row {
        case 0: return L("Mon", "周一")
        case 2: return L("Wed", "周三")
        case 4: return L("Fri", "周五")
        case 6: return L("Sun", "周日")
        default: return ""
        }
    }

    /// App 同款四档量化着色：0 → 轨道色；有量按 sqrt 比例分四档蓝，
    /// 档间对比明显（用户反馈渐变式颜色区分不出来）。
    private func heatColor(value: Int64, peak: Int64) -> Color {
        guard value > 0 else { return skin.track }
        let ratio = Double(value).squareRoot() / Double(peak).squareRoot()
        let level: Double
        switch ratio {
        case ..<0.35: level = 0.35
        case ..<0.6: level = 0.55
        case ..<0.85: level = 0.78
        default: level = 1.0
        }
        return skin.ink(.ai).opacity(level)
    }

    /// 悬停只保留日期、星期与当天总 token，不重复展示请求数和金额。
    private static func heatTooltipLines(_ day: MagpieDecode.HeatDay) -> (String, String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var dateText = day.label
        if let date = formatter.date(from: day.label) {
            let weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let index = Calendar.current.component(.weekday, from: date) - 1
            let parts = day.label.split(separator: "-")
            if parts.count == 3 {
                dateText = L("\(day.label)", "\(parts[0])年\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日")
                    + " " + L("", weekday[index])
            }
        }
        if day.tokens <= 0 && day.calls <= 0 {
            return (dateText, L("no usage", "无用量"))
        }
        return (dateText, Self.heatTokensText(day.tokens) + " token")
    }

    /// App 口径的 token 写法：≥1 万给一位小数「3678.2 万」，≥1 亿「3.8 亿」。
    private static func heatTokensText(_ value: Int64) -> String {
        let n = Double(value)
        if n >= 100_000_000 { return String(format: "%.1f", n / 100_000_000) + L("B", " 亿") }
        if n >= 10_000 { return String(format: "%.1f", n / 10_000) + L("0K", " 万") }
        return GlanceFormat.grouped(value)
    }

    private func peakDayText(_ days: [MagpieDecode.HeatDay]) -> String {
        guard let top = days.max(by: { $0.tokens < $1.tokens }), top.tokens > 0 else { return "—" }
        // "2026-11-26" → "11-26"
        let short = String(top.label.dropFirst(5))
        return short + " · " + GlanceFormat.short(top.tokens)
    }

    // MARK: 会话卡

    private var sessionsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                head(title: L("Sessions", "会话"),
                     aside: sessionAside,
                     trailing: AnyView(disclosure))
                if model.sessionsExpanded && !sessionRows.isEmpty {
                    Spacer().frame(height: PanelStyle.blockGap)
                    sessionGrid
                }
            }
        }
    }

    private var disclosure: some View {
        Button {
            model.toggleSessions()
        } label: {
            Image(systemName: model.sessionsExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(skin.text3)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.sessionsExpanded ? L("Collapse sessions", "收起会话")
                                    : L("Expand sessions", "展开会话"))
    }

    private var sessionAside: String {
        if case .live(let usage) = model.snapshot.sessionStatus {
            return usage.autoSelected ? L("auto-followed", "自动跟随") : L("followed", "已选定")
        }
        return ""
    }

    private struct SessionLine {
        var id: String
        var title: String
        var about: String
        var tokens: String
        var active: Bool
        var brand: PanelBrand
        /// 混用多个模型：图标用中性多模型符号，而不是某一家品牌 logo。
        var mixed: Bool = false
    }

    private var sessionRows: [SessionLine] {
        let liveId: String? = {
            if case .live(let usage) = model.snapshot.sessionStatus { return usage.sessionId }
            return nil
        }()
        if !model.snapshot.usageSessions.isEmpty {
            let rows = model.snapshot.usageSessions.map { row -> SessionLine in
                let id = row.id.hasPrefix("session-") ? row.id : "session-" + row.id
                return SessionLine(id: id,
                                   title: row.title ?? DSHSessionFormat.shortId(id),
                                   about: sessionAbout(models: row.models, at: row.lastAt),
                                   tokens: GlanceFormat.short(row.tokens),
                                   active: id == liveId,
                                   brand: brandFor(models: row.models),
                                   mixed: row.models.count > 1)
            }
            return Array(rows.prefix(6))
        }
        var rows: [SessionLine] = []
        if case .live(let usage) = model.snapshot.sessionStatus {
            let liveModels = usage.models.isEmpty ? [usage.model] : usage.models
            let about = sessionAbout(models: liveModels, at: usage.lastAt)
            rows.append(SessionLine(id: usage.sessionId,
                                    title: usage.title.flatMap { $0.isEmpty ? nil : $0 }
                                        ?? DSHSessionFormat.shortId(usage.sessionId),
                                    about: about,
                                    tokens: GlanceFormat.short(usage.totalTokens),
                                    active: true,
                                    brand: usage.providerId.hasPrefix("deepseek") ? .deepSeek
                                        : (usage.providerId.hasPrefix("openai") ? .codex : .ai),
                                    mixed: liveModels.count > 1))
        }
        for choice in model.snapshot.sessionChoices where !rows.contains(where: { $0.id == choice.sessionId }) {
            let about = sessionAbout(models: choice.models, at: choice.lastAt)
            rows.append(SessionLine(id: choice.sessionId,
                                    title: choice.displayName,
                                    about: about,
                                    tokens: "",
                                    active: false,
                                    brand: .ai,
                                    mixed: choice.models.count > 1))
        }
        return Array(rows.prefix(6))
    }

    /// 会话用的品牌色：DeepSeek 蓝、Codex 青，其它用默认 ink。
    private func brandFor(models: [String]) -> PanelBrand {
        if models.contains(where: { $0.hasPrefix("deepseek") }) { return .deepSeek }
        if models.contains(where: { $0.hasPrefix("openai") }) { return .codex }
        return .ai
    }

    /// "模型 · 3 分钟前"：混用两个以上模型时只写数量，和时间一起放进一行，不会被省略号截断。
    private func sessionAbout(models: [String], at: Date?) -> String {
        let names = models.map { name -> String in
            if let range = name.range(of: "/", options: .backwards) { return String(name[range.upperBound...]) }
            return name
        }
        let model = names.count > 1 ? L("\(names.count) models", "混用 \(names.count) 个模型")
                                   : (names.first ?? "")
        return [model, GlanceFormat.relative(at)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var sessionGrid: some View {
        // 两列时每列 3 条共 6 条；单列时同样封顶 6 条，别把面板撑得比屏幕还高。
        let rows = Array(sessionRows.prefix(6))
        let half = (rows.count + 1) / 2
        let left = Array(rows.prefix(half))
        let right = Array(rows.dropFirst(half))
        if PanelStyle.singleColumnSessions {
            return AnyView(VStack(alignment: .leading, spacing: PanelStyle.sessionGap) {
                ForEach(rows, id: \.id) { sessionLine($0) }
            })
        }
        return AnyView(HStack(alignment: .top, spacing: PanelStyle.columnGap) {
            VStack(alignment: .leading, spacing: PanelStyle.sessionGap) {
                ForEach(left, id: \.id) { sessionLine($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: PanelStyle.sessionGap) {
                ForEach(right, id: \.id) { sessionLine($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        })
    }

    /// 会话行图标：每一行都要有可辨识图形，不再出现纯色空方块。
    /// deepSeek/codex 用品牌 logo png；ai 用单色 sparkles；混用用中性多模型符号。
    /// 符号放在淡色圆角底上，尺寸/圆角与鲸鱼 logo 的 13pt·r4 一致。
    private func sessionIcon(_ line: SessionLine) -> some View {
        Group {
            if line.mixed {
                sessionTile(symbol: "square.grid.2x2.fill", tint: skin.text2, active: line.active)
            } else if line.brand == .ai {
                sessionTile(symbol: "sparkles", tint: skin.ink(.ai), active: line.active)
            } else if let image = model.icon(line.brand == .deepSeek ? "deepseek-logo" : "codex-logo") {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 13, height: 13)
                    .opacity(line.active ? 1 : 0.4)
            } else {
                // logo 资源缺失时的兜底：仍是带符号的淡色底，不是空方块。
                sessionTile(symbol: line.brand == .deepSeek ? "fish.fill" : "terminal.fill",
                            tint: skin.ink(line.brand), active: line.active)
            }
        }
    }

    private func sessionTile(symbol: String, tint: Color, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(0.14))
            .frame(width: 13, height: 13)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(tint)
            )
            .opacity(active ? 1 : 0.4)
    }

    private func sessionLine(_ line: SessionLine) -> some View {
        Button(action: { model.onSelectSession(line.id) }) {
            HStack(alignment: .top, spacing: 0) {
                sessionIcon(line)
                    .padding(.top, 1)
                Spacer().frame(width: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                        .font(.system(size: PanelStyle.body, weight: .medium))
                        .foregroundColor(skin.text)
                        .lineLimit(1)
                    Text(line.about)
                        .font(.system(size: PanelStyle.small, weight: .medium))
                        .foregroundColor(skin.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(line.tokens)
                    .font(.system(size: PanelStyle.small, weight: .medium))
                    .foregroundColor(skin.text2)
                    .lineLimit(1)
            }
            .frame(height: PanelStyle.session, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Open this conversation in DSH", "在 DSH 中打开这个对话"))
    }

    // MARK: Windows（两列：标签 + % / 条 +「时间已过」竖刻 / 重置文案）

    private func windows(_ rows: [UsageQuotaRow], brand: PanelBrand) -> some View {
        HStack(alignment: .top, spacing: PanelStyle.columnGap) {
            ForEach(Array(rows.prefix(2).enumerated()), id: \.offset) { _, row in
                window(row, brand: brand)
            }
            if rows.count == 1 {
                Spacer(minLength: 0).frame(maxWidth: .infinity)
            }
        }
    }

    private func window(_ row: UsageQuotaRow, brand: PanelBrand) -> some View {
        // 与 Touch Bar 同口径：显示「还剩多少」，条也画剩余份额。
        let remaining = row.remainingPercent.map { Double(min(100, max(0, $0))) / 100 }
        let percentText = remaining.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        // PanelStyle.hot 是「已用」阈值（0.9）；换算到剩余口径：remaining <= 1 - hot 才警示。
        let hot = (remaining ?? 1) <= 1 - PanelStyle.hot
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(GlanceFormat.windowName(row.label))
                    .font(.system(size: PanelStyle.small, weight: .medium))
                    .foregroundColor(skin.text2)
                Spacer(minLength: 6)
                Text(percentText)
                    .font(.system(size: PanelStyle.small, weight: .medium))
                    .foregroundColor(hot ? skin.signal : skin.text)
            }
            .frame(height: PanelStyle.line)
            UsageWindowMeter(progress: remaining, tint: skin.ink(brand))
                .frame(height: PanelStyle.meter + 4)
                .padding(.vertical, (PanelStyle.barBand - PanelStyle.meter - 4) / 2)
            Text(row.resetAt.map { GlanceFormat.resetClock($0, label: row.label) } ?? "")
                .font(.system(size: PanelStyle.small, weight: .medium))
                .foregroundColor(skin.text3)
                .lineLimit(1)
                // 480 宽时两列只有 212pt，「11-27 20:55 重置」仍可能偏宽，宁可缩字。
                .minimumScaleFactor(0.78)
                .frame(height: PanelStyle.line, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Models（份额条 + 行）

    private func models(_ rows: [UsageModelRow], brand: PanelBrand) -> some View {
        let top = Array(rows.prefix(3))
        let total = max(top.reduce(Int64(0)) { $0 + max(0, $1.tokens) }, 1)
        return VStack(alignment: .leading, spacing: 0) {
            shares(top, total: total, brand: brand)
                .frame(height: PanelStyle.modelsBar)
            Spacer().frame(height: PanelStyle.modelsBarGap)
            ForEach(Array(top.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(skin.ink(brand).opacity(1 - Double(index) * 0.25))
                        .frame(width: 8, height: 8)
                    Spacer().frame(width: 14)
                    Text(shortModelName(row.name))
                        .font(.system(size: PanelStyle.small, weight: .medium))
                        .foregroundColor(skin.text2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(GlanceFormat.short(row.tokens))
                        .font(.system(size: PanelStyle.small, weight: .medium))
                        .foregroundColor(skin.text)
                        .lineLimit(1)
                }
                .frame(height: PanelStyle.line)
                .padding(.bottom, index == top.count - 1 ? 0 : PanelStyle.rowGap)
            }
        }
    }

    private func shares(_ rows: [UsageModelRow], total: Int64, brand: PanelBrand) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(skin.track)
                HStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        Rectangle()
                            .fill(skin.ink(brand).opacity(1 - Double(index) * 0.25))
                            .frame(width: max(0, CGFloat(max(0, row.tokens)) / CGFloat(total)) * proxy.size.width)
                    }
                }
                .clipShape(Capsule())
            }
        }
    }

    private func shortModelName(_ name: String) -> String {
        if let range = name.range(of: "/") { return String(name[range.upperBound...]) }
        return name
    }

    // MARK: Pairs（两列：标签 + 右值）

    private func pairs(_ items: [(String, String)]) -> some View {
        HStack(alignment: .top, spacing: PanelStyle.columnGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 0) {
                    Text(item.0)
                        .font(.system(size: PanelStyle.small, weight: .medium))
                        .foregroundColor(skin.text2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.1)
                        .font(.system(size: PanelStyle.small, weight: .medium))
                        .foregroundColor(skin.text)
                        .lineLimit(1)
                }
                .frame(height: PanelStyle.line)
            }
        }
    }
}

// MARK: - 今日面积图（Glance 的 today 块：wash 填充 + 1.6 描边 + 末端 2.6 圆点）

private extension EnvironmentValues {
    var heatHover: UsagePanelView.HeatHover {
        get { self[UsagePanelView.HeatHoverKey.self] }
        set { self[UsagePanelView.HeatHoverKey.self] = newValue }
    }
}

struct UsageAreaChart: View {
    var values: [Int64] = []
    var tint: Color = .accentColor

    private var series: [Int64] { Array(values.suffix(7)) }

    var body: some View {
        GeometryReader { proxy in
            if series.count >= 2 {
                chart(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func chart(width: CGFloat, height: CGFloat) -> some View {
        let peak = max(series.max() ?? 0, 1)
        let top: CGFloat = 6
        let foot = height - 2
        let points: [CGPoint] = series.enumerated().map { index, value in
            let ratio = value <= 0 ? 0 : CGFloat(Double(value).squareRoot() / Double(peak).squareRoot())
            let x = width * CGFloat(index) / CGFloat(series.count - 1)
            return CGPoint(x: x, y: foot - max(0.5, (foot - top) * ratio))
        }
        var area = Path()
        area.move(to: CGPoint(x: 0, y: height))
        for point in points { area.addLine(to: point) }
        area.addLine(to: CGPoint(x: width, y: height))
        area.closeSubpath()

        var line = Path()
        line.move(to: points[0])
        for point in points.dropFirst() { line.addLine(to: point) }

        return ZStack(alignment: .topLeading) {
            area.fill(LinearGradient(gradient: Gradient(colors: [tint.opacity(0.34), tint.opacity(0.0)]),
                                     startPoint: .top, endPoint: .bottom))
            line.stroke(tint, lineWidth: 1.6)
            if let last = points.last {
                Circle()
                    .fill(tint)
                    .frame(width: 5.2, height: 5.2)
                    .position(x: last.x, y: last.y)
            }
        }
    }
}

// MARK: - 额度条（Glance 的 meter：6pt 圆角轨 + 填充 + 「时间已过」竖刻度）

struct UsageWindowMeter: View {
    var progress: Double?
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: max(0, proxy.size.width), height: PanelStyle.meter)
                if let progress {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, min(1, progress)) * proxy.size.width, height: PanelStyle.meter)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// 面板底：真正的 behind-window 磨砂，桌面会自然透上来。
struct VisualEffectBackground: NSViewRepresentable {
    /// `.sidebar` 比 `.underWindowBackground` 更透：后者在浅色外观下几乎是一层实白，
    /// 看上去像白塑料板，这正是「不像雾透玻璃」的主因。sidebar 保留更多背景色，
    /// 再用 emphasised 提一点饱和度，背景的颜色才透得上来。
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
    }
}

/// 玻璃的「厚度」：顶部一道高光、底部一道内阴影。
/// 只有模糊+圆角是看不出材质的，真实玻璃靠这两条边读出表面。
struct GlassSheen: View {
    var dark: Bool
    var strong: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color.white.opacity(dark ? (strong ? 0.16 : 0.10) : (strong ? 0.42 : 0.22)),
                             Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: min(strong ? 210 : 170, geo.size.height * (strong ? 0.62 : 0.55)))

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(dark ? 0.22 : 0.75))
                        .frame(height: 1.5)
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill((dark ? Color.white : Color.black).opacity(dark ? 0.06 : (strong ? 0.10 : 0.05)))
                        .frame(height: 1)
                }
                .padding(.horizontal, PanelStyle.radius * 0.6)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Panel controller

/// 面板窗口：无边框、不抢焦点、整块玻璃自己画圆角和描边，
/// 这样才不会带上 NSPopover 的箭头和它那套 11pt 圆角。
final class UsagePanelController: NSObject {
    private final class GlassPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let model: UsagePanelModel
    private let hosting: NSHostingController<UsagePanelView>
    private let panel: GlassPanel
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pinned = false
    private var anchorRect: NSRect = .zero
    private weak var anchorButton: NSStatusBarButton?

    init(model: UsagePanelModel) {
        self.model = model
        self.hosting = NSHostingController(rootView: UsagePanelView(model: model))
        self.panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: PanelStyle.width, height: 400),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        // 非激活面板默认不收 mouse-moved，SwiftUI 的 .help 悬停提示（热力图每日明细）
        // 依赖它才能触发；只开这一个开关，不改焦点/点击行为。
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = PanelStyle.radius
            // 调试用：QS_GLASS=regular|clear、QS_TINT=0…1 可以在不重编译的情况下对比透明档位。
            let env = ProcessInfo.processInfo.environment
            glass.style = (env["QS_GLASS"] == "regular") ? .regular : .clear
            let tint = Double(env["QS_TINT"] ?? "0.12") ?? 0.12
            glass.tintColor = NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return dark ? NSColor(white: 0.05, alpha: tint) : NSColor(white: 1.0, alpha: tint)
            }
            glass.frame = NSRect(x: 0, y: 0, width: PanelStyle.width, height: 460)
            hosting.view.frame = glass.bounds
            hosting.view.autoresizingMask = [.width, .height]
            glass.contentView = hosting.view
            panel.contentView = glass
        } else {
            panel.contentView = hosting.view
        }
        hosting.view.wantsLayer = true
        hosting.view.layer?.masksToBounds = true
        if let appearance = NSApp.appearance {
            hosting.view.appearance = appearance
            panel.appearance = appearance
        }
    }

    var isShown: Bool { panel.isVisible }

    /// 截图验收时用：不装外部点击/失去焦点就收起的监听。
    func pinForCapture() {
        pinned = true
        removeMonitors()
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel.isVisible { close() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.view.fittingSize
        if size.width < 200 || size.height < 200 {
            size = NSSize(width: PanelStyle.width, height: 460)
        }
        panel.setContentSize(size)
        anchorButton = button
        if let window = button.window {
            anchorRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        if let origin = anchorOrigin(for: size, button: button) {
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        installMonitors()
        // SwiftUI 的第一遍布局常常比 fittingSize 晚一拍，开窗后再校一次尺寸，
        // 否则最后一行（例如「会话」标题）会被窗口下沿切掉。
        DispatchQueue.main.async { self.resizeToFit() }
    }

    private func resizeToFit() {
        guard panel.isVisible else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize
        guard fitted.height > 80, abs(fitted.height - panel.frame.height) > 0.5 else { return }
        let origin = panel.frame.origin
        panel.setContentSize(NSSize(width: PanelStyle.width, height: fitted.height))
        panel.setFrameOrigin(origin)
    }

    func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
    }

    /// 贴在状态栏图标正下方，右对齐图标右边缘，并夹在屏幕可视区内。
    private func anchorOrigin(for size: NSSize, button: NSStatusBarButton) -> NSPoint? {
        guard let window = button.window else { return nil }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return nil }
        var x = buttonRect.maxX - size.width
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        var y = buttonRect.minY - size.height - 6
        if y < visible.minY + 8 { y = visible.minY + 8 }
        return NSPoint(x: x, y: y)
    }

    private func installMonitors() {
        guard !pinned else { return }
        removeMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) { self.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.close(); return nil }
            let point = NSEvent.mouseLocation
            // 点状态栏图标本身就是「收起」：吃掉这次点击，免得按钮再把面板打开一次。
            if self.anchorRect.contains(point) { self.close(); return nil }
            if !self.panel.frame.contains(point) { self.close() }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close()
        }
    }

    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        outsideMonitor = nil
        localMonitor = nil
        resignObserver = nil
    }

    // Called by the app as numbers arrive; never rebuilds the panel, just republishes.
    func update(_ snapshot: UsageSnapshot) {
        model.snapshot = snapshot
        guard panel.isVisible else { return }
        DispatchQueue.main.async { self.resizeToFit() }
    }
}
