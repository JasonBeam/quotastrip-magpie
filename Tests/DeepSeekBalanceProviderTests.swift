import Foundation
func L(_ en: String, _ zh: String) -> String { en }

final class MockDeepSeekProtocol: URLProtocol {
    static var status = 200
    static var headers: [String: String] = [:]
    static var payload = Data()
    static var requests = 0
    static var delay: TimeInterval = 0
    static var stopped = Set<ObjectIdentifier>()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let status = Self.status, headers = Self.headers, payload = Self.payload
        precondition(request.url?.absoluteString == "https://api.deepseek.com/user/balance")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-only")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) {
            guard !Self.stopped.contains(ObjectIdentifier(self)) else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: payload)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.stopped.insert(ObjectIdentifier(self)) }
}

@main struct Tests {
    static let valid = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"10.25","granted_balance":"0","topped_up_balance":"10.25"},{"currency":"USD","total_balance":"1e1","granted_balance":".5","topped_up_balance":"+0.0"}]}"#
    static func wait(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done(), "Test timed out")
    }
    static func main() throws {
        let value = try JSONDecoder().decode(DeepSeekBalance.self, from: Data(valid.utf8))
        try value.validate()
        precondition(value.balance_infos.count == 2)
        for invalid in ["-1", "NaN", "Infinity", "", "1abc", " 1", "1 ", "1,000", "1\n", "1e9999"] {
            let entry = DeepSeekBalance.Entry(currency: "CNY", total_balance: invalid, granted_balance: "0", topped_up_balance: "0")
            do { try entry.validate(); preconditionFailure("Accepted invalid entry: \(invalid)") } catch {}
        }
        for invalidJSON in [valid.replacingOccurrences(of: "CNY", with: "EUR"), #"{"is_available":true,"balance_infos":[]}"#, #"{"is_available":true}"#, valid.replacingOccurrences(of: "\"10.25\"", with: "10.25")] {
            precondition((try? JSONDecoder().decode(DeepSeekBalance.self, from: Data(invalidJSON.utf8))) == nil)
        }
        MockDeepSeekProtocol.payload = Data(valid.utf8)
        MockDeepSeekProtocol.delay = 0.02
        let provider = DeepSeekBalanceProvider()
        var calls = 0
        for _ in 0..<2 {
            provider.fetch { balance, error, stale in
                precondition(Thread.isMainThread && balance != nil && error == nil && !stale)
                calls += 1
            }
        }
        wait { calls == 2 }
        precondition(MockDeepSeekProtocol.requests == 1, "Overlapping calls weren't coalesced")
        provider.fetch { balance, error, stale in precondition(balance != nil && error == nil && !stale); calls += 1 }
        precondition(calls == 3 && MockDeepSeekProtocol.requests == 1, "Cache miss")
        MockDeepSeekProtocol.status = 429
        MockDeepSeekProtocol.headers = ["Retry-After": "120"]
        provider.fetch(force: true) { balance, error, stale in precondition(balance != nil && error != nil && stale); calls += 1 }
        wait { calls == 4 }
        precondition(provider.cooldownUntil!.timeIntervalSinceNow > 115)
        provider.fetch(force: true) { balance, error, stale in precondition(balance != nil && error != nil && stale); calls += 1 }
        precondition(calls == 5 && MockDeepSeekProtocol.requests == 2, "Force bypassed cooldown")

        let dateProvider = DeepSeekBalanceProvider()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        MockDeepSeekProtocol.status = 503
        MockDeepSeekProtocol.headers = ["Retry-After": formatter.string(from: Date().addingTimeInterval(180))]
        var dateDone = false
        dateProvider.fetch { balance, error, stale in precondition(balance == nil && error != nil && stale); dateDone = true }
        wait { dateDone }
        precondition(dateProvider.cooldownUntil!.timeIntervalSinceNow > 170)

        let oversizedProvider = DeepSeekBalanceProvider()
        MockDeepSeekProtocol.status = 200
        MockDeepSeekProtocol.headers = [:]
        MockDeepSeekProtocol.payload = Data(repeating: 65, count: 256 * 1024 + 1)
        var oversizedDone = false
        oversizedProvider.fetch { balance, error, stale in precondition(balance == nil && error != nil && stale); oversizedDone = true }
        wait { oversizedDone }

        let generationProvider = DeepSeekBalanceProvider()
        MockDeepSeekProtocol.payload = Data(valid.utf8)
        MockDeepSeekProtocol.delay = 0.1
        var generationCalls = 0
        generationProvider.fetch { balance, error, stale in precondition(balance == nil && error == "Changed" && !stale); generationCalls += 1 }
        generationProvider.invalidate(message: "Changed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(generationCalls == 1, "Old generation completed after invalidation")

        // Directly exercise redirect refusal without making any external connection.
        let transport = DeepSeekBalanceRequest()
        let source = URL(string: "https://api.deepseek.com/user/balance")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: source)
        var redirectRefused = false
        transport.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.org/"])!, newRequest: URLRequest(url: URL(string: "https://example.org/")!)) { redirectRefused = $0 == nil }
        precondition(redirectRefused)
        session.invalidateAndCancel()
        print("PASS: validation, shared requests, TTL cache, stale errors, force cooldown, Retry-After seconds/date, 256KiB limit, generation cancellation, redirect refusal; no Keychain access")
    }
}
