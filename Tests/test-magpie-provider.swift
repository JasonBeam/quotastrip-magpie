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
        // 本周合计：周一(11-23)至周四(11-26)；上周日(11-22)不计。
        let week = """
        {"rows":[],"series":[
          {"label":"Nov 22","time":"2026-11-22T00:00:00+08:00","input":500,"output":0,"cache_read":0},
          {"label":"Nov 23","time":"2026-11-23T00:00:00+08:00","input":100,"output":10,"cache_read":900},
          {"label":"Nov 26","time":"2026-11-26T00:00:00+08:00","input":200,"output":20,"cache_read":1800}]}
        """
        expect(MagpieDecode.decodeUsageWeekTotal(Data(week.utf8), now: day) == 1010 + 2020,
               "week total = Mon..today, last Sunday excluded")
        expect(MagpieDecode.decodeUsageWeekTotal(Data(#"{"rows":[],"series":[]}"#.utf8), now: day) == nil,
               "empty week → nil")

        // 近 7 天折线：11-20…11-26，缺的天补 0；完全无重叠 → nil。
        let recent = """
        {"rows":[],"series":[
          {"label":"Nov 19","time":"2026-11-19T00:00:00+08:00","input":9,"output":0,"cache_read":0},
          {"label":"Nov 20","time":"2026-11-20T00:00:00+08:00","input":100,"output":10,"cache_read":900},
          {"label":"Nov 26","time":"2026-11-26T00:00:00+08:00","input":200,"output":20,"cache_read":1800}]}
        """
        let trend = MagpieDecode.decodeUsageRecentDays(Data(recent.utf8), now: day)!
        expect(trend.labels.count == 7 && trend.labels.first == "2026-11-20" && trend.labels.last == "2026-11-26",
               "recent 7 days: old→new local dates")
        expect(trend.tokens == [1010, 0, 0, 0, 0, 0, 2020], "missing days are zero slots, Nov 19 excluded")
        expect(MagpieDecode.decodeUsageRecentDays(Data(#"{"rows":[],"series":[]}"#.utf8), now: day) == nil,
               "no overlap → nil (DSH fallback)")

        // 按日明细（tooltip 用）：calls/cost 一并解出；hour bucket 拒收。
        let heatSample = """
        {"bucket":"day","rows":[],"series":[
          {"label":"Oct 29","time":"2026-10-29T00:00:00+08:00","calls":7,"input":50,"output":5,"cache_read":45,"cost":0.5},
          {"label":"Nov 26","time":"2026-11-26T00:00:00+08:00","calls":223,"input":200,"output":20,"cache_read":1800,"cost":9.27}]}
        """
        let heat = MagpieDecode.decodeUsageHeatDays(Data(heatSample.utf8))!
        expect(heat.count == 2 && heat[0].label == "2026-10-29" && heat[1].label == "2026-11-26",
               "heat days: local date labels")
        expect(heat[1].tokens == 2020 && heat[1].calls == 223 && heat[1].cost == 9.27,
               "heat day carries tokens/calls/cost for tooltip")
        expect(MagpieDecode.decodeUsageHeatDays(Data(#"{"bucket":"day","rows":[],"series":[]}"#.utf8)) == nil,
               "empty heatmap → nil (card hidden)")
        expect(MagpieDecode.decodeUsageHeatDays(Data(#"{"period":"today","bucket":"hour","series":[{"label":"00"}]}"#.utf8)) == nil,
               "hourly bucket rejected as daily heatmap")
        expect(MagpieDecode.decodeFxRate(Data(#"{"rate":6.678179,"at":"2026-11-26T12:18:43+08:00"}"#.utf8)) == 6.678179,
               "fx rate decoded")
        expect(MagpieDecode.decodeFxRate(Data(#"{"rate":0}"#.utf8)) == nil, "zero fx rejected")

        // 整段热力：App 缓存（cut 前归档）+ 实时 series（cut 起）合并。
        let cacheSample = """
        {"key":"x","cut":"2026-11-25T00:00:00+08:00","since":"2025-11-24T00:00:00+08:00","days":[
          {"date":"2026-11-20","calls":10,"tokens":1000,"cost":1.0},
          {"date":"2026-11-24","calls":20,"tokens":2000,"cost":2.0},
          {"date":"2026-11-25","calls":99,"tokens":99999,"cost":9.0}]}
        """
        let cached = MagpieDecode.decodeHeatCache(Data(cacheSample.utf8))!
        expect(cached.days.count == 3, "heat cache days decoded")
        expect(cached.days["2026-11-24"]?.calls == 20 && cached.days["2026-11-24"]?.cost == 2.0,
               "cached day keeps calls/cost")
        expect(MagpieDecode.decodeHeatCache(Data(#"{"days":[]}"#.utf8)) == nil, "cache without cut rejected")
        let liveSeries = [MagpieDecode.HeatDay(label: "2026-11-25", tokens: 3000, calls: 30, cost: 3.0),
                          MagpieDecode.HeatDay(label: "2026-11-26", tokens: 4000, calls: 40, cost: 4.0)]
        let full = MagpieDecode.mergeHeatmap(cached: cached, series: liveSeries, now: day)!
        // 起点 = 最早数据 11-20（周五）所在周的周一 11-16；终点 11-26。
        expect(full.first?.label == "2026-11-16" && full.last?.label == "2026-11-26" && full.count == 11,
               "merged heat spans Monday-of-first-week .. today")
        func heatAt(_ label: String) -> MagpieDecode.HeatDay { full.first { $0.label == label }! }
        expect(heatAt("2026-11-20").tokens == 1000 && heatAt("2026-11-24").tokens == 2000, "cached days kept")
        expect(heatAt("2026-11-25").tokens == 3000 && heatAt("2026-11-25").calls == 30,
               "cut day comes from live series, not stale cache")
        expect(heatAt("2026-11-26").tokens == 4000 && heatAt("2026-11-16").tokens == 0, "live tail kept, gaps zero")
        let seriesOnly = MagpieDecode.mergeHeatmap(cached: nil, series: liveSeries, now: day)!
        expect(seriesOnly.first?.label == "2026-11-23" && seriesOnly.count == 4,
               "no cache → series-only week fallback")
        expect(MagpieDecode.mergeHeatmap(cached: nil, series: nil, now: day) == nil, "no data → nil")

        // 今日会话数：去重 id；period 非 today 拒收。
        let sessionsToday = """
        {"period":"today","sessions":[{"id":"a","agent":"codex"},{"id":"b","agent":"dsh"},{"id":"a","agent":"codex"}]}
        """
        expect(MagpieDecode.decodeUsageTodaySessions(Data(sessionsToday.utf8)) == 2, "today sessions deduped")
        expect(MagpieDecode.decodeUsageTodaySessions(Data(#"{"period":"30d","sessions":[{"id":"a"}]}"#.utf8)) == nil,
               "30d sessions rejected as today")
        expect(MagpieDecode.decodeUsageTodaySessions(Data(#"{"period":"today","sessions":[]}"#.utf8)) == 0,
               "empty today sessions → 0 (real zero, not unknown)")

        // 千问供应商今日消耗：只取 qwen/ 前缀的 modelAt；session-unknown 不混入。
        let qwenToday = """
        {"period":"today","calls":1861,"input":12157099,"output":929501,"cache_read":275951104,"cost":19.57,
         "by":{"modelAt":[
           {"id":"qwen/qwen4-max","calls":800,"input":100,"output":10,"cache_read":900,"cost":16.1},
           {"id":"session-unknown/qwen4-max","calls":50,"input":5,"output":5,"cache_read":50,"cost":0.1},
           {"id":"qwen/deepseek-v4.1-flash-1017","calls":900,"input":200,"output":20,"cache_read":1800,"cost":1.7}]}}
        """
        let qwen = MagpieDecode.decodeQwenUsageToday(Data(qwenToday.utf8))!
        expect(qwen.calls == 1861 && qwen.tokens == 12157099 + 929501 + 275951104,
               "qwen today totals from filtered top level")
        expect(qwen.cost == 19.57, "qwen cost preserved")
        expect(qwen.models.count == 2, "session-unknown rows excluded from qwen models")
        expect(qwen.models[0].name == "deepseek-v4.1-flash-1017" && qwen.models[0].tokens == 2020,
               "qwen models sorted by tokens desc, prefix stripped")
        expect(qwen.models[1].name == "qwen4-max" && qwen.models[1].calls == 800, "qwen4-max kept")
        expect(MagpieDecode.decodeQwenUsageToday(Data(merged.utf8)) == nil,
               "30d response rejected as qwen today")
        expect(MagpieDecode.decodeQwenUsageToday(Data(#"{"period":"today","calls":0,"input":0,"output":0,"cache_read":0}"#.utf8)) == nil,
               "all-zero qwen today → nil (card hidden)")

        // 通用供应商合计取 by.provider，不能误用 qwen 过滤后的顶层；模型也只认 kimi/ 前缀。
        let mixedProviders = """
        {"period":"today","calls":455,"input":300,"output":30,"cache_read":3000,"cost":4.3,
         "by":{"provider":[
           {"id":"qwen","calls":455,"input":300,"output":30,"cache_read":3000,"cost":4.3},
           {"id":"kimi","calls":38,"input":753480,"output":17020,"cache_read":8223482,"cost":3.3}],
          "modelAt":[
           {"id":"qwen/qwen4-max","calls":455,"input":300,"output":30,"cache_read":3000,"cost":4.3},
           {"id":"kimi/k3.1-pro","calls":38,"input":753480,"output":17020,"cache_read":8223482,"cost":3.3},
           {"id":"session-unknown/k3.1-pro","calls":9,"input":90,"output":9,"cache_read":900,"cost":0.9}]}}
        """
        let kimi = MagpieDecode.decodeProviderUsageToday(Data(mixedProviders.utf8), provider: "kimi")!
        expect(kimi.calls == 38 && kimi.tokens == 753480 + 17020 + 8223482,
               "kimi totals come from by.provider.kimi, not qwen-filtered top level")
        expect(kimi.models.count == 1 && kimi.models[0].name == "k3.1-pro",
               "kimi models exclude qwen and session-unknown rows")
        expect(MagpieDecode.decodeProviderUsageToday(Data(mixedProviders.utf8), provider: "qwen")?.tokens == 3330,
               "generic decoder also reads qwen provider summary")
        expect(MagpieDecode.decodeProviderUsageToday(Data(mixedProviders.utf8), provider: "missing") == nil,
               "missing provider → nil")
        expect(MagpieDecode.decodeProviderUsageToday(Data(merged.utf8), provider: "kimi") == nil,
               "30d response rejected as provider today")
        let zeroKimi = """
        {"period":"today","by":{"provider":[{"id":"kimi","calls":0,"input":0,"output":0,"cache_read":0}]}}
        """
        expect(MagpieDecode.decodeProviderUsageToday(Data(zeroKimi.utf8), provider: "kimi") == nil,
               "all-zero provider today → nil (card hidden)")
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
