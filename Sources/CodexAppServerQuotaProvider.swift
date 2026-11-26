import Foundation

/// Live account reader. Invalid/incomplete results intentionally return nil so the
/// caller can use the local session reader without mixing snapshots or buckets.
final class CodexAppServerQuotaProvider {
    private final class Pending { let semaphore = DispatchSemaphore(value: 0); var message: [String: Any]? }
    private let codexURL: URL
    private let queue = DispatchQueue(label: "app.quotastrip.app-server")
    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var error: Pipe?
    private var buffer = ""
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var initialized = false

    init() { codexURL = Self.discoverCodexURL() }

    /// Used by the menu's explicit refresh: discard a potentially stuck stdio session.
    func reset() {
        queue.sync { stop() }
    }

    func latestQuota(timeout: TimeInterval) -> QuotaService? {
        queue.sync {
            // The bundled app-server occasionally misses its first cold-start request.
            // Retry once with a fresh process; each attempt is still short and runs off the UI thread.
            for _ in 0..<2 {
                // A warmed stdio server responds quickly, but a new bundled server needs
                // several seconds to start. This remains on QuotaFetcher's utility queue.
                let coldStart = process?.isRunning != true
                guard startIfNeeded() else { continue }
                let requestTimeout = coldStart ? max(timeout, 8) : timeout
                if !initialized {
                    _ = request(method: "initialize", params: [
                        "clientInfo": ["name": "quotastrip", "version": "1.0"],
                        "capabilities": ["experimentalApi": true, "optOutNotificationMethods": []],
                    ], timeout: min(requestTimeout, 0.5))
                    initialized = true
                }
                if let message = request(method: "account/rateLimits/read", params: NSNull(), timeout: requestTimeout),
                   let result = message["result"] as? [String: Any], let quota = parse(result) {
                    return quota
                }
                stop()
            }
            return nil
        }
    }

    private func startIfNeeded() -> Bool {
        if process?.isRunning == true, input != nil { return true }
        stop()
        let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = codexURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.accept(data) }
        }
        // Drain warnings so app-server cannot become blocked by stderr output.
        error.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        do { try process.run() } catch { return false }
        self.process = process; self.input = input; self.output = output; self.error = error
        buffer = ""; initialized = false
        return true
    }

    private func stop() {
        output?.fileHandleForReading.readabilityHandler = nil
        error?.fileHandleForReading.readabilityHandler = nil
        input?.fileHandleForWriting.closeFile()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; error = nil
        buffer = ""; pending.removeAll(); initialized = false
    }

    private func request(method: String, params: Any, timeout: TimeInterval) -> [String: Any]? {
        guard let input else { return nil }
        let id = nextID; nextID += 1
        let wait = Pending()
        lock.lock(); pending[id] = wait; lock.unlock()
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A); input.fileHandleForWriting.write(data)
        let result = wait.semaphore.wait(timeout: .now() + timeout)
        lock.lock(); let message = wait.message; pending[id] = nil; lock.unlock()
        return result == .success ? message : nil
    }

    private func accept(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        buffer.append(text)
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...end)
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (message["id"] as? NSNumber)?.intValue ?? Int("\(message["id"] ?? "")"),
                  let wait = pending[id] else { continue }
            wait.message = message; wait.semaphore.signal()
        }
    }

    private func parse(_ result: [String: Any]) -> QuotaService? {
        // Strictly select the one intended bucket; no generic result.rateLimits fallback.
        guard let buckets = result["rateLimitsByLimitId"] as? [String: Any],
              let codex = buckets["codex"] as? [String: Any], codex["limitId"] as? String == "codex",
              let five = window(codex["primary"] as? [String: Any], minutes: 300),
              let week = window(codex["secondary"] as? [String: Any], minutes: 10_080) else { return nil }
        return QuotaService(ok: true, stale: false, five: five, week: week, attention: false, source: "app-server")
    }

    private func window(_ raw: [String: Any]?, minutes: Int) -> QuotaWindow? {
        guard let raw, int(raw["windowDurationMins"]) == minutes,
              let used = number(raw["usedPercent"]), used.isFinite,
              let reset = number(raw["resetsAt"]), reset > Date().timeIntervalSince1970 else { return nil }
        return QuotaWindow(pct: 100 - min(max(used, 0), 100), reset: reset)
    }

    private func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? Int("\(value ?? "")") }
    private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? Double("\(value ?? "")") }

    private static func discoverCodexURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            // ChatGPT 154+ bundles the CLI in codex-cli instead of Resources/codex.
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
        ]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: paths[0])
    }
}
