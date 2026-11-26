import Foundation

/// DSH account balance and local usage. Progress comes from a top-up round, not a budget estimate.
struct DeepSeekSnapshot {
    var balance: Decimal? = nil
    /// The bar's denominator: everything the account holds, so the bar shows the remaining share.
    /// Either the balance right after the last top-up, or the platform's balance + cumulative spend.
    var startingBalance: Decimal? = nil
    /// `"account"` when `startingBalance` came from the platform bill (authoritative).
    /// nil means the caller's own top-up round decides the denominator.
    var startingBalanceSource: String? = nil
    var todaySpend: Decimal? = nil
    var todayTokens: Int64? = nil
    /// 今日缓存命中率（%），口径与 DSH 用量页面一致；缺失时为 nil。
    var todayCacheHitPercent: Double? = nil
    /// 本月 1 号到今天的 token 合计（DeepSeek 账户口径）；nil 表示不可用，界面显示「本月 —」。
    var monthTokens: Int64? = nil
    /// 今天按模型拆分的 token（"provider/model" → tokens），面板「按模型」行用；空数组表示没有数据。
    var todayByModel: [String: Int64] = [:]
    /// 今天所有 provider 的 token 合计，口径与 dsh-usage-stats 的「今日」一致。
    var todayAllTokens: Int64? = nil
    /// 今天按 provider 前缀拆分的 token（"deepseek-account" / "baidu-pzt" …），面板按来源分卡用。
    var todayProviderTokens: [String: Int64] = [:]
    /// DSH 用量接口里的会话清单（累计 token、模型、最后活动时间），按最近活动降序。
    var usageSessions: [(id: String, tokens: Int64, models: [String], lastAt: Date?)] = []
    /// 当前正在使用的模型（"provider/model"），取最近活跃会话的 session-context；nil 表示未知。
    var currentModel: String? = nil
    /// 当前模型今天的 token；nil 表示未知，界面回退到今日总量。
    var currentModelTokens: Int64? = nil
    /// 今天每个模型（"provider/model"）的缓存命中率（%），全 provider 都解；
    /// 当前模型不是 DeepSeek 时，Touch Bar 的缓存列用它，避免显示空。
    var todayModelCacheHit: [String: Double] = [:]
    /// 平台账单里的账户累计持有（totalHeld）。与余额同时存在时才能算“累计已花”。
    var accountTotalHeld: Decimal? = nil
    /// 近 7 日（旧→新）本地日期 "yyyy-MM-dd"，与 `recentDayTokens` 一一对应。
    /// 只统计 `deepseek-account/` 前缀的模型；无记录的那天 token 为 0。
    var recentDayLabels: [String] = []
    var recentDayTokens: [Int64] = []
    var currency: String = "CNY"
    var stale: Bool = false
    var message: String? = nil
}

/// No API keys, profile contents, command-line arguments, or environment are read.
/// State is main-thread confined; fetch may be called from any thread.
final class DSHBalanceProvider {
    private var configuredEndpoint: URL?
    private var invalidEndpoint = false
    private var discoveredEndpoint: URL?
    private var generation: UInt64 = 0
    private var cached: DeepSeekSnapshot?
    private var cachedDay: String?
    private var cachedTodayByModel: [String: Int64] = [:]
    private var cachedAllTokens: Int64?
    private var cachedProviderTokens: [String: Int64] = [:]
    private var cachedSessions: [(id: String, tokens: Int64, models: [String], lastAt: Date?)] = []
    /// 用户真正打开过的会话；nil = 列表还没取到或取不到（此时不过滤）。
    private var allowedConversations: Set<String>?
    private var cachedAt: Date?
    private var attemptedAt: Date?
    private var lastFailure: String?
    private var callbacks: [(DeepSeekSnapshot) -> Void] = []
    private var transport: DSHLocalRequest?

    /// Base origin only: http://127.0.0.1:<port>. nil enables local process discovery.
    var endpoint: URL? {
        get { configuredEndpoint ?? discoveredEndpoint }
        set {
            precondition(Thread.isMainThread)
            generation &+= 1
            transport?.cancel()
            transport = nil
            configuredEndpoint = newValue.flatMap(Self.validatedEndpoint)
            invalidEndpoint = newValue != nil && configuredEndpoint == nil
            discoveredEndpoint = nil
            cached = nil; cachedAt = nil; cachedDay = nil; attemptedAt = nil; lastFailure = nil
            let pending = callbacks; callbacks.removeAll()
            pending.forEach { $0(DeepSeekSnapshot(stale: true, message: "DSH 地址已更改，请刷新。")) }
        }
    }

    init(endpoint: URL? = nil) {
        configuredEndpoint = endpoint.flatMap(Self.validatedEndpoint)
        invalidEndpoint = endpoint != nil && configuredEndpoint == nil
    }

    /// Restrict to numeric IPv4 loopback (no DNS rebinding), no credentials/query/path.
    static func validatedEndpoint(_ url: URL) -> URL? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "http", c.host == "127.0.0.1", c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
              let port = c.port, (1...65535).contains(port) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    func fetch(force: Bool = false, completion: @escaping (DeepSeekSnapshot) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.fetch(force: force, completion: completion) }; return
        }
        if !callbacks.isEmpty { callbacks.append(completion); return }
        let day = Self.dayString(Date())
        if !force, let cached = cached, cachedDay == day, let at = cachedAt,
           Date().timeIntervalSince(at) < 60 { completion(cached); return }
        // A failed request cannot be hammered by repeated forced refreshes.
        if let failure = lastFailure, let at = attemptedAt, Date().timeIntervalSince(at) < 60 {
            completion(staleSnapshot(failure)); return
        }
        callbacks.append(completion)
        attemptedAt = Date()
        let version = generation
        if invalidEndpoint { finishFailure("仅支持无凭据、无查询参数的 http://127.0.0.1:端口 地址。"); return }
        if let configured = configuredEndpoint { tryEndpoints([configured], version: version); return }
        let known = discoveredEndpoint
        DispatchQueue.global(qos: .utility).async {
            var candidates = DSHLocalDiscovery.discover()
            if let known = known { candidates.removeAll { $0 == known }; candidates.insert(known, at: 0) }
            DispatchQueue.main.async {
                guard version == self.generation else { return }
                self.tryEndpoints(candidates, version: version)
            }
        }
    }

    private func tryEndpoints(_ endpoints: [URL], version: UInt64) {
        guard let origin = endpoints.first else {
            finishFailure("未找到可用的本机 DSH。请启动 DSH 并启用用量统计，或设置本机地址。"); return
        }
        let request = DSHLocalRequest()
        transport = request
        let url = origin.appendingPathComponent("api/usage-stats/account")
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "provider", value: "deepseek-account")]
        request.start(url: c.url!) { [weak self] result in
            guard let self = self, version == self.generation else { return }
            self.transport = nil
            do {
                let data = try result.get()
                let account = try DSHUsagePayload.decodeAccount(data)
                self.discoveredEndpoint = origin
                self.loadBill(origin: origin, account: account, version: version)
            } catch {
                if endpoints.count > 1 { self.tryEndpoints(Array(endpoints.dropFirst()), version: version) }
                else { self.finishFailure("DSH 账户不可用或本机接口无效；保留上次数据。") }
            }
        }
    }

    /// The platform bill is what turns "remaining of this round" into "remaining of the account":
    /// it carries the cumulative spend, so balance + spend is everything the account ever held.
    /// A missing or failed bill is not an error: the top-up round still provides a denominator.
    private func loadBill(origin: URL, account: DSHUsagePayload.AccountValue, version: UInt64) {
        let request = DSHLocalRequest()
        transport = request
        request.start(url: origin.appendingPathComponent("api/usage-stats/platform-bill")) { [weak self] result in
            guard let self = self, version == self.generation else { return }
            self.transport = nil
            let bill = try? DSHUsagePayload.decodeBill(try result.get())
            self.loadConversations(origin: origin, version: version) {
                self.loadUsage(origin: origin, account: account, bill: bill, version: version)
            }
        }
    }

    private func loadUsage(origin: URL, account: DSHUsagePayload.AccountValue,
                           bill: DSHUsagePayload.BillValue?, version: UInt64) {
        let request = DSHLocalRequest()
        transport = request
        request.start(url: origin.appendingPathComponent("api/usage-stats/usage")) { [weak self] result in
            guard let self = self, version == self.generation else { return }
            self.transport = nil
            let day = Self.dayString(Date())
            var snapshot = DeepSeekSnapshot(balance: bill?.balance ?? account.remaining,
                                             currency: bill?.currency ?? account.currency)
            if let total = bill?.totalHeld {
                snapshot.startingBalance = total
                snapshot.accountTotalHeld = total
                snapshot.startingBalanceSource = "account"
            }
            do {
                let data = try result.get()
                let today = try DSHUsagePayload.decodeToday(data, day: day)
                snapshot.todayTokens = today.tokens
                snapshot.todayCacheHitPercent = today.cacheHitPercent
                snapshot.monthTokens = today.monthTokens
                snapshot.todayByModel = today.byModel
                snapshot.todayAllTokens = today.allTokens
                snapshot.todayProviderTokens = today.providerTokens
                snapshot.todayModelCacheHit = DSHUsagePayload.decodeModelCache(data, day: day)
                snapshot.usageSessions = (try? DSHUsagePayload.decodeSessions(
                    data, limit: 12, allowed: self.allowedConversations)) ?? []
                self.cachedTodayByModel = today.byModel
                self.cachedAllTokens = today.allTokens
                self.cachedProviderTokens = today.providerTokens
                self.cachedSessions = snapshot.usageSessions
                let days = DSHUsagePayload.recentDayStrings(endingAt: Date())
                let recent = DSHUsagePayload.decodeRecentDays(data, days: days)
                snapshot.recentDayLabels = recent.dayLabels
                snapshot.recentDayTokens = recent.tokens
                self.lastFailure = nil
            } catch {
                snapshot.todayTokens = self.cachedDay == day ? self.cached?.todayTokens : nil
                snapshot.todayCacheHitPercent = self.cachedDay == day ? self.cached?.todayCacheHitPercent : nil
                snapshot.monthTokens = self.cachedDay == day ? self.cached?.monthTokens : nil
                snapshot.todayByModel = self.cachedDay == day ? self.cachedTodayByModel : [:]
                snapshot.todayAllTokens = self.cachedDay == day ? self.cachedAllTokens : nil
                snapshot.todayProviderTokens = self.cachedDay == day ? self.cachedProviderTokens : [:]
                snapshot.todayModelCacheHit = self.cachedDay == day ? (self.cached?.todayModelCacheHit ?? [:]) : [:]
                snapshot.usageSessions = self.cachedDay == day ? self.cachedSessions : []
                if self.cachedDay == day {
                    snapshot.recentDayLabels = self.cached?.recentDayLabels ?? []
                    snapshot.recentDayTokens = self.cached?.recentDayTokens ?? []
                }
                snapshot.stale = true
                snapshot.message = "DSH 今日用量暂不可用；余额已更新，用量保留上次数据。"
                self.lastFailure = snapshot.message
            }
            self.cachedSessions = snapshot.usageSessions
            self.loadCurrentModel(origin: origin, snapshot: snapshot, day: day, version: version)
        }
    }

    /// 跟随「最近活跃会话」的当前模型：session-context 给出该会话此刻的 provider/model，
    /// 再用今日按模型拆分取它的 token。失败不报错：currentModel 留 nil，界面回退今日总量。
    private func loadConversations(origin: URL, version: UInt64, then: @escaping () -> Void) {
        let request = DSHLocalRequest()
        transport = request
        request.start(url: origin.appendingPathComponent("api/usage-stats/conversations")) { [weak self] result in
            guard let self = self, version == self.generation else { return }
            self.transport = nil
            self.allowedConversations = (try? result.get()).flatMap { DSHUsagePayload.decodeConversationIds($0) }
            then()
        }
    }

    private func loadCurrentModel(origin: URL, snapshot: DeepSeekSnapshot, day: String, version: UInt64) {
        var snapshot = snapshot
        guard let top = snapshot.usageSessions.first else {
            self.cached = snapshot; self.cachedDay = day; self.cachedAt = Date()
            self.deliver(snapshot)
            return
        }
        let request = DSHLocalRequest()
        transport = request
        var c = URLComponents(url: origin.appendingPathComponent("api/usage-stats/session-context"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "session", value: top.id)]
        request.start(url: c.url!) { [weak self] result in
            guard let self = self, version == self.generation else { return }
            self.transport = nil
            if let data = try? result.get(),
               let cur = try? DSHUsagePayload.decodeSessionContext(data) {
                snapshot.currentModel = cur
                snapshot.currentModelTokens = snapshot.todayByModel[cur]
            }
            self.cached = snapshot; self.cachedDay = day; self.cachedAt = Date()
            self.deliver(snapshot)
        }
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func staleSnapshot(_ message: String) -> DeepSeekSnapshot {
        var value = cached ?? DeepSeekSnapshot()
        if cachedDay != Self.dayString(Date()) {
            value.todayTokens = nil
            value.todaySpend = nil
            value.todayCacheHitPercent = nil
            value.monthTokens = nil
            value.todayByModel = [:]
            value.todayModelCacheHit = [:]
            value.currentModel = nil
            value.currentModelTokens = nil
            value.recentDayLabels = []
            value.recentDayTokens = []
        }
        value.stale = true; value.message = message
        return value
    }
    private func finishFailure(_ message: String) {
        lastFailure = message
        deliver(staleSnapshot(message))
    }
    private func deliver(_ value: DeepSeekSnapshot) {
        let pending = callbacks; callbacks.removeAll()
        pending.forEach { $0(value) }
    }
}

/// Pure payload decoding, deliberately independent of network, profiles and Keychain.
enum DSHUsagePayload {
    struct AccountValue { let remaining: Decimal; let currency: String }
    enum Invalid: Error { case payload }
    private struct AccountResponse: Decodable {
        let ok: Bool
        let account: Account
        struct Account: Decodable {
            let status: String
            let source: String
            let stale: Bool?
            let balance: Balance?
        }
        struct Balance: Decodable { let remaining: Decimal?; let currency: String? }
    }
    static func decodeAccount(_ data: Data) throws -> AccountValue {
        guard data.count <= 256 * 1024 else { throw Invalid.payload }
        let response = try JSONDecoder().decode(AccountResponse.self, from: data)
        guard response.ok, response.account.status == "ok", response.account.source == "host-account",
              response.account.stale != true, let balance = response.account.balance,
              let amount = balance.remaining, !amount.isNaN, amount >= 0,
              let currency = balance.currency, ["CNY", "USD"].contains(currency) else { throw Invalid.payload }
        return AccountValue(remaining: amount, currency: currency)
    }
    /// `GET /api/usage-stats/platform-bill`: the harness passes the platform's own summary through.
    struct BillValue {
        let balance: Decimal?
        /// Balance + cumulative official spend: everything the account has ever held.
        let totalHeld: Decimal
        let currency: String
    }
    private struct BillResponse: Decodable {
        let ok: Bool
        let value: Bill?
        struct Bill: Decodable {
            let currency: String?
            let balance: Decimal?
            let totalCosts: Decimal?
            let totalHeld: Decimal?
            let stale: Bool?
        }
    }
    static func decodeBill(_ data: Data) throws -> BillValue {
        guard data.count <= 256 * 1024 else { throw Invalid.payload }
        let response = try JSONDecoder().decode(BillResponse.self, from: data)
        guard response.ok, let bill = response.value, bill.stale != true,
              let held = bill.totalHeld, !held.isNaN, held > 0,
              let currency = bill.currency, ["CNY", "USD"].contains(currency) else { throw Invalid.payload }
        if let balance = bill.balance, balance.isNaN || balance < 0 { throw Invalid.payload }
        if let costs = bill.totalCosts, costs.isNaN || costs < 0 { throw Invalid.payload }
        return BillValue(balance: bill.balance, totalHeld: held, currency: currency)
    }

    private struct UsageResponse: Decodable {
        let ok: Bool
        let days: [Day]
        let sessions: [Session]?
        struct Day: Decodable { let date: String; let models: [Model] }
        struct Session: Decodable {
            let sessionId: String
            let tokens: Int64?
            let models: [String]?
            let lastAt: String?
        }
        // Ignore foreign providers' numbers entirely, including malformed/overflowing values.
        struct Model: Decodable {
            let model: String
            let tokens: Int64?
            let inputTokens: Int64?
            let cacheReadTokens: Int64?
            let cacheWriteTokens: Int64?
            enum CodingKeys: String, CodingKey {
                case model, tokens, inputTokens, cacheReadTokens, cacheWriteTokens
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                model = try c.decode(String.self, forKey: .model)
                let own = model.hasPrefix("deepseek-account/")
                // token 总数对所有 provider 都解出来（面板要按模型分行显示）；输入/缓存明细只给 DeepSeek。
                // 其它 provider 的数字只用于「按模型」一行，解不出来就跳过，不因为它让整份统计失败。
                tokens = own
                    ? try c.decode(Int64.self, forKey: .tokens)
                    : (try? c.decodeIfPresent(Int64.self, forKey: .tokens)) ?? nil
                inputTokens = own ? try c.decodeIfPresent(Int64.self, forKey: .inputTokens) : nil
                cacheReadTokens = own ? try c.decodeIfPresent(Int64.self, forKey: .cacheReadTokens) : nil
                cacheWriteTokens = own ? try c.decodeIfPresent(Int64.self, forKey: .cacheWriteTokens) : nil
            }
        }
    }

    struct TodayUsage {
        let tokens: Int64
        /// 缓存命中率 = cacheRead / (input + cacheRead)，与 DSH 用量页面同一口径。
        let cacheHitPercent: Double?
        /// 本月 1 号到今天（含）的 deepseek-account token 合计；解析失败为 nil，界面显示「—」。
        let monthTokens: Int64?
        /// 今天所有 provider 的模型拆分，按 token 降序；给面板的「按模型」行用。
        let byModel: [String: Int64]
        /// 今天所有 provider 的 token 合计：面板「AI 用量」大数字用它。
        let allTokens: Int64
        /// 今天按 provider 前缀（model 名 "/" 之前）拆分的 token 合计。
        let providerTokens: [String: Int64]
    }

    static func decodeToday(_ data: Data, day: String) throws -> TodayUsage {
        guard data.count <= 256 * 1024 else { throw Invalid.payload }
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        guard response.ok else { throw Invalid.payload }
        let matches = response.days.filter { $0.date == day }
        guard matches.count <= 1 else { throw Invalid.payload }

        var tokens: Int64 = 0
        var input: Int64 = 0
        var cachedInput: Int64 = 0
        var cacheWrite: Int64 = 0
        var anyModel = false
        for model in matches.first?.models ?? [] where model.model.hasPrefix("deepseek-account/") {
            anyModel = true
            guard let count = model.tokens, count >= 0 else { throw Invalid.payload }
            let sum = tokens.addingReportingOverflow(count)
            guard !sum.overflow else { throw Invalid.payload }
            tokens = sum.partialValue
            if let value = model.inputTokens {
                guard value >= 0 else { throw Invalid.payload }
                let total = input.addingReportingOverflow(value)
                guard !total.overflow else { throw Invalid.payload }
                input = total.partialValue
            }
            if let value = model.cacheReadTokens {
                guard value >= 0 else { throw Invalid.payload }
                let total = cachedInput.addingReportingOverflow(value)
                guard !total.overflow else { throw Invalid.payload }
                cachedInput = total.partialValue
            }
            if let value = model.cacheWriteTokens {
                guard value >= 0 else { throw Invalid.payload }
                let total = cacheWrite.addingReportingOverflow(value)
                guard !total.overflow else { throw Invalid.payload }
                cacheWrite = total.partialValue
            }
        }

        var byModel: [String: Int64] = [:]
        var allTokens: Int64 = 0
        var providerTokens: [String: Int64] = [:]
        for model in matches.first?.models ?? [] {
            guard let count = model.tokens, count > 0, !model.model.isEmpty else { continue }
            byModel[model.model, default: 0] = count
            let sum = allTokens.addingReportingOverflow(count)
            if !sum.overflow { allTokens = sum.partialValue }
            if let provider = model.model.split(separator: "/", maxSplits: 1).first.map(String.init),
               !provider.isEmpty {
                let running = providerTokens[provider] ?? 0
                let next = running.addingReportingOverflow(count)
                if !next.overflow { providerTokens[provider] = next.partialValue }
            }
        }

        // 与 dsh-usage-stats 的 cacheHitRate 同口径：cacheRead / (input + cacheRead + cacheWrite)。
        let prompt = input.addingReportingOverflow(cachedInput)
        let denominator = prompt.partialValue.addingReportingOverflow(cacheWrite)
        let rate: Double?
        if anyModel, !prompt.overflow, !denominator.overflow, denominator.partialValue > 0 {
            rate = min(100, Double(cachedInput) / Double(denominator.partialValue) * 100)
        } else {
            rate = nil
        }
        // 本月累计：同一份 payload 里 1 号到今天的自然日求和，口径与今日完全一致。
        var month: Int64 = 0
        var monthOK = true
        if day.count >= 7 {
            let prefix = String(day.prefix(7))
            for entry in response.days where entry.date.hasPrefix(prefix) {
                for model in entry.models where model.model.hasPrefix("deepseek-account/") {
                    guard let count = model.tokens, count >= 0 else { monthOK = false; break }
                    let sum = month.addingReportingOverflow(count)
                    if sum.overflow { monthOK = false; break }
                    month = sum.partialValue
                }
                if !monthOK { break }
            }
        } else {
            monthOK = false
        }
        return TodayUsage(tokens: tokens, cacheHitPercent: rate, monthTokens: monthOK ? month : nil,
                          byModel: byModel, allTokens: allTokens, providerTokens: providerTokens)
    }

    // MARK: 会话清单

    /// 用量 payload 里的 sessions 数组：每个会话的累计 token、模型与最后活动时间。
    /// 标题不在这个接口里（它只给 null），由 DSHSessionTitles 从 DSH 的会话缓存只读取。
    static func decodeSessions(_ data: Data, limit: Int = 12, allowed: Set<String>? = nil) throws
        -> [(id: String, tokens: Int64, models: [String], lastAt: Date?)] {
        guard data.count <= 1024 * 1024 else { throw Invalid.payload }
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        guard response.ok else { throw Invalid.payload }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        var items: [(id: String, tokens: Int64, models: [String], lastAt: Date?)] = []
        for session in response.sessions ?? [] {
            guard !session.sessionId.isEmpty, let count = session.tokens, count >= 0 else { continue }
            // 过滤要在截断之前：否则最近一批子代理会话会把用户的会话挤出去。
            if let allowed = allowed, !allowed.isEmpty,
               !allowed.contains(sessionKey(session.sessionId)) { continue }
            let last = session.lastAt.flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            items.append((id: session.sessionId, tokens: count,
                          models: session.models ?? [], lastAt: last))
        }
        items.sort { ($0.lastAt ?? .distantPast) > ($1.lastAt ?? .distantPast) }
        return Array(items.prefix(max(0, min(limit, 24))))
    }

    /// 用户自己打开过的会话 id（来自 harness 的 workspace 列表）。
    /// 返回 nil 表示列表不可用：调用方此时不应过滤，否则会把整列会话弄空。
    static func decodeConversationIds(_ data: Data) -> Set<String>? {
        guard data.count <= 512 * 1024 else { return nil }
        struct Response: Decodable {
            let ok: Bool
            let sessionIds: [String]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.ok, let ids = response.sessionIds else { return nil }
        return Set(ids.map { sessionKey($0) })
    }

    /// 同一会话在 usage 接口里可能是 `session-<uuid>`，也可能是裸 uuid，统一后再比较。
    static func sessionKey(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        let prefix = "session-"
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }

    /// 仅 token 总数的旧入口，保留给既有测试与调用方。
    static func decodeTodayTokens(_ data: Data, day: String) throws -> Int64 {
        try decodeToday(data, day: day).tokens
    }

    /// 今天每个模型的缓存命中率（%），不限 provider；口径 cacheRead/(input+cacheRead+cacheWrite)。
    /// 解析失败/缺字段返回空表，界面回退到 DeepSeek 口径，不因为它让整份统计失败。
    static func decodeModelCache(_ data: Data, day: String) -> [String: Double] {
        guard data.count <= 256 * 1024 else { return [:] }
        struct AnyModel: Decodable {
            let model: String
            let inputTokens: Int64?
            let cacheReadTokens: Int64?
            let cacheWriteTokens: Int64?
        }
        struct AnyDay: Decodable { let date: String; let models: [AnyModel] }
        struct AnyResponse: Decodable { let ok: Bool; let days: [AnyDay] }
        guard let response = try? JSONDecoder().decode(AnyResponse.self, from: data), response.ok,
              let entry = response.days.first(where: { $0.date == day }) else { return [:] }
        var out: [String: Double] = [:]
        for model in entry.models {
            let input = model.inputTokens ?? 0
            let cached = model.cacheReadTokens ?? 0
            let write = model.cacheWriteTokens ?? 0
            guard input >= 0, cached >= 0, write >= 0, !model.model.isEmpty else { continue }
            let prompt = input.addingReportingOverflow(cached)
            let denom = prompt.partialValue.addingReportingOverflow(write)
            guard !prompt.overflow, !denom.overflow, denom.partialValue > 0 else { continue }
            out[model.model] = min(100, Double(cached) / Double(denom.partialValue) * 100)
        }
        return out
    }

    // MARK: 当前模型

    private struct SessionContextResponse: Decodable {
        let ok: Bool
        let context: Context?
        struct Context: Decodable {
            let providerId: String?
            let model: String?
        }
    }

    /// session-context 里该会话此刻的模型，拼成 "provider/model"（与 todayByModel 的键同口径）。
    static func decodeSessionContext(_ data: Data) throws -> String {
        guard data.count <= 256 * 1024 else { throw Invalid.payload }
        let response = try JSONDecoder().decode(SessionContextResponse.self, from: data)
        guard response.ok, let context = response.context,
              let model = context.model, !model.isEmpty else { throw Invalid.payload }
        let provider = context.providerId ?? ""
        return provider.isEmpty ? model : provider + "/" + model
    }

    /// 模型短名：去掉 provider 前缀再压缩到 Touch Bar 侧栏放得下的长度，保留可辨识主干。
    static func shortModel(_ key: String) -> String {
        let name = key.split(separator: "/").last.map(String.init) ?? key
        switch name {
        case "qwen4-max-preview": return "qwen4-max"
        case "deepseek-v4.1-flash-1017": return "v4.1-flash"
        case "deepseek-flash": return "ds-flash"
        case "qianfan-code-latest": return "qianfan"
        default:
            return name.count <= 12 ? name : String(name.prefix(11)) + "…"
        }
    }

    // MARK: 近 7 日趋势

    struct RecentDays {
        let dayLabels: [String]
        let tokens: [Int64]
    }

    /// 近 `count` 个本地自然日（旧→新，含今天），格式 yyyy-MM-dd。
    /// 只做日期算术，不读磁盘、不联网。
    static func recentDayStrings(endingAt now: Date, count: Int = 7,
                                 calendar: Calendar = .current) -> [String] {
        guard count > 0, count <= 31 else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = calendar.startOfDay(for: now)
        var result: [String] = []
        result.reserveCapacity(count)
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start) else { return [] }
            result.append(formatter.string(from: date))
        }
        return result
    }

    /// 按给定日期列表读取 `deepseek-account/` 的 token 总量，顺序与 `days` 一致。
    /// 缺字段、负值、溢出、重复日期、超大响应都返回空数组——宁可不画，也不画错。
    static func decodeRecentDays(_ data: Data, days: [String]) -> RecentDays {
        let empty = RecentDays(dayLabels: [], tokens: [])
        guard !days.isEmpty, days.count <= 31, Set(days).count == days.count,
              data.count <= 256 * 1024,
              let response = try? JSONDecoder().decode(UsageResponse.self, from: data),
              response.ok else { return empty }
        var totals: [String: Int64] = [:]
        for day in days { totals[day] = 0 }
        var seen = Set<String>()
        for entry in response.days where totals[entry.date] != nil {
            guard seen.insert(entry.date).inserted else { return empty }
            var sum: Int64 = 0
            for model in entry.models where model.model.hasPrefix("deepseek-account/") {
                guard let value = model.tokens, value >= 0 else { return empty }
                let next = sum.addingReportingOverflow(value)
                guard !next.overflow else { return empty }
                sum = next.partialValue
            }
            let merged = (totals[entry.date] ?? 0).addingReportingOverflow(sum)
            guard !merged.overflow else { return empty }
            totals[entry.date] = merged.partialValue
        }
        return RecentDays(dayLabels: days, tokens: days.map { totals[$0] ?? 0 })
    }
}

/// Discovery inspects executable names and parent PIDs, never arguments or environment.
/// No descriptor is currently published by DSH; no profile/config/credential files are opened.
enum DSHLocalDiscovery {
    static func discover() -> [URL] {
        guard let processes = output("/bin/ps", ["-axo", "pid=,ppid=,comm="]) else { return [] }
        var parents: [Int: Int] = [:]
        var allowed = Set<Int>()
        for line in processes.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { continue }
            parents[pid] = parent
            let name = String(fields[2])
            if name.hasSuffix("/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness") { allowed.insert(pid) }
        }
        // Limit descendants to Electron/Node host processes, not arbitrary tools launched by agents.
        for _ in 0..<8 {
            for line in processes.split(separator: "\n") {
                let f = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
                guard f.count == 3, let pid = Int(f[0]), let parent = parents[pid], allowed.contains(parent) else { continue }
                let name = String(f[2])
                if name.contains("/DeepSeek Harness.app/Contents/") || name.hasSuffix("/node") || name.hasSuffix("/Electron") {
                    allowed.insert(pid)
                }
            }
        }
        guard !allowed.isEmpty,
              let listeners = output("/usr/sbin/lsof", ["-nP", "-a", "-p", allowed.sorted().map(String.init).joined(separator: ","), "-iTCP", "-sTCP:LISTEN", "-Fpn"]) else { return [] }
        return parseListeners(listeners, allowed: allowed)
    }
    static func parseListeners(_ text: String, allowed: Set<Int>) -> [URL] {
        var pid: Int?
        var ports = Set<Int>()
        for line in text.split(separator: "\n") {
            if line.first == "p" { pid = Int(line.dropFirst()) }
            if line.first == "n", let pid = pid, allowed.contains(pid) {
                let address = String(line.dropFirst())
                // Wildcard listeners are probed ONLY via numeric IPv4 loopback.
                guard address.hasPrefix("127.0.0.1:") || address.hasPrefix("*:"),
                      let suffix = address.split(separator: ":").last,
                      let port = Int(suffix), (1...65535).contains(port) else { continue }
                ports.insert(port)
            }
        }
        return ports.sorted().prefix(8).compactMap { URL(string: "http://127.0.0.1:\($0)") }
    }
    private static func output(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: deadline)
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if chunk.count > 256 * 1024 - data.count { process.terminate(); break }
            data.append(chunk)
        }
        process.waitUntilExit(); deadline.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Streaming, bounded, credential-free local HTTP transport. Redirects are never followed.
final class DSHLocalRequest: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var rejected = false
    private var completion: ((Result<Data, Error>) -> Void)?
    private let limit = 256 * 1024
    /// 4xx 响应体里带着插件自己的错误码（session-required / unknown-session），
    /// 余额请求只要 2xx，所以默认仍然拒绝 4xx；会话请求显式打开这个开关。
    private let acceptErrorBody: Bool
    private(set) var statusCode: Int = 0

    init(acceptErrorBody: Bool = false) {
        self.acceptErrorBody = acceptErrorBody
        super.init()
    }
    func start(url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "x-dsh-usage-stats-client-locale")
        request.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "x-dsh-usage-stats-timezone-offset")
        task = session.dataTask(with: request); task?.resume()
    }
    func cancel() {
        completion = nil; task?.cancel(); session?.invalidateAndCancel(); task = nil; session = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
                || (acceptErrorBody && (400...499).contains(http.statusCode)),
              response.expectedContentLength <= Int64(limit) else {
            rejected = true; completionHandler(.cancel); return
        }
        statusCode = http.statusCode
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !rejected else { return }
        guard data.count <= limit - body.count else { rejected = true; dataTask.cancel(); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callback = completion; completion = nil
        session.finishTasksAndInvalidate(); self.session = nil; self.task = nil
        if rejected { callback?(.failure(DSHUsagePayload.Invalid.payload)) }
        else if let error = error { callback?(.failure(error)) }
        else { callback?(.success(body)) }
    }
}
