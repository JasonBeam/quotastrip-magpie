import Foundation

/// Magpie 本机管理层的只读额度视图（GET /v1/magpie/quotas）。
/// 只走 loopback，无需任何 key；不读 gateway.json / logins.json 等凭据文件。
struct MagpieWindow: Equatable {
    let name: String
    let used: Double?
    let remaining: Double?
    let resetsAt: Date?
    /// 上游给了 display（如 "Unknown"）时以它为准，不再按数字画。
    let display: String?
    let lane: String?
}

struct MagpieQuota: Equatable {
    let provider: String
    let name: String
    let kind: String
    let plan: String
    let user: String
    let windows: [MagpieWindow]
    let balance: String?
    let readAt: Date?
    let resetsCount: Int
    /// 上游 error 原文保留，面板/菜单直接展示（如 qwen 需登录、deepseek TLS）。
    let error: String?
    let lastServedAt: Date?

    /// 有真实窗口且无 error 才算「可用」；qwen 未登录时 windows=[] + error。
    var isUsable: Bool { error == nil && !windows.isEmpty }

    func window(named name: String) -> MagpieWindow? {
        windows.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// 账号清单（GET /v1/magpie/accounts）。掩码 label 不持久化、不入模型。
struct MagpieAccount: Equatable {
    let provider: String
    let id: String
    let kind: String
    let on: Bool
    let plan: String
    let user: String
}

enum MagpieDecodeError: Error { case oversized, invalidJSON, invalidEntry }

enum MagpieDecode {
    /// ISO8601 带小数秒/不带、Z 或 +08:00 都接受；缺时区按非法。
    static func parseDate(_ raw: Any?) -> Date? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, !(raw is Bool) else { return nil }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }

    private static func text(_ raw: Any?) -> String { raw as? String ?? "" }

    /// 宽松解码：字段缺失给默认值；error 原样保留。顶层必须是 {data:[…]}。
    static func decodeQuotas(_ data: Data) throws -> [MagpieQuota] {
        guard data.count <= 512 * 1024 else { throw MagpieDecodeError.oversized }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let array = root["data"] as? [[String: Any]] else {
            throw MagpieDecodeError.invalidJSON
        }
        return try array.map { raw in
            let provider = text(raw["provider"])
            guard !provider.isEmpty else { throw MagpieDecodeError.invalidEntry }
            let windows: [MagpieWindow] = (raw["windows"] as? [[String: Any]] ?? []).compactMap { item in
                let name = text(item["name"])
                guard !name.isEmpty else { return nil }
                return MagpieWindow(name: name,
                                    used: number(item["used"]),
                                    remaining: number(item["remaining"]),
                                    resetsAt: parseDate(item["resetsAt"]),
                                    display: item["display"] as? String,
                                    lane: item["lane"] as? String)
            }
            let resets = raw["resets"] as? [String: Any]
            let count = (resets?["count"] as? NSNumber).flatMap { $0.intValue >= 0 ? $0.intValue : nil } ?? 0
            return MagpieQuota(provider: provider,
                               name: text(raw["name"]),
                               kind: text(raw["kind"]),
                               plan: text(raw["plan"]),
                               user: text(raw["user"]),
                               windows: windows,
                               balance: raw["balance"] as? String,
                               readAt: parseDate(raw["readAt"]),
                               resetsCount: count,
                               error: (raw["error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               lastServedAt: parseDate(raw["lastServedAt"]))
        }
    }

    static func decodeAccounts(_ data: Data) throws -> [MagpieAccount] {
        guard data.count <= 256 * 1024 else { throw MagpieDecodeError.oversized }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let array = root["data"] as? [[String: Any]] else {
            throw MagpieDecodeError.invalidJSON
        }
        return array.compactMap { raw in
            let provider = text(raw["provider"])
            guard !provider.isEmpty else { return nil }
            return MagpieAccount(provider: provider,
                                 id: text(raw["id"]),
                                 kind: text(raw["kind"]),
                                 on: (raw["on"] as? NSNumber)?.boolValue ?? false,
                                 plan: text(raw["plan"]),
                                 user: text(raw["user"]))
        }
    }

    /// GET / 的 manifest：name=="magpie" 才认这个端口。
    static func isManifest(_ data: Data) -> Bool {
        guard data.count <= 64 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return root["name"] as? String == "magpie"
    }

    /// GET /v1/magpie/usage/requests 的单行（只取需要的字段）。
    struct RequestRow {
        let at: Date
        let agent: String
        let session: String
        let model: String
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let ms: Int64
        let status: Int
        let source: String?
        /// 首 token 时延（ms）；DSH 口径解码时长 = ms - ttft。
        let ttftMs: Int64?
        let reasoning: Int64

        /// 日志导入行（source=="log"，ms==0）没有计时，不能算 tok/s。
        var hasTiming: Bool { ms > 0 && source != "log" }
        var totalTokens: Int64 { input + output + cacheRead }
        /// DSH 用量口径的缓存命中率：cacheRead / (input + cacheRead)。
        var cacheHitPercent: Double? {
            let denominator = input + cacheRead
            guard denominator > 0 else { return nil }
            return Double(cacheRead) / Double(denominator) * 100
        }
        /// DSH decodeSpeed 口径：输出 token ÷（完成时刻 − 首 token 时刻）。
        /// Magpie 行里 ms 是整请求时长、ttft_ms 是首 token 时延，差值即解码时长。
        var tokensPerSecond: Double? {
            guard hasTiming, output > 0, let ttft = ttftMs else { return nil }
            let decodeMs = ms - ttft
            guard decodeMs > 0 else { return nil }
            return Double(output) / (Double(decodeMs) / 1000)
        }
    }

    /// 宽松解码逐请求行；坏行跳过，不影响其它行。
    static func decodeRequests(_ data: Data) throws -> [RequestRow] {
        guard data.count <= 4 * 1024 * 1024 else { throw MagpieDecodeError.oversized }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let array = root["rows"] as? [[String: Any]] else {
            throw MagpieDecodeError.invalidJSON
        }
        return array.compactMap { raw in
            guard let at = parseDate(raw["t"]) else { return nil }
            func int64(_ key: String) -> Int64 {
                (raw[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } ?? 0
            }
            return RequestRow(at: at,
                              agent: text(raw["agent"]),
                              session: text(raw["session"]),
                              model: text(raw["served"]).isEmpty ? text(raw["model"]) : text(raw["served"]),
                              input: int64("in"),
                              output: int64("out"),
                              cacheRead: int64("cache_read"),
                              ms: int64("ms"),
                              status: (raw["status"] as? NSNumber)?.intValue ?? 0,
                              source: raw["source"] as? String,
                              ttftMs: (raw["ttft_ms"] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil },
                              reasoning: int64("reasoning"))
        }
    }

    /// 当日合计（series 里 label 匹配今天），input+output+cacheRead。
    /// 用 /v1/magpie/usage/requests 的 series：它是网关实时行 + DSH 导入日志的合并口径，
    /// 与 Magpie App「今日」大数字一致；/v1/magpie/usage 的 series 只含网关行（会少 DSH 部分）。
    /// 两边同一 response_id 已由 Magpie 去重，这里不再叠加任何本地读数，避免重复计数。
    static func decodeUsageTodayTotal(_ data: Data, now: Date = Date()) -> Int64? {
        guard data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let series = root["series"] as? [[String: Any]] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        let label = formatter.string(from: now)
        for day in series where (day["label"] as? String) == label {
            func int64(_ key: String) -> Int64 {
                (day[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } ?? 0
            }
            return int64("input") + int64("output") + int64("cache_read")
        }
        return nil
    }

    /// 本周合计（周一到今天），同样取合并 series；time 带时区的 ISO 日期。
    /// 无本周一以来的任何记录时返回 nil（不误报 0）。
    static func decodeUsageWeekTotal(_ data: Data, now: Date = Date()) -> Int64? {
        guard data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let series = root["series"] as? [[String: Any]] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // 周起点固定周一：系统日历 firstWeekday 可能是周日（会把上周日算进本周）。
        calendar.firstWeekday = 2
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return nil }
        let dayStart = calendar.startOfDay(for: now)
        var total: Int64 = 0
        var matched = false
        for day in series {
            guard let text = day["time"] as? String,
                  let date = parseDate(text) else { continue }
            let stamp = calendar.startOfDay(for: date)
            guard stamp >= monday, stamp <= dayStart else { continue }
            func int64(_ key: String) -> Int64 {
                (day[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } ?? 0
            }
            total += int64("input") + int64("output") + int64("cache_read")
            matched = true
        }
        return matched ? total : nil
    }

    /// 近 7 天（旧→新）的合并口径 token 序列，AI 用量卡折线图用。
    /// 返回 (本地日期 "yyyy-MM-dd", input+output+cache_read)；缺记录的那天补 0。
    /// series 里没有近 7 天的任何一天时返回 nil（整体回退 DSH，不画半截假图）。
    static func decodeUsageRecentDays(_ data: Data, now: Date = Date())
        -> (labels: [String], tokens: [Int64])? {
        guard data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let series = root["series"] as? [[String: Any]] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: Int64] = [:]
        for day in series {
            guard let date = parseDate(day["time"] as? String) else { continue }
            func int64(_ key: String) -> Int64 {
                (day[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } ?? 0
            }
            byDay[calendar.startOfDay(for: date)] = int64("input") + int64("output") + int64("cache_read")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var labels: [String] = []
        var tokens: [Int64] = []
        var matched = false
        for offset in stride(from: -6, through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            labels.append(formatter.string(from: date))
            if let value = byDay[date] {
                tokens.append(value)
                matched = true
            } else {
                tokens.append(0)
            }
        }
        return matched ? (labels, tokens) : nil
    }

    /// Magpie App「用量热力图」的整段历史（约一年，一天一格）。
    /// 公开 /v1 接口只回 30 天；App 自己读的是本地缓存 ~/.cache/magpie/heat-v1.json：
    /// days[] 是 cut 之前已归档的每日合计，cut 当天起用 30d 合并 series 补齐。
    /// 这是只读 Magpie 自己的非敏感聚合缓存（无对话内容/凭据），不写不删。
    struct HeatDay: Equatable {
        var label: String   // "yyyy-MM-dd"
        var tokens: Int64
        var calls: Int
        /// 估算成本（US$）；tooltip 换算 ¥ 用，缺省时不显示金额。
        var cost: Double?
    }

    static func decodeHeatCache(_ data: Data) -> (cut: Date, days: [String: HeatDay])? {
        guard data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cut = parseDate(root["cut"] as? String),
              let array = root["days"] as? [[String: Any]] else { return nil }
        var days: [String: HeatDay] = [:]
        for item in array {
            guard let date = item["date"] as? String, date.count == 10,
                  let tokens = (item["tokens"] as? NSNumber)?.int64Value, tokens >= 0 else { continue }
            let calls = (item["calls"] as? NSNumber).flatMap { $0.intValue >= 0 ? $0.intValue : nil } ?? 0
            days[date] = HeatDay(label: date, tokens: tokens, calls: calls, cost: number(item["cost"]))
        }
        guard !days.isEmpty else { return nil }
        return (cut, days)
    }

    /// 合并整段热力：缓存里 cut 之前的天 + 30d series 里 cut 当天起的天。
    /// 输出从「最早有数据那周的周一」到今天的连续日序列（无数据的天补 0），
    /// 与 App 一样只在窗口内画格；两边都没有数据返回 nil。
    static func mergeHeatmap(cached: (cut: Date, days: [String: HeatDay])?,
                             series: [HeatDay]?,
                             now: Date = Date()) -> [HeatDay]? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: HeatDay] = [:]
        var earliest: Date?
        if let cached {
            let cutDay = calendar.startOfDay(for: cached.cut)
            for (label, item) in cached.days {
                guard let date = formatter.date(from: label) else { continue }
                let day = calendar.startOfDay(for: date)
                guard day < cutDay else { continue }   // cut 起以实时 series 为准
                byDay[day] = item
                if earliest == nil || day < earliest! { earliest = day }
            }
        }
        if let series {
            for item in series {
                guard let date = formatter.date(from: item.label) else { continue }
                let day = calendar.startOfDay(for: date)
                byDay[day] = item
                if earliest == nil || day < earliest! { earliest = day }
            }
        }
        guard let first = earliest,
              let start = calendar.dateInterval(of: .weekOfYear, for: first)?.start,
              start <= today else { return nil }
        var out: [HeatDay] = []
        var day = start
        while day <= today {
            let label = formatter.string(from: day)
            out.append(byDay[day] ?? HeatDay(label: label, tokens: 0, calls: 0, cost: nil))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// 30d 合并 series → HeatDay 序列（补 calls/cost，tooltip 用）。
    static func decodeUsageHeatDays(_ data: Data) -> [HeatDay]? {
        guard data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["bucket"] as? String) == "day",
              let series = root["series"] as? [[String: Any]], !series.isEmpty else { return nil }
        var out: [HeatDay] = []
        for item in series {
            guard let date = parseDate(item["time"] as? String) else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            func int64(_ key: String) -> Int64 {
                (item[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } ?? 0
            }
            let calls = (item["calls"] as? NSNumber).flatMap { $0.intValue >= 0 ? $0.intValue : nil } ?? 0
            out.append(HeatDay(label: formatter.string(from: date),
                               tokens: int64("input") + int64("output") + int64("cache_read"),
                               calls: calls, cost: number(item["cost"])))
        }
        return out.isEmpty ? nil : out
    }

    /// App 的 USD→CNY 汇率缓存（~/.cache/magpie/fxrate.json，只读）。
    /// 读不到返回 nil：tooltip 退回显示 US$，不猜汇率。
    static func decodeFxRate(_ data: Data) -> Double? {
        guard data.count <= 64 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rate = number(root["rate"]), rate > 0, rate < 100 else { return nil }
        return rate
    }

    /// 当 heat-v1.json 被清空时，从 usage.jsonl 重建（只读，不写不删）。
    /// usage.jsonl 每行一个请求，按天聚合 tokens/calls/cost。
    static func rebuildHeatCache(from data: Data, cut: Date?) -> (cut: Date, days: [String: HeatDay])? {
        guard data.count <= 16 * 1024 * 1024 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var byDay: [String: (tokens: Int64, calls: Int, cost: Double)] = [:]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let t = row["t"] as? String, t.count >= 10 else { continue }
            let dateStr = String(t.prefix(10))
            guard let _ = formatter.date(from: dateStr) else { continue }
            // 跳过 probe/model_list 等内部流量
            if let source = row["source"] as? String, source == "probe" { continue }
            if let kind = row["kind"] as? String, kind == "model_list" { continue }
            func int64(_ key: String) -> Int64 {
                (row[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } ?? 0
            }
            let tokens = int64("in") + int64("out") + int64("cache_read")
            guard tokens > 0 else { continue }
            let existing = byDay[dateStr] ?? (0, 0, 0)
            byDay[dateStr] = (existing.tokens + tokens, existing.calls + 1, existing.cost)
        }
        guard !byDay.isEmpty else { return nil }
        let cutDay = cut ?? Date()
        let days: [String: HeatDay] = byDay.map { (label, v) in
            (label, HeatDay(label: label, tokens: v.tokens, calls: v.calls, cost: nil))
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }
        return (cutDay, days)
    }

    /// 今日活跃会话数：GET /v1/magpie/usage?period=today 的 sessions 去重计数。
    /// 该端点只含网关看到的行（比合并口径少 DSH 日志导入），作为「今日共 N 个」
    /// 的 Magpie 主源可接受；period 不是 today 的响应拒收，避免把 30d 会话当今日。
    static func decodeUsageTodaySessions(_ data: Data) -> Int? {
        guard data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["period"] as? String) == "today",
              let sessions = root["sessions"] as? [[String: Any]] else { return nil }
        var ids = Set<String>()
        for session in sessions {
            guard let id = session["id"] as? String, !id.isEmpty else { continue }
            ids.insert(id)
        }
        return ids.count
    }

    /// 千问供应商消耗卡的数据（period=today&provider=qwen 的响应）。
    struct QwenUsage: Equatable {
        var calls: Int
        var tokens: Int64
        /// 估算成本（US$，Magpie Usage 页价目表口径），面板原样两位小数。
        var cost: Double?
        /// 按模型拆分（旧→新按 token 降序），id 已去掉 "qwen/" 前缀。
        var models: [QwenModelUsage] = []
    }

    struct QwenModelUsage: Equatable {
        var name: String
        var calls: Int
        var tokens: Int64
        var cost: Double?
    }

    /// 只认 period=="today" 的响应；by.modelAt 里只取 "qwen/" 前缀的行，
    /// session-unknown/…（DSH 日志导入行）不属于千问供应商，严禁混入。
    static func decodeQwenUsageToday(_ data: Data) -> QwenUsage? {
        guard data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["period"] as? String) == "today" else { return nil }
        func int64(_ raw: Any?) -> Int64 {
            (raw as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } ?? 0
        }
        let calls = int64(root["calls"])
        let tokens = int64(root["input"]) + int64(root["output"]) + int64(root["cache_read"])
        guard calls > 0 || tokens > 0 else { return nil }
        var usage = QwenUsage(calls: Int(calls), tokens: tokens, cost: number(root["cost"]))
        let by = root["by"] as? [String: Any]
        let modelAt = by?["modelAt"] as? [[String: Any]] ?? []
        usage.models = modelAt.compactMap { item in
            guard let id = item["id"] as? String, id.hasPrefix("qwen/") else { return nil }
            let name = String(id.dropFirst("qwen/".count))
            guard !name.isEmpty else { return nil }
            return QwenModelUsage(name: name,
                                  calls: Int(int64(item["calls"])),
                                  tokens: int64(item["input"]) + int64(item["output"]) + int64(item["cache_read"]),
                                  cost: number(item["cost"]))
        }.sorted { $0.tokens > $1.tokens }
        return usage
    }
}

/// Magpie 只读客户端。端口发现：UserDefaults magpie.origin → GET / manifest 校验。
/// 失败即冷却（60s），保留 lastGood（UserDefaults 持久化）；不扫凭据文件。
/// 所有回调在主线程；并发合并；模式与 JimmyCloudPlanProvider 一致。
final class MagpieProvider {
    struct Snapshot: Equatable {
        var quotas: [MagpieQuota] = []
        var accounts: [MagpieAccount] = []
        var readAt: Date?
        var error: String?
        var stale = false

        func quota(_ provider: String) -> MagpieQuota? {
            quotas.first { $0.provider == provider }
        }
        var isRunning: Bool { error == nil }
    }

    typealias Completion = (Snapshot) -> Void

    /// 测试缝：绕过 UserDefaults 与 manifest 校验，直接指定 origin 列表。
    static var overrideOrigin: URL?
    private static let originKey = "magpie.origin"
    private static let storeKey = "app.quotastrip.magpie.last.v1"
    private static let storeDateKey = "app.quotastrip.magpie.lastAt.v1"
    private static let defaultOrigin = URL(string: "http://127.0.0.1:3425")!

    private var lastGood: Snapshot?
    private var cachedAt: Date?
    private var cooldownUntil: Date?
    private var inFlight = false
    private var completions: [Completion] = []
    private var generation: UInt64 = 0
    private let fetchQueue = DispatchQueue(label: "app.quotastrip.magpie", qos: .utility)

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let quotas = try? MagpieDecode.decodeQuotas(data) {
            var snapshot = Snapshot()
            snapshot.quotas = quotas
            snapshot.readAt = quotas.compactMap { $0.readAt }.max()
            snapshot.stale = true
            lastGood = snapshot
            cachedAt = UserDefaults.standard.object(forKey: Self.storeDateKey) as? Date
        }
    }

    static func configuredOrigin() -> URL {
        if let override = overrideOrigin { return override }
        if let raw = UserDefaults.standard.string(forKey: originKey),
           let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1" {
            return url
        }
        return defaultOrigin
    }

    func fetch(force: Bool = false, completion: @escaping Completion) {
        precondition(Thread.isMainThread)
        if inFlight { completions.append(completion); return }
        let now = Date()
        if let until = cooldownUntil, until > now {
            completion(currentSnapshot(stale: true))
            return
        }
        if !force, let at = cachedAt, lastGood != nil, now.timeIntervalSince(at) < 60 {
            completion(currentSnapshot(stale: false))
            return
        }
        completions.append(completion)
        inFlight = true
        let version = generation
        let origin = Self.configuredOrigin()
        fetchQueue.async { [weak self] in
            guard let self else { return }
            let outcome = Self.run(origin: origin)
            DispatchQueue.main.async {
                guard version == self.generation else { return }
                self.inFlight = false
                let callbacks = self.completions
                self.completions.removeAll()
                switch outcome {
                case .ok(let quotasData, let accountsData):
                    do {
                        let quotas = try MagpieDecode.decodeQuotas(quotasData)
                        var snapshot = Snapshot()
                        snapshot.quotas = quotas
                        // accounts 偶发失败不致命：保留上次好值，避免面板闪「0 个账号」。
                        // 空 Data（请求失败）不覆盖上次好值。
                        if let decoded = try? MagpieDecode.decodeAccounts(accountsData), !decoded.isEmpty {
                            snapshot.accounts = decoded
                        } else {
                            snapshot.accounts = self.lastGood?.accounts ?? []
                        }
                        snapshot.readAt = quotas.compactMap { $0.readAt }.max() ?? Date()
                        self.lastGood = snapshot
                        self.cachedAt = Date()
                        self.cooldownUntil = nil
                        UserDefaults.standard.set(quotasData, forKey: Self.storeKey)
                        UserDefaults.standard.set(self.cachedAt, forKey: Self.storeDateKey)
                        callbacks.forEach { $0(snapshot) }
                    } catch {
                        self.fail(L("Magpie returned invalid quota data.", "Magpie 额度数据无效。"), callbacks: callbacks)
                    }
                case .failed(let message):
                    self.fail(message, callbacks: callbacks)
                }
            }
        }
    }

    private func currentSnapshot(stale: Bool) -> Snapshot {
        var snapshot = lastGood ?? Snapshot()
        if lastGood == nil {
            snapshot.error = L("Magpie is not running.", "Magpie 未运行。")
        }
        snapshot.stale = stale && lastGood != nil
        return snapshot
    }

    private func fail(_ message: String, callbacks: [Completion]) {
        cooldownUntil = Date().addingTimeInterval(60)
        var snapshot = lastGood ?? Snapshot()
        snapshot.error = message
        snapshot.stale = lastGood != nil
        callbacks.forEach { $0(snapshot) }
    }

    private enum Outcome {
        case ok(Data, Data)
        case failed(String)
    }

    // MARK: 当前对话实时视图（GET /v1/magpie/usage/requests）

    struct Activity: Equatable {
        var model: String?
        var session: String?
        var sessionTokens: Int64?
        var sessionCacheHit: Double?
        var tokensPerSecond: Double?
        var requestAt: Date?
        /// Magpie 自己的当日 token 合计；DSH 用量不可用时的兜底。
        var todayTotal: Int64?
        /// 本周（周一至今）合并口径合计；Codex 卡右上角小字用它。
        var weekTotal: Int64?
        /// 近 7 天合并口径序列（旧→新）；AI 用量卡折线图主源，nil 时回退 DSH。
        var recentDayLabels: [String] = []
        var recentDayTokens: [Int64] = []
        /// 整段按日明细（旧→新，与 Magpie App「用量热力图」同窗口同口径）；面板热力图用。
        var heatDays: [MagpieDecode.HeatDay] = []
        /// App 同款 USD→CNY 汇率（只读缓存）；nil 时 tooltip 显示 US$。
        var fxRate: Double?
        /// 今日活跃会话数（Magpie 网关口径）；「今日共 N 个」主源。
        var todaySessions: Int?
        /// 千问供应商今日消耗（provider=qwen 过滤）；千问卡下方的 Magpie 卡用。
        var qwenToday: MagpieDecode.QwenUsage?
        var error: String?
        var stale = false
    }

    private var activityGood: Activity?
    private var activityAt: Date?
    private var activityCooldown: Date?
    private var activityInFlight = false
    private var activityCompletions: [(Activity) -> Void] = []

    /// 20s tick 内命中 15s 缓存；失败保留上次好值标 stale，冷却 30s。
    func fetchActivity(force: Bool = false, completion: @escaping (Activity) -> Void) {
        precondition(Thread.isMainThread)
        if activityInFlight { activityCompletions.append(completion); return }
        let now = Date()
        if let until = activityCooldown, until > now {
            completion(activitySnapshot(stale: true)); return
        }
        if !force, let at = activityAt, activityGood != nil, now.timeIntervalSince(at) < 15 {
            completion(activitySnapshot(stale: false)); return
        }
        activityCompletions.append(completion)
        activityInFlight = true
        let origin = Self.configuredOrigin()
        fetchQueue.async { [weak self] in
            guard let self else { return }
            let outcome = Self.runActivity(origin: origin)
            DispatchQueue.main.async {
                self.activityInFlight = false
                let callbacks = self.activityCompletions
                self.activityCompletions.removeAll()
                switch outcome {
                case .ok(let activity):
                    self.activityGood = activity
                    self.activityAt = Date()
                    self.activityCooldown = nil
                    callbacks.forEach { $0(activity) }
                case .failed(let message):
                    self.activityCooldown = Date().addingTimeInterval(30)
                    var snapshot = self.activitySnapshot(stale: true)
                    snapshot.error = message
                    callbacks.forEach { $0(snapshot) }
                }
            }
        }
    }

    private func activitySnapshot(stale: Bool) -> Activity {
        var snapshot = activityGood ?? Activity()
        if activityGood == nil {
            snapshot.error = L("Magpie is not running.", "Magpie 未运行。")
        }
        snapshot.stale = stale && activityGood != nil
        return snapshot
    }

    private enum ActivityOutcome {
        case ok(Activity)
        case failed(String)
    }

    private static func runActivity(origin: URL) -> ActivityOutcome {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let manifest = get(session, origin.appendingPathComponent("")),
              MagpieDecode.isManifest(manifest) else {
            return .failed(L("Magpie is not running.", "Magpie 未运行。"))
        }
        guard let url = URL(string: "v1/magpie/usage/requests?limit=100", relativeTo: origin),
              let data = get(session, url),
              let rows = try? MagpieDecode.decodeRequests(data) else {
            return .failed(L("Magpie requests failed.", "Magpie 请求记录读取失败。"))
        }
        var result = activity(from: rows)
        // 今日合计直接取同一响应的合并 series（含 DSH 日志导入），不再发第二个请求。
        result.todayTotal = MagpieDecode.decodeUsageTodayTotal(data)
        result.weekTotal = MagpieDecode.decodeUsageWeekTotal(data)
        if let recent = MagpieDecode.decodeUsageRecentDays(data) {
            result.recentDayLabels = recent.labels
            result.recentDayTokens = recent.tokens
        }
        // 热力图 = App 同款整段历史：~/.cache/magpie/heat-v1.json（cut 前已归档的
        // 每日合计，只读）+ 同一份 30d 合并 series 补 cut 起的最近几天。
        // 缓存读不到时退回纯 30d series，卡片仍可用，只是窗口短。
        let recent = MagpieDecode.decodeUsageHeatDays(data)
        var cached: (cut: Date, days: [String: MagpieDecode.HeatDay])?
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/magpie/heat-v1.json")
        if let cacheData = try? Data(contentsOf: cacheURL) {
            cached = MagpieDecode.decodeHeatCache(cacheData)
        }
        // heat-v1.json 被 Magpie 清空时（只剩 cut，days 为空），从 usage.jsonl 重建。
        // usage.jsonl 是 Magpie 的原始请求日志，不会被清，按天聚合即可。
        if cached?.days.isEmpty == true {
            let usageURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/magpie/usage.jsonl")
            if let usageData = try? Data(contentsOf: usageURL) {
                cached = MagpieDecode.rebuildHeatCache(from: usageData, cut: cached?.cut)
            }
        }
        if let heat = MagpieDecode.mergeHeatmap(cached: cached, series: recent) {
            result.heatDays = heat
        }
        let fxURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/magpie/fxrate.json")
        if let fxData = try? Data(contentsOf: fxURL) {
            result.fxRate = MagpieDecode.decodeFxRate(fxData)
        }
        // 今日会话数 / 千问消耗是补充读数：任何一个失败只让对应区块走兜底或隐藏，
        // 不影响主 activity（tok/s、今日合计）的可用性。
        if let sessionsURL = URL(string: "v1/magpie/usage?period=today", relativeTo: origin),
           let sessionsData = get(session, sessionsURL) {
            result.todaySessions = MagpieDecode.decodeUsageTodaySessions(sessionsData)
        }
        if let qwenURL = URL(string: "v1/magpie/usage/requests?limit=1&period=today&provider=qwen", relativeTo: origin),
           let qwenData = get(session, qwenURL) {
            result.qwenToday = MagpieDecode.decodeQwenUsageToday(qwenData)
        }
        return .ok(result)
    }

    /// 最新一条真实对话请求（codex/dsh，排除 magpie/probe/mcp/curl 等内部流量）。
    /// tok/s 只在最近 120s 内有计时请求时给出，避免把几分钟前的速率当“实时”。
    static func activity(from rows: [MagpieDecode.RequestRow], now: Date = Date()) -> Activity {
        var conversations: [MagpieDecode.RequestRow] = []
        for row in rows where (row.agent == "codex" || row.agent == "dsh") && !row.session.isEmpty {
            conversations.append(row)
        }
        conversations.sort { $0.at > $1.at }
        var activity = Activity()
        guard let latest = conversations.first else { return activity }
        activity.model = latest.model.isEmpty ? nil : latest.model
        activity.session = latest.session
        activity.sessionTokens = latest.totalTokens
        activity.sessionCacheHit = latest.cacheHitPercent
        activity.requestAt = latest.at
        for row in conversations {
            guard row.hasTiming, row.status == 200, row.output > 0 else { continue }
            if now.timeIntervalSince(row.at) <= 120 {
                activity.tokensPerSecond = row.tokensPerSecond
            }
            break
        }
        return activity
    }

    /// fetchQueue 上同步执行：manifest 校验 → quotas → accounts（accounts 失败不致命）。
    private static func run(origin: URL) -> Outcome {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let manifest = get(session, origin.appendingPathComponent("")),
              MagpieDecode.isManifest(manifest) else {
            return .failed(L("Magpie is not running.", "Magpie 未运行。"))
        }
        guard let quotas = get(session, origin.appendingPathComponent("v1/magpie/quotas")) else {
            return .failed(L("Magpie quotas request failed.", "Magpie 额度请求失败。"))
        }
        let accounts = get(session, origin.appendingPathComponent("v1/magpie/accounts")) ?? Data()
        return .ok(quotas, accounts)
    }

    private static func get(_ session: URLSession, _ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, !data.isEmpty else { return }
            result = data
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return result
    }

    /// 拒重定向：loopback 只读接口不应把请求带去别处。
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
