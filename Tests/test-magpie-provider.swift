import Foundation

func L(_ en: String, _ zh: String) -> String { zh }

/// Magpie 只读额度解码 / manifest 校验 / 兜底行为的合成测试。
/// 网络部分用本机 mock HTTP server（127.0.0.1 临时端口），不触外网、不读凭据。
@main
struct MagpieTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(name)") }
    }

    static let quotasSample = """
    {"data":[
      {"provider":"codex","name":"Codex","kind":"subscription","plan":"plus","user":"user@example.com",
       "windows":[
         {"name":"5 hours","used":0,"remaining":100,"resetsAt":"2026-11-26T19:47:37+08:00"},
         {"name":"7 days","used":85,"remaining":15,"resetsAt":"2026-11-27T15:21:52+08:00"},
         {"name":"Image generation","used":0,"remaining":100,"display":"Unknown","text":true,"lane":"images"}],
       "balance":"1331.4 credits","readAt":"2026-11-26T14:47:40.123456+08:00",
       "resets":{"count":1,"until":"2026-12-26T06:15:44.869715Z","each":[{"until":"2026-12-26T06:15:44.869715Z","id":"RateLimitResetCredit_x"}]}},
      {"provider":"qwen","name":"Qwen","kind":"plan","plan":"Token Plan","windows":[],
       "error":"this plan's usage is told only to a sign-in on the Qwen AI platform: sign in in Qwen's settings",
       "lastServedAt":"2026-11-26T06:35:27.147572Z","last":true},
      {"provider":"deepseek","name":"DeepSeek","kind":"balance","windows":[],"balance":"¥14.71"}],
     "object":"list"}
    """

    static let accountsSample = """
    {"data":[
      {"provider":"deepseek","providerName":"DeepSeek","id":"110db8f084","pin":"deepseek/110db8f084","kind":"key","label":"sk-…masked","on":true},
      {"provider":"codex","providerName":"Codex","id":"f10d3b8eece56ed4","kind":"account","user":"user@example.com","plan":"plus","on":true}],
     "object":"list"}
    """

    static func decodeTests() {
        let quotas = try! MagpieDecode.decodeQuotas(Data(quotasSample.utf8))
        expect(quotas.count == 3, "three providers")
        let codex = quotas[0]
        expect(codex.provider == "codex" && codex.kind == "subscription" && codex.plan == "plus", "codex identity")
        expect(codex.windows.count == 3, "codex three windows")
        expect(codex.window(named: "5 hours")?.remaining == 100, "5h remaining 100")
        expect(codex.window(named: "7 days")?.used == 85, "7d used 85")
        let utc = ISO8601DateFormatter(); utc.formatOptions = [.withInternetDateTime]
        expect(codex.window(named: "5 hours")?.resetsAt == utc.date(from: "2026-11-26T11:47:37Z"), "resetsAt keeps +08:00")
        expect(codex.window(named: "Image generation")?.display == "Unknown", "display Unknown preserved")
        expect(codex.window(named: "Image generation")?.lane == "images", "lane images")
        expect(codex.balance == "1331.4 credits", "balance string verbatim")
        expect(codex.resetsCount == 1, "resets count 1")
        expect(codex.error == nil && codex.isUsable, "codex usable")
        expect(codex.readAt != nil, "readAt parsed with fractional seconds")

        let qwen = quotas[1]
        expect(qwen.windows.isEmpty, "qwen empty windows")
        expect(qwen.error?.contains("sign in") == true, "qwen error verbatim")
        expect(!qwen.isUsable, "qwen not usable with error")
        expect(qwen.lastServedAt != nil, "lastServedAt Z parsed")

        let deepseek = quotas[2]
        expect(deepseek.balance == "¥14.71", "deepseek balance string")
        expect(!deepseek.isUsable, "balance-only not usable as windows")

        // 宽松缺省：字段缺失给默认，不抛。
        let minimal = try! MagpieDecode.decodeQuotas(Data(#"{"data":[{"provider":"x"}]}"#.utf8))
        expect(minimal.count == 1 && minimal[0].windows.isEmpty && minimal[0].resetsCount == 0, "minimal entry defaults")
        expect(minimal[0].name == "" && minimal[0].balance == nil, "minimal nil fields")

        // error 空串按无 error。
        let emptyError = try! MagpieDecode.decodeQuotas(Data(#"{"data":[{"provider":"x","error":"","windows":[{"name":"w"}]}]}"#.utf8))
        expect(emptyError[0].error == nil && emptyError[0].isUsable, "empty error treated as none")

        // 非法形状拒收。
        for bad in ["[]", "{}", #"{"data":"no"}"#, #"{"data":[{}]}"#] {
            do {
                _ = try MagpieDecode.decodeQuotas(Data(bad.utf8))
                fatalError("FAIL: bad shape accepted: \(bad)")
            } catch { checks += 1 }
        }
        // 超大拒收。
        do {
            _ = try MagpieDecode.decodeQuotas(Data(count: 512 * 1024 + 1))
            fatalError("FAIL: oversized accepted")
        } catch { checks += 1 }

        // accounts：掩码 label 不进模型。
        let accounts = try! MagpieDecode.decodeAccounts(Data(accountsSample.utf8))
        expect(accounts.count == 2, "two accounts")
        expect(accounts[0].provider == "deepseek" && accounts[0].kind == "key" && accounts[0].on, "deepseek key on")
        expect(accounts[1].plan == "plus" && accounts[1].user == "user@example.com", "codex account plan/user")

        // manifest 校验。
        expect(MagpieDecode.isManifest(Data(#"{"name":"magpie","version":"0.1.4823"}"#.utf8)), "manifest accepted")
        expect(!MagpieDecode.isManifest(Data(#"{"name":"other"}"#.utf8)), "wrong name rejected")
        expect(!MagpieDecode.isManifest(Data("not json".utf8)), "non-JSON rejected")

        // 日期缺时区拒收。
        expect(MagpieDecode.parseDate("2026-11-26T19:47:37") == nil, "naive datetime rejected")
        expect(MagpieDecode.parseDate(nil) == nil, "nil date")
    }

    /// 本机 mock server：一次 listen，按路径返回固定 JSON；port 0 自动分配。
    final class MockServer {
        let port: UInt16
        private let serverSocket: Int32
        private var routes: [String: (Int, String)] = [:]
        private let queue = DispatchQueue(label: "mock.magpie", attributes: .concurrent)
        private var running = true

        init(routes: [String: (Int, String)]) {
            self.routes = routes
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(sock, 8) == 0 else { fatalError("mock bind failed") }
            var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
            }
            serverSocket = sock
            port = UInt16(bigEndian: bound.sin_port)
            queue.async { [weak self] in self?.serve() }
        }

        private func serve() {
            while running {
                let client = accept(serverSocket, nil, nil)
                if client < 0 { return }
                queue.async { [weak self] in self?.handle(client) }
            }
        }

        private func handle(_ client: Int32) {
            defer { close(client) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let readCount = read(client, &buffer, buffer.count)
            guard readCount > 0 else { return }
            let request = String(decoding: buffer[0..<readCount], as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let cleanPath = path.split(separator: "?").first.map(String.init) ?? path
            let (status, body) = routes[cleanPath] ?? (404, "{}")
            let reason = status == 200 ? "OK" : "Not Found"
            let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = response.withCString { write(client, $0, strlen($0)) }
        }

        func stop() {
            running = false
            close(serverSocket)
        }
    }

    static func networkTests() {
        let manifest = #"{"name":"magpie","version":"test","pid":1}"#
        let server = MockServer(routes: [
            "/": (200, manifest),
            "/v1/magpie/quotas": (200, quotasSample),
            "/v1/magpie/accounts": (200, accountsSample),
        ])
        defer { server.stop() }
        MagpieProvider.overrideOrigin = URL(string: "http://127.0.0.1:\(server.port)")
        defer { MagpieProvider.overrideOrigin = nil }

        let provider = MagpieProvider()
        var received: MagpieProvider.Snapshot?
        provider.fetch(force: true) { received = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        guard let snapshot = received else { fatalError("FAIL: no callback") }
        expect(snapshot.error == nil, "mock fetch no error")
        expect(snapshot.quotas.count == 3, "mock three quotas")
        expect(snapshot.accounts.count == 2, "mock two accounts")
        expect(snapshot.quota("codex")?.resetsCount == 1, "mock resets")
        expect(!snapshot.stale, "mock fresh not stale")

        // 缓存命中：60s 内第二次 fetch 不再触网（force=false）。
        var second: MagpieProvider.Snapshot?
        provider.fetch(force: false) { second = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        expect(second?.quotas.count == 3, "cached second fetch")

        // 兜底：指向空端口 → 失败冷却，保留 lastGood 标 stale，error 提示未运行。
        let dead = MagpieProvider()
        MagpieProvider.overrideOrigin = URL(string: "http://127.0.0.1:1")
        var failed: MagpieProvider.Snapshot?
        dead.fetch(force: true) { failed = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(25))
        expect(failed?.error != nil, "dead origin reports error")
        expect(failed?.quotas.isEmpty == false || failed?.error?.contains("未运行") == true, "dead origin message")

        // 非 magpie manifest（错误身份）拒收。
        let impostor = MockServer(routes: ["/": (200, #"{"name":"not-magpie"}"#)])
        defer { impostor.stop() }
        MagpieProvider.overrideOrigin = URL(string: "http://127.0.0.1:\(impostor.port)")
        let wrong = MagpieProvider()
        var wrongSnapshot: MagpieProvider.Snapshot?
        wrong.fetch(force: true) { wrongSnapshot = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        expect(wrongSnapshot?.error != nil, "impostor manifest rejected")
    }

    static func main() {
        // 测试进程不污染真实 UserDefaults：用独立 suite 前先清掉本测试键。
        UserDefaults.standard.removeObject(forKey: "app.quotastrip.magpie.last.v1")
        UserDefaults.standard.removeObject(forKey: "app.quotastrip.magpie.lastAt.v1")
        decodeTests()
        networkTests()
        activityTests()
        UserDefaults.standard.removeObject(forKey: "app.quotastrip.magpie.last.v1")
        UserDefaults.standard.removeObject(forKey: "app.quotastrip.magpie.lastAt.v1")
        print("magpie tests: \(checks) checks passed")
    }

    // MARK: 当前对话实时视图（requests 解码 + activity 挑选 + fetchActivity 兜底）

    static let requestsSample = """
    {"rows":[
      {"t":"2026-11-26T15:36:01.557654+08:00","agent":"codex","session":"s-live","model":"qwen4-max","served":"qwen4-max",
       "in":72658,"out":2309,"cache_read":0,"ms":34199,"ttft_ms":33000,"status":200},
      {"t":"2026-11-26T15:33:01.499+08:00","agent":"dsh","session":"s-log","model":"deepseek-flash","served":"deepseek-flash",
       "in":37698,"out":786,"cache_read":42240,"ms":0,"status":0,"source":"log"},
      {"t":"2026-11-26T15:30:00.000+08:00","agent":"magpie","session":"probe","model":"","in":0,"out":0,"cache_read":0,"ms":10,"status":200,"source":"probe"},
      {"t":"2026-11-26T15:29:00.000+08:00","agent":"codex","session":"s-old","model":"qwen4-max",
       "in":100,"out":50,"cache_read":100,"ms":1000,"status":499}],
     "total":4}
    """

    static func activityTests() {
        let rows = try! MagpieDecode.decodeRequests(Data(requestsSample.utf8))
        expect(rows.count == 4, "four request rows decoded")
        // 今日合计取 requests 响应的合并 series（网关+DSH日志，Magpie 已去重）。
        let merged = """
        {"rows":[],"series":[{"label":"Nov 26","input":14208124,"output":1177434,"cache_read":262782464}]}
        """
        let day = MagpieDecode.parseDate("2026-11-26T21:00:00+08:00")!
        expect(MagpieDecode.decodeUsageTodayTotal(Data(merged.utf8), now: day) == 14208124 + 1177434 + 262782464,
               "today total = merged series in+out+cache")
        expect(MagpieDecode.decodeUsageTodayTotal(Data(#"{"rows":[],"series":[]}"#.utf8), now: day) == nil,
               "no matching day → nil (fallback to DSH)")
        let live = rows[0]
        expect(live.hasTiming && live.status == 200, "live row timed")
        expect(abs((live.tokensPerSecond ?? 0) - 2309.0 / ((34199 - 33000) / 1000.0)) < 0.001, "tok/s = out / decode seconds (DSH 口径)")
        expect(live.cacheHitPercent == 0, "zero cache → 0% hit")
        let log = rows[1]
        expect(!log.hasTiming && log.tokensPerSecond == nil, "log row (ms=0) has no tok/s")
        expect(abs((log.cacheHitPercent ?? 0) - 42240.0 / (37698 + 42240) * 100) < 0.001, "cache hit = read/(in+read)")
        expect(log.totalTokens == 37698 + 786 + 42240, "session tokens = in+out+cache")
        // 无 ttft 的行不给速率（不能拿整请求时长冒充解码时长）。
        let noTtft = try! MagpieDecode.decodeRequests(Data(#"{"rows":[{"t":"2026-11-26T15:00:00+08:00","agent":"codex","session":"x","out":10,"ms":1000,"status":200}]}"#.utf8))
        expect(noTtft[0].tokensPerSecond == nil, "row without ttft has no tok/s")

        // 坏形状拒收 / 坏行跳过。
        do {
            _ = try MagpieDecode.decodeRequests(Data("{}".utf8))
            fatalError("FAIL: bad requests shape accepted")
        } catch { checks += 1 }
        let partial = try! MagpieDecode.decodeRequests(Data(#"{"rows":[{"agent":"codex"},{"t":"2026-11-26T15:00:00+08:00","agent":"dsh","session":"x"}]}"#.utf8))
        expect(partial.count == 1, "row without t skipped")

        // activity：取最新真实对话行；probe/magpie 忽略；499 不算速率。
        let now = MagpieDecode.parseDate("2026-11-26T15:36:10+08:00")!
        let activity = MagpieProvider.activity(from: rows, now: now)
        expect(activity.model == "qwen4-max" && activity.session == "s-live", "latest conversation row wins")
        expect(activity.sessionTokens == 74967, "session tokens from latest row")
        expect(activity.tokensPerSecond != nil, "fresh timed row gives tok/s")
        // 超过 120s：不给速率，但保留模型/缓存。
        let later = MagpieProvider.activity(from: rows, now: now.addingTimeInterval(600))
        expect(later.tokensPerSecond == nil && later.model == "qwen4-max", "stale rate dropped, model kept")
        // 只有日志行（DSH 场景）：无 tok/s，有缓存。
        let logOnly = MagpieProvider.activity(from: [rows[1]], now: now)
        expect(logOnly.tokensPerSecond == nil && logOnly.sessionCacheHit != nil, "log-only session: cache but no rate")
        expect(MagpieProvider.activity(from: [], now: now).model == nil, "empty rows → empty activity")

        // fetchActivity：mock 成功 → 缓存命中 → 死端口保留上次好值标 stale。
        let server = MockServer(routes: [
            "/": (200, #"{"name":"magpie","version":"test"}"#),
            "/v1/magpie/usage/requests": (200, requestsSample),
        ])
        MagpieProvider.overrideOrigin = URL(string: "http://127.0.0.1:\(server.port)")
        let provider = MagpieProvider()
        var got: MagpieProvider.Activity?
        provider.fetchActivity(force: true) { got = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        expect(got?.session == "s-live" && got?.error == nil, "mock activity fetched")
        server.stop()
        MagpieProvider.overrideOrigin = URL(string: "http://127.0.0.1:1")
        var degraded: MagpieProvider.Activity?
        provider.fetchActivity(force: true) { degraded = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(25))
        expect(degraded?.session == "s-live" && degraded?.stale == true, "dead origin keeps last good, marked stale")
        expect(degraded?.error != nil, "dead origin reports error")
        MagpieProvider.overrideOrigin = nil
    }
}
