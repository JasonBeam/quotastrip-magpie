import Foundation

func L(_ en: String, _ zh: String) -> String { zh }

/// 千问 Token Plan 解码 / 剩余 / 过期判定的合成测试：不触网、不碰 Chrome、不读凭据。
@main
struct PlanTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(name)") }
    }
    static func rejected(_ text: String, _ name: String) {
        do {
            _ = try QwenPlan.decode(Data(text.utf8))
            fatalError("FAIL: \(name) (unexpectedly accepted)")
        } catch {
            checks += 1
        }
    }

    static let sample = """
    {"qwen":{"max_age_seconds":5400,"note":"服务商返回部分订阅信息","observed_at":1795504787,"ok":true,"plan":"Standard","source":"千问官方 CLI","status":"partial","windows":[{"key":"monthly","label":"月度 Credits","limit":80000.0,"reset_at":"2026-12-16T00:00:00.000+08:00","unit":"Credits","used_percent":6.36167092}]},"ts":1795504787}
    """

    static func main() {
        // 正常解码
        let plan = try! QwenPlan.decode(Data(sample.utf8))
        expect(plan.plan == "Standard", "plan name")
        expect(plan.status == "partial", "plan status")
        expect(plan.source == "千问官方 CLI", "plan source")
        expect(plan.observedAt == Date(timeIntervalSince1970: 1_795_504_787), "observed_at unix seconds")
        expect(plan.maxAge == 5400, "max_age_seconds")
        expect(plan.windows.count == 1, "one window")
        let window = plan.windows[0]
        expect(window.key == "monthly" && window.label == "月度 Credits", "window key/label")
        expect(window.limit == 80000, "limit 80000")
        expect(window.unit == "Credits", "unit")
        expect(abs(window.remainingPercent - 93.63832908) < 1e-9, "remaining = 100 - used")
        // 2026-12-16T00:00:00+08:00 == 2026-12-15T16:00:00Z
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime]
        expect(window.resetAt == utc.date(from: "2026-12-15T16:00:00Z"), "reset_at keeps +08:00 offset")
        expect(plan.monthlyWindow?.key == "monthly", "monthlyWindow picks monthly")

        // 剩余计算边界
        let zero = QwenPlanWindow(key: "monthly", label: "", limit: nil, usedPercent: 0, resetAt: nil, unit: "")
        let full = QwenPlanWindow(key: "monthly", label: "", limit: nil, usedPercent: 100, resetAt: nil, unit: "")
        expect(zero.remainingPercent == 100, "used 0 → remaining 100")
        expect(full.remainingPercent == 0, "used 100 → remaining 0")

        // stale 判定：now - observedAt > maxAge
        let now = Date()
        let fresh = QwenPlan(plan: "", status: "", source: "", note: "",
                             observedAt: now.addingTimeInterval(-5399), maxAge: 5400, windows: [zero])
        let aged = QwenPlan(plan: "", status: "", source: "", note: "",
                            observedAt: now.addingTimeInterval(-5401), maxAge: 5400, windows: [zero])
        let unknown = QwenPlan(plan: "", status: "", source: "", note: "",
                               observedAt: nil, maxAge: 5400, windows: [zero])
        expect(!fresh.isStale(at: now), "5399s old is fresh")
        expect(aged.isStale(at: now), "5401s old is stale")
        expect(unknown.isStale(at: now), "missing observedAt is stale")

        // used_percent 越界 / 类型错误
        rejected(sample.replacingOccurrences(of: "6.36167092", with: "100.5"), "used > 100")
        rejected(sample.replacingOccurrences(of: "6.36167092", with: "-0.1"), "used < 0")
        rejected(sample.replacingOccurrences(of: "6.36167092", with: "\"6.3\""), "used as string")
        rejected(sample.replacingOccurrences(of: "6.36167092", with: "true"), "used as bool")

        // ok=false / 缺 windows / 空 windows
        rejected(sample.replacingOccurrences(of: "\"ok\":true", with: "\"ok\":false"), "ok false")
        rejected(sample.replacingOccurrences(of: "\"windows\":[{\"key\":\"monthly\",\"label\":\"月度 Credits\",\"limit\":80000.0,\"reset_at\":\"2026-12-16T00:00:00.000+08:00\",\"unit\":\"Credits\",\"used_percent\":6.36167092}]", with: "\"windows\":[]"), "empty windows")
        rejected("{\"qwen\":{\"ok\":true},\"ts\":1}", "missing windows")
        rejected("{\"ts\":1}", "missing qwen block")
        rejected("[1,2,3]", "root is not an object")
        rejected("not json", "garbage body")

        // 坏 reset_at：缺时区 / 纯日期 / 乱码 / 非字符串
        rejected(sample.replacingOccurrences(of: "2026-12-16T00:00:00.000+08:00", with: "2026-12-16T00:00:00"), "reset without timezone")
        rejected(sample.replacingOccurrences(of: "2026-12-16T00:00:00.000+08:00", with: "2026-12-16"), "reset date only")
        rejected(sample.replacingOccurrences(of: "2026-12-16T00:00:00.000+08:00", with: "garbage"), "reset garbage")
        rejected(sample.replacingOccurrences(of: "\"2026-12-16T00:00:00.000+08:00\"", with: "123"), "reset not a string")

        // limit 非法 / 缺省
        rejected(sample.replacingOccurrences(of: "80000.0", with: "0"), "limit zero")
        rejected(sample.replacingOccurrences(of: "80000.0", with: "-5"), "limit negative")
        let noLimit = try! QwenPlan.decode(Data(sample.replacingOccurrences(of: "\"limit\":80000.0,", with: "").utf8))
        expect(noLimit.windows[0].limit == nil, "missing limit stays nil")
        let noReset = try! QwenPlan.decode(Data(sample.replacingOccurrences(of: "\"reset_at\":\"2026-12-16T00:00:00.000+08:00\",", with: "").utf8))
        expect(noReset.windows[0].resetAt == nil, "missing reset_at stays nil")

        // 256KiB 上限
        let oversized = String(repeating: " ", count: 256 * 1024 + 1)
        rejected(oversized, "oversized body")
        let padded = sample + String(repeating: " ", count: 256 * 1024)
        rejected(padded, "valid JSON padded past the limit")

        // 直连扁平形状 /api/v1/qwen/usage
        let direct = """
        {"plan":"Standard","unit":"Credits","monthly_limit":80000.0,"used_percent":10.2938112,"reset_at":"2026-12-16T00:00:00.000+08:00","observed_at":"2026-11-24T15:10:59+00:00","data_status":"partial","stale":false,"last_attempt_at":"2026-11-24T15:10:59+00:00","sync_status":"ok"}
        """
        let d = try! QwenPlan.decode(Data(direct.utf8))
        expect(d.plan == "Standard", "direct plan")
        expect(d.status == "partial", "direct data_status maps to status")
        expect(d.note == "ok", "direct sync_status maps to note")
        expect(d.source == "direct-api", "direct source tag")
        expect(d.windows.count == 1 && d.monthlyWindow?.key == "monthly", "direct single monthly window")
        expect(d.monthlyWindow?.limit == 80000, "direct monthly_limit")
        expect(abs((d.monthlyWindow?.remainingPercent ?? 0) - 89.7061888) < 1e-9, "direct remaining = 100 - used")
        expect(d.observedAt == utc.date(from: "2026-11-24T15:10:59Z"), "direct observed_at ISO8601")
        expect(d.monthlyWindow?.resetAt == utc.date(from: "2026-12-15T16:00:00Z"), "direct reset keeps +08:00")
        expect(!d.isStale(at: utc.date(from: "2026-11-24T15:20:00Z")!), "direct fresh within 90min")
        expect(d.isStale(at: utc.date(from: "2026-11-24T17:00:00Z")!), "direct older than 90min is stale")
        rejected(direct.replacingOccurrences(of: "10.2938112", with: "101"), "direct used > 100")
        rejected(direct.replacingOccurrences(of: "\"used_percent\":10.2938112", with: "\"used_percent\":\"x\""), "direct used as string")
        rejected(direct.replacingOccurrences(of: "2026-12-16T00:00:00.000+08:00", with: "2026-12-16"), "direct reset without timezone")

        // 多账号 /api/v1/usage/accounts：空 models/keys 兼容 + 宽松明细解码
        let accounts = """
        [{"id":"qwen-primary","label":"Qwen Token Plan","provider":"qwen","plan":"Standard","unit":"Credits","monthly_limit":80000.0,"used_percent":21.769231325,"reset_at":"2026-12-16T00:00:00.000+08:00","observed_at":"2026-11-25T16:23:48+00:00","data_status":"partial","sync_status":"ok","stale":false,"models":[],"keys":[]}]
        """
        let list = try! QwenPlan.decodeAccounts(Data(accounts.utf8))
        expect(list.count == 1, "accounts one pool")
        expect(list[0].id == "qwen-primary" && list[0].label == "Qwen Token Plan", "accounts id/label")
        expect(list[0].models.isEmpty && list[0].keys.isEmpty, "empty models/keys tolerated")
        expect(abs((list[0].monthlyWindow?.remainingPercent ?? 0) - 78.230768675) < 1e-9, "accounts remaining")
        let inner = String(accounts.dropFirst().dropLast())
        let multi = try! QwenPlan.decodeAccounts(Data(("[" + inner + "," + inner.replacingOccurrences(of: "qwen-primary", with: "qwen-second") + "]").utf8))
        expect(multi.count == 2 && multi[1].id == "qwen-second", "accounts order preserved")
        let filled = accounts
            .replacingOccurrences(of: "\"models\":[]", with: "\"models\":[{\"model\":\"qwen4-max\",\"used\":52000,\"share\":65},{\"model\":\"qwen4-flash\",\"used\":28000,\"share\":35}]")
            .replacingOccurrences(of: "\"keys\":[]", with: "\"keys\":[{\"key_label\":\"beam****94\",\"used\":12000}]")
        let f = try! QwenPlan.decodeAccounts(Data(filled.utf8))[0]
        expect(f.models.count == 2 && f.models[0].label == "qwen4-max" && f.models[0].share == 65, "models lines decoded")
        expect(f.keys.count == 1 && f.keys[0].label == "beam****94" && f.keys[0].used == 12000, "keys lines decoded")
        let missing = accounts.replacingOccurrences(of: ",\"models\":[],\"keys\":[]", with: "")
        let m = try! QwenPlan.decodeAccounts(Data(missing.utf8))[0]
        expect(m.models.isEmpty && m.keys.isEmpty, "missing models/keys tolerated")
        do { _ = try QwenPlan.decodeAccounts(Data("[]".utf8)); fatalError("FAIL: empty accounts accepted") } catch { checks += 1 }
        do { _ = try QwenPlan.decodeAccounts(Data(direct.utf8)); fatalError("FAIL: flat object accepted as accounts") } catch { checks += 1 }

        print("PASS: \(checks) qwen plan decode/remaining/stale checks")
    }
}
