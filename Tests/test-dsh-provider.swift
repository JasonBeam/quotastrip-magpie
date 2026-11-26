import Foundation

@main
struct DSHProviderTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(name)") }
    }
    static func rejected(_ text: String, account: Bool = true) -> Bool {
        do {
            if account { _ = try DSHUsagePayload.decodeAccount(Data(text.utf8)) }
            else { _ = try DSHUsagePayload.decodeTodayTokens(Data(text.utf8), day: "2026-11-13") }
            return false
        } catch { return true }
    }
    static func main() throws {
        let account = #"{"ok":true,"account":{"status":"ok","source":"host-account","balance":{"remaining":14.77000000000000000001,"currency":"CNY","breakdown":{"toppedUp":14.77}}}}"#
        let value = try DSHUsagePayload.decodeAccount(Data(account.utf8))
        expect(value.remaining == Decimal(string: "14.77000000000000000001")!, "decimal precision")
        expect(value.currency == "CNY", "currency")
        expect(rejected(account.replacingOccurrences(of: "\"ok\":true", with: "\"ok\":false")), "non-ok envelope")
        expect(rejected(account.replacingOccurrences(of: "\"status\":\"ok\"", with: "\"status\":\"signed-out\"")), "signed out")
        expect(rejected(account.replacingOccurrences(of: "\"status\":\"ok\"", with: "\"stale\":true,\"status\":\"ok\"")), "server stale")
        expect(rejected(account.replacingOccurrences(of: "host-account", with: "token")), "wrong source")
        expect(rejected(account.replacingOccurrences(of: "14.77000000000000000001", with: "-1")), "negative balance")
        expect(rejected(account.replacingOccurrences(of: "14.77000000000000000001", with: "null")), "null balance")
        expect(rejected(account.replacingOccurrences(of: "CNY", with: "XXX")), "invalid currency")
        let usage = #"{"ok":true,"days":[{"date":"2026-11-12","models":[{"model":"deepseek-account/deepseek-flash","tokens":1000}]},{"date":"2026-11-13","tokens":9999999,"models":[{"model":"deepseek-account/deepseek-flash","tokens":26452830},{"model":"openai/gpt-6.1-sol","tokens":3910104},{"model":"other/deepseek-flash","tokens":100}]}],"total":{"tokens":9999999}}"#
        expect(tryValue(usage) == 26452830, "today exact provider, exclude openai and totals")
        expect(tryValue(usage.replacingOccurrences(of: "2026-11-13", with: "2026-11-14")) == 0, "no usage today is zero")
        expect(tryValue(usage.replacingOccurrences(of: "3910104", with: "999999999999999999999999999999")) == 26452830, "ignore foreign overflowing tokens")
        expect(rejected(usage.replacingOccurrences(of: "26452830", with: "-1"), account: false), "negative tokens")
        expect(rejected(usage.replacingOccurrences(of: "26452830", with: "1.25"), account: false), "fractional tokens")
        expect(rejected(usage.replacingOccurrences(of: "26452830", with: "9223372036854775808"), account: false), "Int64 overflow")
        expect(rejected(usage.replacingOccurrences(of: "2026-11-12", with: "2026-11-13"), account: false), "duplicate day")
        expect(rejected(usage.replacingOccurrences(of: "\"ok\":true", with: "\"ok\":false"), account: false), "usage failure")
        expect(rejected(String(repeating: " ", count: 256 * 1024 + 1)), "payload bound")
        let sumOverflow = #"{"ok":true,"days":[{"date":"2026-11-13","models":[{"model":"deepseek-account/deepseek-flash","tokens":9223372036854775807},{"model":"deepseek-account/deepseek-flash","tokens":1}]}]}"#
        expect(rejected(sumOverflow, account: false), "sum overflow")
        // Cache hit rate uses the DSH page's formula: cacheRead / (input + cacheRead).
        // 「AI 用量」大数字 = 当天所有 provider 合计；provider 拆分按 model 名的前缀。
        let allProviders = #"{"ok":true,"days":[{"date":"2026-11-13","models":[{"model":"deepseek-account/deepseek-flash","tokens":1000},{"model":"baidu-pzt/qianfan-code-latest","tokens":4000},{"model":"openai/gpt-6.1-sol","tokens":500}]}]}"#
        let allToday = try DSHUsagePayload.decodeToday(Data(allProviders.utf8), day: "2026-11-13")
        expect(allToday.allTokens == 5500, "all-provider total is the sum of every model")
        expect(allToday.tokens == 1000, "deepseek-only total stays separate")
        expect(allToday.providerTokens["baidu-pzt"] == 4000, "provider split keeps qianfan apart")
        expect(allToday.providerTokens["deepseek-account"] == 1000, "provider split keeps deepseek apart")
        expect(allToday.providerTokens["openai"] == 500, "provider split keeps openai apart")
        // 会话清单：id 去掉 session- 前缀、按最近活动降序、无 token 的条目丢弃。
        let sessionsPayload = #"{"ok":true,"days":[],"sessions":[{"sessionId":"3ad4b15a-ed4c-41fd-98b6-5f4f6687364a","tokens":900,"models":["openai/gpt-6.1-sol"],"lastAt":"2026-11-13T09:09:58.935Z"},{"sessionId":"1c897bf1-c12d-45d1-92d0-2bb77ed16f07","tokens":152461,"models":["deepseek-account/deepseek-flash"],"lastAt":"2026-11-13T10:00:00.000Z"},{"sessionId":"","tokens":1}]}"#
        let sessions = try DSHUsagePayload.decodeSessions(Data(sessionsPayload.utf8))
        expect(sessions.count == 2, "sessions without id are dropped")
        expect(sessions.first?.id == "1c897bf1-c12d-45d1-92d0-2bb77ed16f07", "sessions sort by last activity")
        expect(sessions.first?.tokens == 152461, "session keeps its cumulative tokens")
        expect(sessions.first?.models.first == "deepseek-account/deepseek-flash", "session keeps its models")
        expect((try? DSHUsagePayload.decodeSessions(Data(#"{"ok":false,"days":[]}"#.utf8))) == nil,
               "sessions require ok")
        // 标题：只认 UUID 形态的 id，拒绝路径穿越。
        expect(DSHSessionTitles.key("session-8428a5de-53b1-4ef7-9d34-92641a4174ab") == "8428a5de-53b1-4ef7-9d34-92641a4174ab", "title key strips the prefix")
        expect(DSHSessionTitles.key("../etc/passwd") == nil, "title key rejects traversal")
        expect(DSHSessionTitles.key("not-a-uuid") == nil, "title key rejects non-uuid")
        let titleJSON = #"{"record":{"rows":{"title":{"ver":1,"val":"  在QuotaStrip \n实现样式  "}}}}"#
        expect(DSHSessionTitles.decodeTitle(Data(titleJSON.utf8)) == "在QuotaStrip 实现样式", "title value is collapsed")
        expect(DSHSessionTitles.decodeTitle(Data(#"{"record":{"rows":{}}}"#.utf8)) == nil, "missing title is nil")
        expect(DSHSessionTitles.normalise(String(repeating: "x", count: 60))?.hasSuffix("…") == true, "long titles are truncated")
        let cache = #"{"ok":true,"days":[{"date":"2026-11-13","models":[{"model":"deepseek-account/deepseek-flash","tokens":1000,"inputTokens":100,"cacheReadTokens":900},{"model":"openai/gpt-6.1-sol","tokens":5000,"inputTokens":5000,"cacheReadTokens":0}]}]}"#
        let today = try DSHUsagePayload.decodeToday(Data(cache.utf8), day: "2026-11-13")
        expect(today.tokens == 1000, "cache case keeps the deepseek-only token count")
        expect(abs((today.cacheHitPercent ?? -1) - 90) < 0.0001, "cache hit rate is cacheRead/(input+cacheRead)")
        let noCache = #"{"ok":true,"days":[{"date":"2026-11-13","models":[{"model":"deepseek-account/deepseek-flash","tokens":10}]}]}"#
        let noCacheToday = try DSHUsagePayload.decodeToday(Data(noCache.utf8), day: "2026-11-13")
        expect(noCacheToday.cacheHitPercent == nil, "missing cache fields show no rate")
        // 与 dsh-usage-stats 同口径：新写入的缓存块也要进分母。
        let withWrites = #"{"ok":true,"days":[{"date":"2026-11-13","models":[{"model":"deepseek-account/deepseek-flash","tokens":1000,"inputTokens":10,"cacheReadTokens":80,"cacheWriteTokens":10}]}]}"#
        let withWritesToday = try! DSHUsagePayload.decodeToday(Data(withWrites.utf8), day: "2026-11-13")
        expect(abs((withWritesToday.cacheHitPercent ?? -1) - 80) < 0.0001,
               "cacheWriteTokens counts in the denominator (80/100)")
        let allCached = #"{"ok":true,"days":[{"date":"2026-11-13","models":[{"model":"deepseek-account/deepseek-flash","tokens":10,"inputTokens":0,"cacheReadTokens":25}]}]}"#
        let allCachedToday = try DSHUsagePayload.decodeToday(Data(allCached.utf8), day: "2026-11-13")
        expect(allCachedToday.cacheHitPercent == 100, "all-cached input is 100%")
        let negativeCache = #"{"ok":true,"days":[{"date":"2026-11-13","models":[{"model":"deepseek-account/deepseek-flash","tokens":10,"inputTokens":-5,"cacheReadTokens":25}]}]}"#
        expect(rejected(negativeCache, account: false), "negative cache fields are rejected")

        for address in ["https://example.com", "http://localhost:50592", "http://192.168.1.2:50592", "http://127.0.0.1:50592?key=secret", "http://user:secret@127.0.0.1:50592", "http://127.0.0.1:50592/api", "http://127.0.0.1:50592#fragment", "http://127.0.0.1:0", "http://127.0.0.1:65536"] {
            expect(DSHBalanceProvider.validatedEndpoint(URL(string: address)!) == nil, "reject unsafe endpoint")
        }
        expect(DSHBalanceProvider.validatedEndpoint(URL(string: "http://127.0.0.1:54321/")!)?.absoluteString == "http://127.0.0.1:54321", "normalize local origin")
        // 近 7 日：按 deepseek-account/ 前缀求和，缺失日期补 0（槽位），旧→新。
        let weekDays = ["2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13",
                        "2026-11-14", "2026-11-15", "2026-11-16"]
        let week = #"{"ok":true,"days":[{"date":"2026-11-10","models":[{"model":"deepseek-account/deepseek-flash","tokens":300},{"model":"openai/gpt-6.1-sol","tokens":999999}]},{"date":"2026-11-12","models":[{"model":"deepseek-account/deepseek-flash","tokens":700},{"model":"deepseek-account/deepseek-pro","tokens":5}]}]}"#
        let recent = DSHUsagePayload.decodeRecentDays(Data(week.utf8), days: weekDays)
        expect(recent.dayLabels == weekDays, "recent labels keep the requested order")
        expect(recent.tokens == [300, 0, 705, 0, 0, 0, 0],
               "recent sums only deepseek-account/ and leaves missing days at zero")
        expect(DSHUsagePayload.decodeRecentDays(Data(week.utf8), days: []).tokens.isEmpty,
               "recent with no requested days is empty")
        expect(DSHUsagePayload.decodeRecentDays(Data(week.utf8), days: ["2026-11-10", "2026-11-10"]).tokens.isEmpty,
               "recent refuses duplicate requested days")
        expect(DSHUsagePayload.decodeRecentDays(Data(week.replacingOccurrences(of: "\"ok\":true", with: "\"ok\":false").utf8), days: weekDays).tokens.isEmpty,
               "recent refuses a failed envelope")
        expect(DSHUsagePayload.decodeRecentDays(Data("not json".utf8), days: weekDays).tokens.isEmpty,
               "recent refuses malformed json")
        expect(DSHUsagePayload.decodeRecentDays(Data(week.replacingOccurrences(of: "\"tokens\":700", with: "\"tokens\":-700").utf8), days: weekDays).tokens.isEmpty,
               "recent refuses negative tokens")
        expect(DSHUsagePayload.decodeRecentDays(Data(week.replacingOccurrences(of: "\"date\":\"2026-11-12\"", with: "\"date\":\"2026-11-10\"").utf8), days: weekDays).tokens.isEmpty,
               "recent refuses duplicate payload dates")
        let noOwnTokens = #"{"ok":true,"days":[{"date":"2026-11-10","models":[{"model":"deepseek-account/deepseek-flash"}]}]}"#
        expect(DSHUsagePayload.decodeRecentDays(Data(noOwnTokens.utf8), days: weekDays).tokens.isEmpty,
               "recent refuses a deepseek model without tokens")
        let weekOverflow = #"{"ok":true,"days":[{"date":"2026-11-10","models":[{"model":"deepseek-account/deepseek-flash","tokens":9223372036854775807},{"model":"deepseek-account/deepseek-pro","tokens":1}]}]}"#
        expect(DSHUsagePayload.decodeRecentDays(Data(weekOverflow.utf8), days: weekDays).tokens.isEmpty,
               "recent refuses an overflowing day")
        expect(DSHUsagePayload.decodeRecentDays(Data(String(repeating: " ", count: 256 * 1024 + 1).utf8), days: weekDays).tokens.isEmpty,
               "recent payload bound")

        // 近 7 日日期：本地自然日，旧→新，含今天；跨夏令时用 Calendar 逐日推算。
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 16
        components.hour = 12
        let fixedNow = shanghai.date(from: components)!
        expect(DSHUsagePayload.recentDayStrings(endingAt: fixedNow, calendar: shanghai) == weekDays,
               "recent labels are the 7 local days ending today")
        expect(DSHUsagePayload.recentDayStrings(endingAt: fixedNow, count: 0, calendar: shanghai).isEmpty,
               "recent labels refuse a zero count")

        // Platform bill: balance + cumulative official spend is the account-wide denominator.
        let bill = #"{"ok":true,"value":{"currency":"CNY","balance":9.88963752,"bonusBalance":0,"totalCosts":11.22043864,"totalHeld":21.11007616,"fetchedAt":1,"source":"platform-bill"}}"#
        let billValue = try DSHUsagePayload.decodeBill(Data(bill.utf8))
        expect(billValue.totalHeld == Decimal(string: "21.11007616")!, "bill keeps exact decimals")
        expect(billValue.balance == Decimal(string: "9.88963752")!, "bill balance")
        expect(billValue.currency == "CNY", "bill currency")
        func rejectedBill(_ text: String) -> Bool {
            do { _ = try DSHUsagePayload.decodeBill(Data(text.utf8)); return false } catch { return true }
        }
        expect(rejectedBill(bill.replacingOccurrences(of: "\"ok\":true", with: "\"ok\":false")), "bill failure envelope")
        expect(rejectedBill(bill.replacingOccurrences(of: "\"currency\":\"CNY\"", with: "\"currency\":\"XXX\"")), "bill currency")
        expect(rejectedBill(bill.replacingOccurrences(of: "\"totalHeld\":21.11007616", with: "\"totalHeld\":0")), "bill zero total")
        expect(!rejectedBill(bill), "bill without a stale flag still parses")
        expect(rejectedBill(bill.replacingOccurrences(of: "\"fetchedAt\":1", with: "\"stale\":true,\"fetchedAt\":1")), "stale bill is refused")
        expect(rejectedBill(bill.replacingOccurrences(of: "\"balance\":9.88963752", with: "\"balance\":-1")), "negative bill balance")
        expect(rejectedBill(bill.replacingOccurrences(of: "\"totalHeld\":21.11007616,", with: "")), "bill without total is refused")
        expect(rejectedBill(String(repeating: " ", count: 256 * 1024 + 1)), "bill payload bound")

        let empty = DeepSeekSnapshot()
        expect(empty.startingBalanceSource == nil, "no account-wide denominator by default")
        expect(empty.startingBalance == nil && empty.todaySpend == nil && empty.todayTokens == nil
               && empty.todayCacheHitPercent == nil && empty.balance == nil, "unknown fields never fabricated")
        expect(empty.accountTotalHeld == nil, "no totalHeld by default")
        expect(empty.recentDayLabels.isEmpty && empty.recentDayTokens.isEmpty,
               "no 7-day series by default")
        expect(empty.currency == "CNY" && !empty.stale, "snapshot defaults")
        // Invalid endpoint must complete on main without any real request/discovery.
        var completed = false
        DSHBalanceProvider(endpoint: URL(string: "http://example.com:1234")!).fetch { snapshot in
            expect(Thread.isMainThread && snapshot.stale && snapshot.balance == nil, "main completion and invalid endpoint")
            completed = true
        }
        expect(completed, "invalid endpoint completion")

        // Current-model follow: session-context decode + short tags.
        let ctx = #"{"ok":true,"context":{"providerId":"qwen","model":"qwen4-max-preview"}}"#
        expect((try? DSHUsagePayload.decodeSessionContext(Data(ctx.utf8))) == "qwen/qwen4-max-preview",
               "session-context joins provider/model")
        let ctxNoProvider = #"{"ok":true,"context":{"model":"glm-5.3"}}"#
        expect((try? DSHUsagePayload.decodeSessionContext(Data(ctxNoProvider.utf8))) == "glm-5.3",
               "session-context without provider keeps bare model")
        expect((try? DSHUsagePayload.decodeSessionContext(Data(#"{"ok":false}"#.utf8))) == nil,
               "session-context failure envelope rejected")
        expect((try? DSHUsagePayload.decodeSessionContext(Data(#"{"ok":true,"context":{}}"#.utf8))) == nil,
               "session-context missing model rejected")
        expect(DSHUsagePayload.shortModel("qwen/qwen4-max-preview") == "qwen4-max", "short tag qwen")
        expect(DSHUsagePayload.shortModel("qwen/deepseek-v4.1-flash-1017") == "v4.1-flash", "short tag v4.1")
        expect(DSHUsagePayload.shortModel("qwen/glm-5.3") == "glm-5.3", "short tag glm")
        expect(DSHUsagePayload.shortModel("deepseek-account/deepseek-flash") == "ds-flash", "short tag ds")
        expect(DSHUsagePayload.shortModel("x/some-very-long-model-name-here") == "some-very-l…", "short tag truncates")
        // 全 provider 的按模型缓存命中率：当前模型不是 DeepSeek 时 Touch Bar 缓存列用它。
        let cachePayload = """
        {"ok":true,"days":[{"date":"2026-11-24","models":[\
        {"model":"qwen/qwen4-max-preview","tokens":22446462,"inputTokens":1523736,"cacheReadTokens":20758016,"cacheWriteTokens":0},\
        {"model":"deepseek-account/deepseek-flash","tokens":100,"inputTokens":10,"cacheReadTokens":90,"cacheWriteTokens":0},\
        {"model":"x/zero","tokens":0,"inputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}]}]}
        """
        let cacheMap = DSHUsagePayload.decodeModelCache(Data(cachePayload.utf8), day: "2026-11-24")
        expect(cacheMap.count == 2, "model cache skips zero-denominator")
        expect(abs((cacheMap["qwen/qwen4-max-preview"] ?? 0) - 93.2) < 0.1, "model cache qwen ~93.2")
        expect(abs((cacheMap["deepseek-account/deepseek-flash"] ?? 0) - 90.0) < 0.001, "model cache deepseek 90")
        expect(DSHUsagePayload.decodeModelCache(Data(cachePayload.utf8), day: "2026-11-23").isEmpty, "model cache wrong day empty")
        expect(DSHUsagePayload.decodeModelCache(Data("{}".utf8), day: "2026-11-24").isEmpty, "model cache bad payload empty")
        // 会话列表过滤：只留 workspace 列表里的用户会话，子代理/后台会话藏掉。
        let conversations = """
        {"ok":true,"sessionIds":["session-8428a5de-53b1-4ef7-9d34-92641a4174ab","session-7492a285-62cb-48dc-a07d-5f31b0dcc9ca"],"source":"workspace","fetchedAt":1}
        """
        let allowed = DSHUsagePayload.decodeConversationIds(Data(conversations.utf8))
        expect(allowed?.count == 2, "conversation ids decoded")
        expect(allowed?.contains(DSHUsagePayload.sessionKey("8428a5de-53b1-4ef7-9d34-92641a4174ab")) == true,
               "bare uuid matches prefixed user session")
        expect(allowed?.contains(DSHUsagePayload.sessionKey("9502d5c1-9dfd-4dc6-8996-47c6b4a0ff30")) == false,
               "subagent session filtered out")
        expect(DSHUsagePayload.decodeConversationIds(Data(#"{"ok":false,"error":"no-store"}"#.utf8)) == nil,
               "unavailable list means no filtering")
        print("PASS: \(checks) DSH provider checks (synthetic payloads only; no keys, logs or real HTTP)")
    }
    static func tryValue(_ text: String) -> Int64? {
        try? DSHUsagePayload.decodeTodayTokens(Data(text.utf8), day: "2026-11-13")
    }
}
