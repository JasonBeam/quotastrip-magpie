import Foundation
import Security

/// Official balance payload. Amounts remain strings to preserve the API's precision.
struct DeepSeekBalance: Decodable {
    struct Entry: Decodable {
        let currency: String
        let total_balance: String
        let granted_balance: String
        let topped_up_balance: String

        func validate() throws {
            guard currency == "CNY" || currency == "USD" else { throw ValidationError.invalidCurrency }
            for amount in [total_balance, granted_balance, topped_up_balance] {
                // Decimal(string:) alone accepts numeric prefixes; require the entire string.
                guard amount.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#,
                                   options: .regularExpression) != nil,
                      let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")),
                      !value.isNaN, value >= 0 else { throw ValidationError.invalidAmount }
            }
        }
    }

    enum ValidationError: Error { case emptyBalances, invalidCurrency, invalidAmount }
    let is_available: Bool
    let balance_infos: [Entry]

    private enum CodingKeys: String, CodingKey { case is_available, balance_infos }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        is_available = try container.decode(Bool.self, forKey: .is_available)
        balance_infos = try container.decode([Entry].self, forKey: .balance_infos)
        try validate()
    }

    /// Available without a provider or Keychain, for standalone validation tests.
    func validate() throws {
        guard !balance_infos.isEmpty else { throw ValidationError.emptyBalances }
        try balance_infos.forEach { try $0.validate() }
    }
}

/// All public operations and all completions run on the main thread.
/// Concurrent fetch callers share one request. `force` skips only successful cache TTL,
/// never a failed-request cooldown. Errors return the previous snapshot with stale=true.
final class DeepSeekBalanceProvider {
    typealias Completion = (DeepSeekBalance?, String?, Bool) -> Void

    private static let service = "app.quotastrip.deepseek"
    private static let account = "api-key"
    private var cachedBalance: DeepSeekBalance?
    private var cachedAt: Date?
    private var cooldownUntil: Date?
    private var lastError: String?
    private var generation: UInt64 = 0
    private var request: DeepSeekBalanceRequest?
    private var completions: [Completion] = []

    private enum StorageError: LocalizedError {
        case invalidKey, keychain
        var errorDescription: String? {
            switch self {
            case .invalidKey: return L("Enter a valid DeepSeek API key.", "请输入有效的 DeepSeek API 密钥。")
            case .keychain: return L("Unable to access the DeepSeek API key in Keychain.", "无法访问钥匙串中的 DeepSeek API 密钥。")
            }
        }
    }

    var hasAPIKey: Bool {
        precondition(Thread.isMainThread)
        return (try? readAPIKey()) != nil
    }

    func saveAPIKey(_ value: String) throws {
        precondition(Thread.isMainThread)
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validKey(key), let data = key.data(using: .utf8) else { throw StorageError.invalidKey }
        let query = Self.keyQuery
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StorageError.keychain }
        } else if status != errSecSuccess { throw StorageError.keychain }
        invalidate(message: L("DeepSeek API key changed. Refresh to load the balance.", "DeepSeek API 密钥已更改，请刷新余额。"))
    }

    func removeAPIKey() throws {
        precondition(Thread.isMainThread)
        let status = SecItemDelete(Self.keyQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain }
        invalidate(message: setupMessage)
    }

    func fetch(force: Bool = false, completion: @escaping Completion) {
        precondition(Thread.isMainThread)
        if request != nil { completions.append(completion); return }
        let now = Date()
        if let until = cooldownUntil, until > now {
            completion(cachedBalance, lastError, true)
            return
        }
        let key: String
        do {
            guard let stored = try readAPIKey() else {
                completion(nil, setupMessage, false)
                return
            }
            key = stored
        } catch {
            fail(message: L("Unable to read the DeepSeek API key. Check Keychain access.", "无法读取 DeepSeek API 密钥，请检查钥匙串访问权限。"), retryAfter: 60, completion: completion)
            return
        }
        if !force, let balance = cachedBalance, let date = cachedAt, now.timeIntervalSince(date) < 60 {
            completion(balance, nil, false)
            return
        }
        completions.append(completion)
        let version = generation
        let transport = DeepSeekBalanceRequest()
        request = transport
        transport.start(key: key) { [weak self] result in
            guard let self = self, version == self.generation else { return }
            self.request = nil
            let callbacks = self.completions
            self.completions.removeAll()
            switch result {
            case .success(let data):
                do {
                    let balance = try JSONDecoder().decode(DeepSeekBalance.self, from: data)
                    self.cachedBalance = balance
                    self.cachedAt = Date()
                    self.cooldownUntil = nil
                    self.lastError = nil
                    callbacks.forEach { $0(balance, nil, false) }
                } catch {
                    self.deliverFailure(L("DeepSeek returned an invalid balance response.", "DeepSeek 返回的余额数据无效。"), retryAfter: 60, callbacks: callbacks)
                }
            case .failure(let failure):
                self.deliverFailure(failure.message, retryAfter: failure.retryAfter, callbacks: callbacks)
            }
        }
    }

    private var setupMessage: String { L("Set up a DeepSeek API key to view your balance.", "请设置 DeepSeek API 密钥以查看余额。") }
    private static var keyQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
    private static func validKey(_ key: String) -> Bool {
        // Restrict header values to visible ASCII; no assumptions about future key prefixes.
        !key.isEmpty && key.utf8.count <= 4096 && key.utf8.allSatisfy { $0 >= 33 && $0 <= 126 }
    }
    private func readAPIKey() throws -> String? {
        var query = Self.keyQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.keychain }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), Self.validKey(value) else { return nil }
        return value
    }
    private func invalidate(message: String) {
        generation &+= 1
        request?.cancel()
        request = nil
        cachedBalance = nil
        cachedAt = nil
        cooldownUntil = nil
        lastError = nil
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(nil, message, false) }
    }
    private func fail(message: String, retryAfter: TimeInterval, completion: @escaping Completion) {
        deliverFailure(message, retryAfter: retryAfter, callbacks: [completion])
    }
    private func deliverFailure(_ message: String, retryAfter: TimeInterval, callbacks: [Completion]) {
        lastError = message
        cooldownUntil = Date().addingTimeInterval(max(60, retryAfter))
        let balance = cachedBalance
        callbacks.forEach { $0(balance, message, true) }
    }
}

/// A streaming delegate enforces the size limit before retaining the response body.
/// Its session is intentionally not shared: credentials never follow redirects.
private final class DeepSeekBalanceRequest: NSObject, URLSessionDataDelegate {
    struct Failure: Error {
        let message: String
        let retryAfter: TimeInterval
    }
    private let limit = 256 * 1024
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var completion: ((Result<Data, Failure>) -> Void)?
    private var failure: Failure?

    func start(key: String, completion: @escaping (Result<Data, Failure>) -> Void) {
        self.completion = completion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        completion = nil
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = invalidResponse
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            let message: String
            switch http.statusCode {
            case 401, 403: message = L("DeepSeek API key is invalid or unauthorized. Update it in settings.", "DeepSeek API 密钥无效或未获授权，请在设置中更新。")
            case 429: message = L("DeepSeek is rate limiting requests. Please try again later.", "DeepSeek 请求过于频繁，请稍后重试。")
            case 500...599: message = L("DeepSeek is temporarily unavailable. Please try again later.", "DeepSeek 服务暂时不可用，请稍后重试。")
            default: message = L("DeepSeek could not load your balance. Please try again later.", "无法加载 DeepSeek 余额，请稍后重试。")
            }
            failure = Failure(message: message, retryAfter: max(60, Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After"))))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            failure = invalidResponse
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard data.count <= limit - body.count else {
            failure = invalidResponse
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callback = completion
        completion = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        self.task = nil
        if let failure = failure { callback?(.failure(failure)) }
        else if error != nil {
            callback?(.failure(Failure(message: L("Unable to connect to DeepSeek. Check your connection and try again.", "无法连接 DeepSeek，请检查网络后重试。"), retryAfter: 60)))
        } else { callback?(.success(body)) }
    }

    private var invalidResponse: Failure {
        Failure(message: L("DeepSeek returned an invalid or oversized response.", "DeepSeek 返回的数据无效或过大。"), retryAfter: 60)
    }

    /// Retry-After permits either seconds or an HTTP date (including legacy formats).
    private static func retryDelay(_ header: String?) -> TimeInterval {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 60 }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return min(seconds, Date.distantFuture.timeIntervalSinceNow)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(60, date.timeIntervalSinceNow) }
        }
        return 60
    }
}
