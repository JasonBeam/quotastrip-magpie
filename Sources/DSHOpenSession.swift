import Foundation

/// Ask the local DSH usage plugin to reveal one conversation.
///
/// The harness exposes no deep link for a conversation — `dsh://open` only
/// focuses a window, and the selected conversation is client state. The plugin's
/// browser half, which does own `uiWorkspace`, polls a loopback route for the
/// conversation an outside surface wants and performs the switch. This type is
/// only the outside surface: a bounded, credential-free POST, no retries.
enum DSHOpenSession {
    /// Exact route registered by the plugin's server half.
    static let path = "api/usage-stats/open-session"

    /// How long one attempt may take before it is abandoned.
    static let timeout: TimeInterval = 4

    /// Body cap for the (tiny) JSON reply.
    static let maximumReplyBytes = 16 * 1024

    /// Last origin that accepted a request; discovery is a process scan, so reuse it.
    private static var lastOrigin: URL?

    /// Origin the balance provider already resolved, when the caller has one.
    static func remember(origin: URL?) {
        guard let origin = origin else { return }
        precondition(Thread.isMainThread)
        lastOrigin = origin
    }

    /// True when the reply is the plugin's success shape.
    static func accepted(_ data: Data) -> Bool {
        guard data.count <= maximumReplyBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = root["ok"] as? Bool else { return false }
        return ok
    }

    /// One request body, encoded without ever touching the clipboard or a keychain.
    static func body(sessionId: String) -> Data? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["id": trimmed], options: [])
    }

    /// Test seam: when set, discovery is skipped. Never assigned in the app.
    static var overrideOrigins: [URL]?

    /// Candidate origins, known-good first.
    static func origins() -> [URL] {
        if let override = overrideOrigins { return override }
        var list: [URL] = []
        if let known = lastOrigin { list.append(known) }
        for candidate in DSHLocalDiscovery.discover() where !list.contains(candidate) { list.append(candidate) }
        return list
    }

    /// Post the conversation to the first origin that accepts it.
    /// - Parameters:
    ///   - sessionId: conversation id as the usage records report it.
    ///   - completion: `nil` on success, else a short reason for the menu.
    static func request(sessionId: String, completion: @escaping (String?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { request(sessionId: sessionId, completion: completion) }
            return
        }
        guard let body = body(sessionId: sessionId) else {
            completion("对话 ID 无效")
            return
        }
        let candidates = origins()
        guard !candidates.isEmpty else {
            completion("未找到本机 DSH，无法跳转对话")
            return
        }
        attempt(candidates, index: 0, body: body, completion: completion)
    }

    private static func attempt(_ origins: [URL], index: Int, body: Data, completion: @escaping (String?) -> Void) {
        guard index < origins.count else {
            completion("DSH 插件未响应，无法跳转对话")
            return
        }
        let origin = origins[index]
        guard let url = URL(string: path, relativeTo: origin) else {
            attempt(origins, index: index + 1, body: body, completion: completion)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let task = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
        task.dataTask(with: request) { data, response, error in
            task.finishTasksAndInvalidate()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let accepted = error == nil && (200...299).contains(status) && accepted(data ?? Data())
            DispatchQueue.main.async {
                if accepted {
                    lastOrigin = origin
                    completion(nil)
                } else {
                    attempt(origins, index: index + 1, body: body, completion: completion)
                }
            }
        }.resume()
    }

    /// A redirect would move the request somewhere this app never agreed to talk to.
    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}