#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Offline checks for the "follow the current DSH conversation" card.

Compiles the shipped DSHSessionProvider.swift together with a small harness and feeds it
synthetic payloads. No network, no DSH, no credentials: everything here is parsed from
bytes we hand-craft, so the test proves the *semantics* (what we show when data is
missing) rather than the availability of the endpoint at any moment.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources" / "DSHSessionProvider.swift"
TRANSPORT = ROOT / "Sources" / "DSHBalanceProvider.swift"

HARNESS = r'''
import Foundation

var failures: [String] = []
func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

func json(_ text: String) -> Data { Data(text.utf8) }

let live = json("""
{"ok":true,"context":{
  "sessionId":"session-8428a5de","providerId":"deepseek-account","providerFamily":"deepseek",
  "model":"deepseek-flash","accountId":"acct-1","updatedAt":"2026-11-22T04:00:00.000Z",
  "session":{"sessionId":"session-8428a5de","title":"融合 Glance 面板","providers":["deepseek-account"],
    "models":["deepseek-account/deepseek-flash"],"inputTokens":1200000,"outputTokens":320000,
    "cacheReadTokens":8400000,"cacheWriteTokens":0,"tokens":9920000,
    "estimatedCost":0.31,"currency":"CNY","costComplete":true,"pricing":{"source":"deepseek-official"},
    "firstAt":"2026-11-22T01:00:00.000Z","lastAt":"2026-11-22T04:00:00.000Z"}}}
""")

let result = try DSHSessionPayload.decodeContext(live)
expect(result.usage != nil, "live payload decodes")
if let usage = result.usage {
    expect(usage.sessionId == "session-8428a5de", "session id")
    expect(usage.providerId == "deepseek-account", "provider id kept verbatim")
    expect(usage.model == "deepseek-flash", "model kept verbatim")
    expect(usage.totalTokens == 9_920_000, "total tokens")
    expect(usage.inputTokens == 1_200_000 && usage.cacheReadTokens == 8_400_000, "input/cache split")
    expect(usage.outputTokens == 320_000, "output split")
    expect(usage.estimatedCost == Decimal(string: "0.31"), "complete cost is read")
    expect(usage.currency == "CNY", "currency is read")
    expect(usage.isMixedModel == false, "single model is not mixed")
    expect(DSHSessionFormat.cost(usage).text == "≈ ¥0.31", "cost text uses the currency symbol")
    expect(DSHSessionFormat.cost(usage).note.contains("deepseek-official"), "cost note names the pricing source")
    expect(DSHSessionFormat.modelLine(usage) == "deepseek · deepseek-flash", "model line uses provider family")
    expect(DSHSessionFormat.title(usage) == "融合 Glance 面板", "title comes from the session")
expect(DSHSessionFormat.shortId("session-8428a5de-53b1-4ef7") == "8428a5de", "short id drops the session- prefix")
expect(DSHSessionFormat.title(DSHSessionUsage(sessionId: "session-8428a5de-53b1-4ef7", title: nil,
    providerId: "deepseek-account", providerFamily: "deepseek", model: "deepseek-flash",
    inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 2,
    estimatedCost: nil, currency: nil, pricingSource: nil, lastAt: nil, models: [])) == "8428a5de",
    "a null title falls back to the readable short id, never to \"session-\"")
}

// 费用缺失：不能填 0，必须是「暂无数据」。
let noCost = json("""
{"ok":true,"context":{"sessionId":"s2","providerId":"v-api","providerFamily":"v-api","model":"claude-x",
 "session":{"sessionId":"s2","models":["v-api/claude-x"],"inputTokens":10,"outputTokens":2,
 "cacheReadTokens":0,"cacheWriteTokens":0,"tokens":12,"estimatedCost":null,
 "currency":null,"costComplete":false,"pricing":{"source":"unmapped"}}}}
""")
let missing = try DSHSessionPayload.decodeContext(noCost)
expect(missing.usage?.estimatedCost == nil, "missing cost stays nil")
if let usage = missing.usage {
    expect(DSHSessionFormat.cost(usage).text == "暂无数据", "missing cost renders 暂无数据, not 0")
    expect(DSHSessionFormat.cost(usage).note == "无完整计价", "missing cost note")
}

// 币种缺失但有金额：完整性不成立，同样不显示金额。
let mixedCurrency = json("""
{"ok":true,"context":{"sessionId":"s3","providerId":"v-api","providerFamily":"v-api","model":"claude-x",
 "session":{"sessionId":"s3","models":["v-api/claude-x"],"inputTokens":10,"outputTokens":2,
 "cacheReadTokens":0,"cacheWriteTokens":0,"tokens":12,"estimatedCost":1.5,
 "currency":"","costComplete":true}}}
""")
let mixed = try DSHSessionPayload.decodeContext(mixedCurrency)
expect(mixed.usage?.estimatedCost == nil, "cost without a currency is dropped")

// 混用模型：模型列表原样保留，界面靠 isMixedModel 标注合计口径。
let mixedModels = json("""
{"ok":true,"context":{"sessionId":"s4","providerId":"deepseek-account","providerFamily":"deepseek",
 "model":"deepseek-flash","session":{"sessionId":"s4","title":"混用","models":["deepseek-account/deepseek-flash","v-api/claude-x"],
 "inputTokens":1,"outputTokens":1,"cacheReadTokens":0,"cacheWriteTokens":0,"tokens":2,
 "estimatedCost":null,"currency":null,"costComplete":false}}}
""")
let both = try DSHSessionPayload.decodeContext(mixedModels)
expect(both.usage?.isMixedModel == true, "two models mark the session as mixed")
expect(both.usage?.models.count == 2, "both model keys are kept")

// 真实插件返回过的形状：title:null、updatedAt 是毫秒数、pricing 为空、costComplete:false、
// 同一会话里混用两个 provider（这是线上实际抓到的那份 payload 的字段组合）。
let liveRealShape = json(#"""
{"ok":true,"context":{"sessionId":"session-8428a5de-53b1-4ef7-9d34-92641a4174ab",
 "providerId":"deepseek-account","providerFamily":"deepseek","model":"deepseek-flash",
 "accountId":"deepseek-account","updatedAt":1795321237627,
 "session":{"sessionId":"session-8428a5de-53b1-4ef7-9d34-92641a4174ab","title":null,
  "providers":["deepseek-account","v-api"],
  "models":["deepseek-account/deepseek-flash","v-api/claude-sonnet-5-5"],
  "inputTokens":4277034,"outputTokens":839596,"cacheReadTokens":259177850,
  "cacheWriteTokens":1528437,"tokens":265822917,"estimatedCost":null,"currency":null,
  "costComplete":false,"pricing":{"ruleIds":[],"source":null,"updatedAt":null},
  "firstAt":"2026-11-13T07:33:19.720Z","lastAt":"2026-11-22T04:20:37.627Z"}},
 "display":{"currentSessionPill":true}}
"""#)
let realShape = try DSHSessionPayload.decodeContext(liveRealShape)
expect(realShape.usage != nil, "the shape the shipped plugin returns still decodes")
expect(realShape.usage?.title == nil, "a null title stays empty instead of failing the parse")
expect(realShape.usage?.isMixedModel == true, "two providers in one session is mixed")
expect(realShape.usage?.estimatedCost == nil, "costComplete:false means no cost number")
if let usage = realShape.usage {
    expect(DSHSessionFormat.cost(usage).text == "暂无数据", "incomplete cost renders 暂无数据")
    expect(DSHSessionFormat.modelLine(usage) == "deepseek · deepseek-flash", "model line survives a null title")
}

// 多会话：需要用户选择，而不是猜一个。
let needsPick = try DSHSessionPayload.decodeContext(
    json(#"{"ok":false,"error":"session-required","message":"session query parameter is required when multiple sessions are live"}"#))
expect(needsPick.needsSelection, "session-required maps to needsSelection")
expect(needsPick.usage == nil, "session-required carries no usage")
expect(needsPick.message == nil, "session-required is not an error message")

// 会话已经不在：明确告知，而不是继续展示旧数字。
let unknown = try DSHSessionPayload.decodeContext(json(#"{"ok":false,"error":"unknown-session"}"#))
expect(!unknown.needsSelection && unknown.message != nil, "unknown-session reports a message")

// ok + context:null：连上了但没有可识别会话。
let noContext = try DSHSessionPayload.decodeContext(json(#"{"ok":true,"context":null}"#))
expect(noContext.usage == nil && noContext.message == nil, "null context is empty, not an error")

// 形状不对必须抛错，避免把垃圾当数据。
var threw = false
do { _ = try DSHSessionPayload.decodeContext(json(#"{"hello":"world"}"#)) } catch { threw = true }
expect(threw, "unknown shape throws")

var threwBad = false
do { _ = try DSHSessionPayload.decodeContext(json(#"{"ok":true,"context":{"sessionId":""}}"#)) } catch { threwBad = true }
expect(threwBad, "empty session id throws")

// 候选会话：按最近活动倒序，空标题用短 id。
let choicesData = json("""
{"ok":true,"sessions":[
 {"sessionId":"aaa11111","title":"旧对话","models":["deepseek-account/deepseek-flash"],"lastAt":"2026-11-21T10:00:00.000Z"},
 {"sessionId":"bbb22222","title":"","models":["v-api/claude-x"],"lastAt":"2026-11-22T03:00:00.000Z"}]}
""")
let choices = try DSHSessionPayload.decodeChoices(choicesData)
expect(choices.count == 2, "two choices decoded")
expect(choices[0].sessionId == "bbb22222", "newest session first")
expect(choices[0].displayName == "bbb22222", "empty title falls back to the short id")
expect(choices[1].displayName == "旧对话", "title is used when present")

if failures.isEmpty {
    print("PASS: 33 session checks (synthetic payloads only; no network, no credentials)")
    exit(0)
}
for failure in failures { print("FAIL: " + failure) }
exit(1)
'''


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="quotastrip-session-") as folder:
        work = pathlib.Path(folder)
        (work / "DSHSessionProvider.swift").write_text(SOURCE.read_text(encoding="utf-8"), encoding="utf-8")
        # 传输层（回环发现 + 受限 URLSession）就在 DSHBalanceProvider.swift 里，一起编译。
        (work / "DSHBalanceProvider.swift").write_text(TRANSPORT.read_text(encoding="utf-8"), encoding="utf-8")
        (work / "main.swift").write_text(HARNESS, encoding="utf-8")
        binary = work / "session-tests"
        build = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0",
             str(work / "DSHSessionProvider.swift"), str(work / "DSHBalanceProvider.swift"),
             str(work / "main.swift"), "-o", str(binary)],
            capture_output=True, text=True, timeout=300)
        if build.returncode != 0:
            sys.stderr.write(build.stdout + build.stderr)
            return 1
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)

        # 源码级接线断言：开关、菜单项、断线分支、以及「不读凭据」。
        main_source = (ROOT / "Sources" / "main.swift").read_text(encoding="utf-8")
        panel = (ROOT / "Sources" / "UsagePanel.swift").read_text(encoding="utf-8")
        provider = SOURCE.read_text(encoding="utf-8")
        problems: [str] = []
        if '"followCurrentSession"' not in main_source:
            problems.append("main.swift does not persist the follow toggle")
        if "toggleFollowSession" not in main_source or "followSessionItem" not in main_source:
            problems.append("main.swift has no menu toggle for following")
        if "refreshSession(force: true)" not in main_source:
            problems.append("main.swift does not refresh the session when the panel opens")
        if "guard self.followSession else { return }" not in main_source:
            problems.append("late session results are not dropped after switching the toggle off")
        if "sessionProvider.cancel()" not in main_source:
            problems.append("cancelling follow leaves the in-flight request running")
        if "api/usage-stats/session-context" not in provider:
            problems.append("session provider does not call the documented endpoint")
        if "api/usage-stats/usage" not in provider:
            problems.append("session provider does not use the usage endpoint for the picker")
        for forbidden in ("apiKey", "cookie", "Cookie", "Authorization", "auth.json"):
            if forbidden in provider:
                problems.append("session provider must not read credentials: " + forbidden)
        if "secrets" in provider:
            problems.append("session provider touches the secrets directory")
        if "followSession" not in panel:
            problems.append("panel does not hide the card when following is off")
        if problems:
            print()
            for problem in problems:
                print("FAIL: " + problem)
            return 1
        print("PASS: session wiring assertions")
        return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
