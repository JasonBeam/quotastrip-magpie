import Foundation
import Security

/// 千问 Token Plan 的一个额度窗口（status.jimmycloud.cc 只读用量接口）。
/// usedPercent 是「已用」百分比；剩余 = 100 - usedPercent。
struct QwenPlanWindow: Equatable {
    let key: String
    let label: String
    let limit: Double?
    let usedPercent: Double
    let resetAt: Date?
    let unit: String

    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

/// 分模型 / 分钥匙明细行。上游个人版套餐暂返回空数组（billing 只认套餐购买），
/// 形状宽松兼容：model|label|key_label|key 作名字，used|share 作数值；空数组=不显示。
struct QwenUsageLine: Equatable {
    let label: String
    let used: Double?
    let share: Double?
}

struct QwenPlan: Equatable {
    let plan: String
    let status: String
    let source: String
    let note: String
    let observedAt: Date?
    let maxAge: TimeInterval
    let windows: [QwenPlanWindow]
    var id: String = ""
    var label: String = ""
    var models: [QwenUsageLine] = []
    var keys: [QwenUsageLine] = []

    /// 面板只关心月度窗口；没有 monthly 键时退回第一个窗口。
    var monthlyWindow: QwenPlanWindow? { windows.first { $0.key == "monthly" } ?? windows.first }

    /// 超过 max_age_seconds 没更新即视为过期；没有观测时间一律算过期。
    func isStale(at now: Date = Date()) -> Bool {
        guard let observedAt else { return true }
        return now.timeIntervalSince(observedAt) > maxAge
    }

    enum DecodeError: Error {
        case oversized, invalidJSON, notOK, emptyWindows, emptyAccounts, invalidWindow, invalidReset
    }

    /// 多账号形状：/api/v1/usage/accounts 顶层数组，每项=直连扁平形状 + id/label/models/keys。
    /// 空数组视为无效（保留上次好值）；models/keys 缺失或空都兼容。
    static func decodeAccounts(_ data: Data) throws -> [QwenPlan] {
        guard data.count <= 256 * 1024 else { throw DecodeError.oversized }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DecodeError.invalidJSON
        }
        guard !array.isEmpty else { throw DecodeError.emptyAccounts }
        return try array.map { raw in
            var plan = try decodeDirect(raw)
            plan.id = raw["id"] as? String ?? ""
            plan.label = raw["label"] as? String ?? ""
            plan.models = usageLines(raw["models"])
            plan.keys = usageLines(raw["keys"])
            return plan
        }
    }

    private static func usageLines(_ raw: Any?) -> [QwenUsageLine] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            let label = (item["model"] as? String) ?? (item["label"] as? String)
                ?? (item["key_label"] as? String) ?? (item["key"] as? String) ?? ""
            guard !label.isEmpty else { return nil }
            func number(_ keys: [String]) -> Double? {
                for key in keys {
                    if let value = item[key] as? NSNumber, !(item[key] is Bool),
                       value.doubleValue.isFinite { return value.doubleValue }
                }
                return nil
            }
            return QwenUsageLine(label: label,
                                 used: number(["used", "used_credits", "used_tokens", "credits"]),
                                 share: number(["share", "share_percent", "percent"]))
        }
    }

    /// 兼容两种形状：
    ///  - 直连接口 /api/v1/qwen/usage：扁平 {plan,unit,monthly_limit,used_percent,reset_at,observed_at,data_status,stale,sync_status}
    ///  - 旧 Chrome 遥测 plan-usage.json：{qwen:{ok,windows:[...],plan,status,observed_at(epoch),max_age_seconds}}
    static func decode(_ data: Data) throws -> QwenPlan {
        guard data.count <= 256 * 1024 else { throw DecodeError.oversized }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DecodeError.invalidJSON
        }
        if let qwen = root["qwen"] as? [String: Any] { return try decodeLegacy(qwen) }
        return try decodeDirect(root)
    }

    /// 直连扁平形状：单个月度窗口。
    private static func decodeDirect(_ root: [String: Any]) throws -> QwenPlan {
        guard let usedNumber = root["used_percent"] as? NSNumber,
              !(root["used_percent"] is Bool) else { throw DecodeError.invalidWindow }
        let used = usedNumber.doubleValue
        guard used.isFinite, (0...100).contains(used) else { throw DecodeError.invalidWindow }
        var limit: Double?
        if let limitNumber = root["monthly_limit"] as? NSNumber {
            let value = limitNumber.doubleValue
            guard value.isFinite, value > 0 else { throw DecodeError.invalidWindow }
            limit = value
        }
        var resetAt: Date?
        if let resetText = root["reset_at"] as? String {
            guard let date = parseISO8601(resetText) else { throw DecodeError.invalidReset }
            resetAt = date
        } else if root["reset_at"] != nil {
            throw DecodeError.invalidReset
        }
        let window = QwenPlanWindow(key: "monthly",
                                    label: "月度 Credits",
                                    limit: limit,
                                    usedPercent: used,
                                    resetAt: resetAt,
                                    unit: root["unit"] as? String ?? "Credits")
        var observedAt: Date?
        if let text = root["observed_at"] as? String { observedAt = parseISO8601(text) }
        return QwenPlan(plan: root["plan"] as? String ?? "",
                        status: root["data_status"] as? String ?? "",
                        source: "direct-api",
                        note: root["sync_status"] as? String ?? "",
                        observedAt: observedAt,
                        maxAge: 5400,
                        windows: [window])
    }

    /// 旧遥测形状：ok 必须为 true、windows 非空、used_percent ∈ 0...100、
    /// limit 可选但出现必须 > 0、reset_at 可选但出现必须是带时区的 ISO8601。
    private static func decodeLegacy(_ qwen: [String: Any]) throws -> QwenPlan {
        guard (qwen["ok"] as? Bool) == true else { throw DecodeError.notOK }
        guard let rawWindows = qwen["windows"] as? [[String: Any]], !rawWindows.isEmpty else {
            throw DecodeError.emptyWindows
        }
        var windows: [QwenPlanWindow] = []
        for raw in rawWindows {
            guard let usedNumber = raw["used_percent"] as? NSNumber,
                  !(raw["used_percent"] is Bool) else { throw DecodeError.invalidWindow }
            let used = usedNumber.doubleValue
            guard used.isFinite, (0...100).contains(used) else { throw DecodeError.invalidWindow }
            var limit: Double?
            if let limitNumber = raw["limit"] as? NSNumber {
                let value = limitNumber.doubleValue
                guard value.isFinite, value > 0 else { throw DecodeError.invalidWindow }
                limit = value
            }
            var resetAt: Date?
            if let resetText = raw["reset_at"] as? String {
                guard let date = parseISO8601(resetText) else { throw DecodeError.invalidReset }
                resetAt = date
            } else if raw["reset_at"] != nil {
                throw DecodeError.invalidReset
            }
            windows.append(QwenPlanWindow(
                key: raw["key"] as? String ?? "monthly",
                label: raw["label"] as? String ?? "",
                limit: limit,
                usedPercent: used,
                resetAt: resetAt,
                unit: raw["unit"] as? String ?? "Credits"))
        }
        var observedAt: Date?
        if let number = qwen["observed_at"] as? NSNumber, !(qwen["observed_at"] is Bool) {
            let seconds = number.doubleValue
            if seconds.isFinite, seconds > 0 { observedAt = Date(timeIntervalSince1970: seconds) }
        }
        var maxAge: TimeInterval = 5400
        if let number = qwen["max_age_seconds"] as? NSNumber, !(qwen["max_age_seconds"] is Bool) {
            let value = number.doubleValue
            if value.isFinite, value > 0 { maxAge = value }
        }
        return QwenPlan(plan: qwen["plan"] as? String ?? "",
                        status: qwen["status"] as? String ?? "",
                        source: qwen["source"] as? String ?? "",
                        note: qwen["note"] as? String ?? "",
                        observedAt: observedAt,
                        maxAge: maxAge,
                        windows: windows)
    }

    /// reset_at 形如 2026-12-16T00:00:00.000+08:00；必须带时区，缺时区按非法处理。
    private static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// 直连 status.jimmycloud.cc 只读用量接口（Bearer 只读令牌，存 macOS 钥匙串）。
/// 不依赖 Chrome、不弹窗、不读 Cookie。所有公开操作与回调在主线程；并发合并；
/// 失败保留上次好值（持久化到 UserDefaults），过旧才标 stale。
final class JimmyCloudPlanProvider {
    typealias Completion = (QwenPlan?, String?, Bool) -> Void

    private var lastGood: QwenPlan?
    /// 多账号列表（accounts 端点）；旧扁平形状时=[lastGood]。第一个账号供 Touch Bar/单卡兼容。
    private(set) var accounts: [QwenPlan] = []
    private var cachedAt: Date?
    private var cooldownUntil: Date?
    private var lastError: String?
    private var generation: UInt64 = 0
    private var inFlight = false
    private var completions: [Completion] = []
    private let fetchQueue = DispatchQueue(label: "app.quotastrip.jimmycloud.direct", qos: .utility)
    private static let storeKey = "app.quotastrip.qwenplan.last.v1"
    private static let storeDateKey = "app.quotastrip.qwenplan.lastAt.v1"
    private static let endpoint = URL(string: "https://status.jimmycloud.cc/api/v1/usage/accounts")!
    private static let keychainService = "app.quotastrip.qwen-usage"
    private static let keychainAccount = "usage-token"

    init() {
        // 持久化上次好值：重启 app / 断网时仍显示上次数据（过旧才标过期）。
        if let data = UserDefaults.standard.data(forKey: Self.storeKey) {
            if let list = try? QwenPlan.decodeAccounts(data) {
                accounts = list
                lastGood = list.first
            } else if let plan = try? QwenPlan.decode(data) {
                accounts = [plan]
                lastGood = plan
            }
            cachedAt = UserDefaults.standard.object(forKey: Self.storeDateKey) as? Date
        }
    }

    func fetch(force: Bool = false, completion: @escaping Completion) {
        precondition(Thread.isMainThread)
        if inFlight { completions.append(completion); return }
        let now = Date()
        if let until = cooldownUntil, until > now {
            completion(lastGood, lastError, true)
            return
        }
        if !force, let plan = lastGood, let at = cachedAt, now.timeIntervalSince(at) < 60 {
            completion(plan, nil, plan.isStale(at: now))
            return
        }
        completions.append(completion)
        inFlight = true
        let version = generation
        fetchQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.runDirect()
            DispatchQueue.main.async {
                guard version == self.generation else { return }
                self.inFlight = false
                let callbacks = self.completions
                self.completions.removeAll()
                switch result {
                case .data(let data):
                    do {
                        // 新端点返回数组；旧服务端仍返回扁平时退回单账号解码。
                        let list: [QwenPlan]
                        if let decoded = try? QwenPlan.decodeAccounts(data) {
                            list = decoded
                        } else {
                            list = [try QwenPlan.decode(data)]
                        }
                        guard let plan = list.first else { throw QwenPlan.DecodeError.emptyAccounts }
                        self.accounts = list
                        self.lastGood = plan
                        self.cachedAt = Date()
                        UserDefaults.standard.set(data, forKey: Self.storeKey)
                        UserDefaults.standard.set(self.cachedAt, forKey: Self.storeDateKey)
                        self.cooldownUntil = nil
                        self.lastError = nil
                        let stale = plan.isStale()
                        let message = stale ? L("Plan data is out of date.", "千问额度数据已过期。") : nil
                        callbacks.forEach { $0(plan, message, stale) }
                    } catch {
                        self.deliverFailure(L("Qwen plan returned invalid data.", "千问额度数据无效。"),
                                            retryAfter: 60, callbacks: callbacks)
                    }
                case .failed(let message, let retryAfter):
                    self.deliverFailure(message, retryAfter: retryAfter, callbacks: callbacks)
                }
            }
        }
    }

    private func deliverFailure(_ message: String, retryAfter: TimeInterval, callbacks: [Completion]) {
        lastError = message
        cooldownUntil = Date().addingTimeInterval(max(60, retryAfter))
        let plan = lastGood
        callbacks.forEach { $0(plan, message, true) }
    }

    private enum DirectOutcome {
        case data(Data)
        case failed(String, TimeInterval)
    }

    /// 钥匙串取只读令牌；缺失则失败（保留上次好值）。
    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// 在 fetchQueue 上同步 GET；按文档处理 200/401/405/503 与网络错误。
    private static func runDirect() -> DirectOutcome {
        guard let token = readToken() else {
            return .failed(L("Qwen read-only token missing from Keychain.",
                             "钥匙串中没有千问只读令牌。"), 300)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: DirectOutcome = .failed(L("Qwen usage request failed.", "千问用量请求失败。"), 60)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failed(L("Network error reaching Qwen usage API.", "连接千问用量接口网络错误。"), 60)
                _ = error
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failed(L("Qwen usage API returned no HTTP response.", "千问用量接口无 HTTP 响应。"), 60)
                return
            }
            switch http.statusCode {
            case 200:
                guard let data, !data.isEmpty else {
                    outcome = .failed(L("Qwen usage API returned empty body.", "千问用量接口返回空内容。"), 60)
                    return
                }
                outcome = .data(data)
            case 401:
                outcome = .failed(L("Qwen token rejected (401). Check the read-only token.",
                                    "千问令牌被拒绝（401），请检查只读令牌。"), 300)
            case 405:
                outcome = .failed(L("Qwen usage API requires GET (405).", "千问用量接口要求 GET（405）。"), 300)
            case 503:
                let retry = (http.value(forHTTPHeaderField: "Retry-After") as NSString?)?.doubleValue ?? 60
                outcome = .failed(L("Qwen usage snapshot unavailable (503).", "千问用量快照暂不可用（503）。"),
                                  max(60, retry))
            default:
                outcome = .failed(L("Qwen usage API HTTP \(http.statusCode).", "千问用量接口 HTTP \(http.statusCode)。"), 60)
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return outcome
    }
}
