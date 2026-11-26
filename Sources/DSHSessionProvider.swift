import Foundation

/// 当前 DSH 对话的用量（只读、只走本机回环接口）。
///
/// 数据来源只有两个 usage-stats 端点，均由插件自己按事件归属聚合：
/// - `/api/usage-stats/session-context`（一个活动会话的 provider / model / token / 费用）
/// - `/api/usage-stats/usage`（仅在需要列出候选会话时读取 `sessions` 数组）
///
/// 这里不做任何推断：拿不到会话就报「未选择」，拿不到完整费用就报「暂无数据」。
struct DSHSessionUsage: Equatable {
    var sessionId: String
    var title: String?
    var providerId: String
    var providerFamily: String?
    var model: String
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var cacheWriteTokens: Int64
    var totalTokens: Int64
    /// 只有数据源给出完整且单一币种的计价时才非 nil。
    var estimatedCost: Decimal?
    var currency: String?
    var pricingSource: String?
    var lastAt: Date?
    /// 本会话出现过的模型键（`provider/model`），用于如实标注“混用”。
    var models: [String]

    /// 本会话是否混用了多个模型。混用时只展示合计，并明确标注。
    var isMixedModel: Bool { models.count > 1 }
    /// 没有用户指定的会话时，按「最近活跃」自动跟上的那个；界面据此标注，不冒充用户选择。
    var autoSelected: Bool = false
}

/// 面板里可以手动选择的候选会话（来自 usage 的 sessions 数组，按最近活动排序）。
struct DSHSessionChoice: Equatable {
    var sessionId: String
    var title: String?
    var models: [String]
    var lastAt: Date?

    var displayName: String {
        if let title, !title.isEmpty { return title }
        // 会话 id 形如 "session-8428a5de-…"：去掉前缀再取 8 位，否则前缀永远是 "session-"。
        return DSHSessionFormat.shortId(sessionId)
    }
}

enum DSHSessionStatus: Equatable {
    case off                       // 用户关闭了跟随
    case connecting
    case live(DSHSessionUsage)
    case needsSelection([DSHSessionChoice])
    case noSession(String)         // 连上了，但当前会话没有可用数据
    case unavailable(String)       // 断线 / 插件不可用 / 会话已关闭

    /// 有活会话时才画实心圆点；其它状态一律灰点，不冒充“进行中”。
    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

// MARK: - 纯解析（离线可测）

enum DSHSessionPayload {
    enum Invalid: Error { case shape }

    struct ContextResult: Equatable {
        var usage: DSHSessionUsage?
        var needsSelection: Bool
        var message: String?
    }

    static func decodeContext(_ data: Data) throws -> ContextResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid.shape
        }
        if let ok = root["ok"] as? Bool, ok == false {
            switch root["error"] as? String {
            case "session-required":
                return ContextResult(usage: nil, needsSelection: true, message: nil)
            case "unknown-session":
                return ContextResult(usage: nil, needsSelection: false,
                                     message: "该对话已不在 DSH 中打开")
            case let code?:
                let text = (root["message"] as? String) ?? code
                return ContextResult(usage: nil, needsSelection: false, message: text)
            case nil:
                return ContextResult(usage: nil, needsSelection: false, message: "本机用量统计返回了未知错误")
            }
        }
        guard root["ok"] as? Bool == true else {
            throw Invalid.shape
        }
        guard let context = root["context"] as? [String: Any] else {
            // ok + context:null：当前没有可识别的会话，不是错误，但也没有数据。
            return ContextResult(usage: nil, needsSelection: false, message: nil)
        }
        guard let sessionId = context["sessionId"] as? String, !sessionId.isEmpty,
              let providerId = context["providerId"] as? String, !providerId.isEmpty,
              let model = context["model"] as? String, !model.isEmpty else {
            throw Invalid.shape
        }
        let session = context["session"] as? [String: Any] ?? [:]
        let models = (session["models"] as? [String]) ?? []
        // 费用只在“完整 + 单币种”时才认，其余一律 nil（界面显示暂无数据）。
        let complete = (session["costComplete"] as? Bool) ?? false
        var cost: Decimal?
        var currency: String?
        if complete, let raw = session["estimatedCost"], !(raw is NSNull) {
            let number = (raw as? NSNumber)?.doubleValue
            if let number, number.isFinite, number >= 0 {
                cost = Decimal(string: String(format: "%.6f", number), locale: Locale(identifier: "en_US_POSIX"))
                currency = (session["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if currency == nil { cost = nil }
            }
        }
        let pricing = session["pricing"] as? [String: Any]
        let source = pricing?["source"] as? String
        let usage = DSHSessionUsage(
            sessionId: sessionId,
            title: (session["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            providerId: providerId,
            providerFamily: context["providerFamily"] as? String,
            model: model,
            inputTokens: int64(session["inputTokens"]),
            outputTokens: int64(session["outputTokens"]),
            cacheReadTokens: int64(session["cacheReadTokens"]),
            cacheWriteTokens: int64(session["cacheWriteTokens"]),
            totalTokens: int64(session["tokens"]),
            estimatedCost: cost,
            currency: currency,
            pricingSource: source,
            lastAt: isoDate(session["lastAt"] as? String),
            models: models
        )
        return ContextResult(usage: usage, needsSelection: false, message: nil)
    }

    /// usage 端点里的 `sessions`：只用来给用户挑会话，不参与任何汇总。
    static func decodeChoices(_ data: Data) throws -> [DSHSessionChoice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]] else { throw Invalid.shape }
        let choices: [DSHSessionChoice] = sessions.compactMap { item in
            guard let id = item["sessionId"] as? String, !id.isEmpty else { return nil }
            return DSHSessionChoice(sessionId: id,
                                    title: (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    models: (item["models"] as? [String]) ?? [],
                                    lastAt: isoDate(item["lastAt"] as? String))
        }
        return choices.sorted { ($0.lastAt ?? .distantPast) > ($1.lastAt ?? .distantPast) }
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String, let parsed = Int64(text) { return parsed }
        return 0
    }

    private static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - 展示口径（离线可测）

enum DSHSessionFormat {
    /// 「≈ ¥0.31」或「暂无数据」。第二行是口径说明，绝不用 0 冒充未知。
    static func cost(_ usage: DSHSessionUsage) -> (text: String, note: String) {
        guard let cost = usage.estimatedCost, let currency = usage.currency else {
            return ("暂无数据", "无完整计价")
        }
        let symbol = symbol(for: currency)
        let value = NSDecimalNumber(decimal: cost).doubleValue
        let text: String
        if value == 0 { text = symbol + "0.00" } else if value < 0.01 {
            text = symbol + String(format: "%.4f", value)
        } else {
            text = symbol + String(format: "%.2f", value)
        }
        let source = usage.pricingSource.flatMap { $0.isEmpty ? nil : $0 }
        return ("≈ " + text, source.map { "估算 · 本会话 · " + $0 } ?? "估算 · 本会话")
    }

    static func symbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        default: return currency.uppercased() + " "
        }
    }

    /// 会话标题缺省时用短 id，保证「这是哪个对话」有据可查。
    /// `session-8428a5de-53b1-…` → `8428a5de`，给没有标题的会话一个可认的短名。
    static func shortId(_ sessionId: String) -> String {
        var rest = sessionId
        if rest.hasPrefix("session-") { rest.removeFirst("session-".count) }
        let head = String(rest.prefix(8))
        return head.isEmpty ? String(sessionId.prefix(8)) : head
    }

    static func title(_ usage: DSHSessionUsage) -> String {
        if let title = usage.title, !title.isEmpty { return title }
        return shortId(usage.sessionId)
    }

    static func modelLine(_ usage: DSHSessionUsage) -> String {
        let family = usage.providerFamily.flatMap { $0.isEmpty ? nil : $0 }
        let provider = (family ?? usage.providerId).flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.lowercased() == "unknown" ? nil : trimmed
        }
        // 供应商解析不出来时只留模型名，不把内部的 "unknown" 摊到界面上。
        return provider.map { $0 + " · " + usage.model } ?? usage.model
    }
}

// MARK: - 本机请求

final class DSHSessionProvider {
    /// 手动指定时只请求这个 origin；nil 表示按本机进程自动发现。
    var endpoint: URL? {
        didSet { discovered = nil; cache = nil; cacheAt = nil }
    }

    private var discovered: URL?
    private var cache: (DSHSessionStatus, [DSHSessionChoice])?
    private var cacheAt: Date?
    private var cacheKey: String = ""
    private var transport: DSHLocalRequest?
    private var generation: UInt64 = 0

    /// 关闭跟随时调用：取消在途请求并作废回调，避免旧结果写回面板。
    func cancel() {
        generation &+= 1
        transport?.cancel()
        transport = nil
        cache = nil
        cacheAt = nil
    }

    /// `selection` 是用户手动指定的会话 id；nil 表示跟随（单会话时自动）。
    func fetch(force: Bool, selection: String?, completion: @escaping (DSHSessionStatus, [DSHSessionChoice]) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.fetch(force: force, selection: selection, completion: completion) }
            return
        }
        let key = selection ?? ""
        if !force, cacheKey == key, let cache, let at = cacheAt,
           Date().timeIntervalSince(at) < 10 {
            completion(cache.0, cache.1)
            return
        }
        generation &+= 1
        let version = generation
        transport?.cancel()
        let request = DSHLocalRequest(acceptErrorBody: true)
        transport = request

        let known = discovered
        DispatchQueue.global(qos: .utility).async {
            var candidates: [URL]
            if let endpoint = self.endpoint {
                candidates = [endpoint]
            } else {
                candidates = DSHLocalDiscovery.discover()
                if let known, let index = candidates.firstIndex(of: known) {
                    candidates.remove(at: index); candidates.insert(known, at: 0)
                }
            }
            DispatchQueue.main.async {
                guard version == self.generation else { return }
                self.attempt(candidates, selection: selection, request: request,
                             version: version, completion: completion)
            }
        }
    }

    private func attempt(_ candidates: [URL], selection: String?, request: DSHLocalRequest,
                         version: UInt64, completion: @escaping (DSHSessionStatus, [DSHSessionChoice]) -> Void,
                         auto: Bool = false) {
        guard let origin = candidates.first else {
            finish(.unavailable("未连接：未找到本机 DSH"), choices: [], selection: selection,
                   completion: completion)
            return
        }
        var components = URLComponents(url: origin.appendingPathComponent("api/usage-stats/session-context"),
                                       resolvingAgainstBaseURL: false)!
        if let selection, !selection.isEmpty {
            components.queryItems = [URLQueryItem(name: "session", value: selection)]
        }
        request.start(url: components.url!) { [weak self] result in
            guard let self, version == self.generation else { return }
            self.transport = nil
            guard case .success(let data) = result else {
                // 换下一个候选端口；全部失败再报未连接。
                var rest = candidates
                rest.removeFirst()
                if rest.isEmpty {
                    self.finish(.unavailable("未连接：本机用量统计没有响应"), choices: [],
                                selection: selection, completion: completion)
                } else {
                    let next = DSHLocalRequest(acceptErrorBody: true)
                    self.transport = next
                    self.attempt(rest, selection: selection, request: next,
                                 version: version, completion: completion)
                }
                return
            }
            self.discovered = origin
            do {
                let payload = try DSHSessionPayload.decodeContext(data)
                if payload.needsSelection {
                    self.loadChoices(origin: origin, selection: selection, version: version,
                                     completion: completion)
                    return
                }
                if let message = payload.message {
                    self.finish(.unavailable(message), choices: [], selection: selection,
                                completion: completion)
                    return
                }
                guard let usage = payload.usage else {
                    self.finish(.noSession("这个对话还没有可用的用量记录"), choices: [],
                                selection: selection, completion: completion)
                    return
                }
                var live = usage
                live.autoSelected = auto
                self.finish(.live(live), choices: self.lastChoices, selection: selection,
                            completion: completion)
            } catch {
                // 这个端口答得出 usage 但答不出 session-context（例如旧实例/旧版本插件），
                // 换下一个候选继续试；全部失败才报未连接，避免把“旧端口”当成“当前对话不可用”。
                var rest = candidates
                rest.removeFirst()
                if rest.isEmpty {
                    self.finish(.unavailable("未连接：本机用量统计没有提供当前对话数据"),
                                choices: [], selection: selection, completion: completion)
                } else {
                    let next = DSHLocalRequest(acceptErrorBody: true)
                    self.transport = next
                    self.attempt(rest, selection: selection, request: next,
                                 version: version, completion: completion)
                }
            }
        }
    }

    private var lastChoices: [DSHSessionChoice] = []

    private func loadChoices(origin: URL, selection: String?, version: UInt64,
                             completion: @escaping (DSHSessionStatus, [DSHSessionChoice]) -> Void) {
        let request = DSHLocalRequest(acceptErrorBody: true)
        transport = request
        request.start(url: origin.appendingPathComponent("api/usage-stats/usage")) { [weak self] result in
            guard let self, version == self.generation else { return }
            self.transport = nil
            guard case .success(let data) = result,
                  let choices = try? DSHSessionPayload.decodeChoices(data) else {
                self.finish(.needsSelection([]), choices: [], selection: selection, completion: completion)
                return
            }
            self.lastChoices = choices
            // 用户没有指定会话时，自动跟随最近活跃的那个（与 DSH 面板“跟随当前会话”的观感一致），
            // 并在卡片上标注这是自动跟随，随时可切换或关闭。
            if selection == nil, let newest = choices.first {
                let next = DSHLocalRequest(acceptErrorBody: true)
                self.transport = next
                self.attempt([origin], selection: newest.sessionId, request: next,
                             version: version, completion: completion, auto: true)
                return
            }
            self.finish(.needsSelection(choices), choices: choices, selection: selection,
                        completion: completion)
        }
    }

    private func finish(_ status: DSHSessionStatus, choices: [DSHSessionChoice], selection: String?,
                        completion: @escaping (DSHSessionStatus, [DSHSessionChoice]) -> Void) {
        cache = (status, choices)
        cacheAt = Date()
        cacheKey = selection ?? ""
        completion(status, choices)
    }
}
