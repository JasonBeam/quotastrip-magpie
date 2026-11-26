#!/usr/bin/env python3
"""Tests for Sources/CodexUsageProvider.swift.

Builds the provider together with a generated Swift test main, runs the checks
(all assertions live in Swift), then removes the temporary build directory.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROVIDER = os.path.join(ROOT, "Sources", "CodexUsageProvider.swift")

SWIFT_TEST = r'''
import Foundation

var checks = 0
var failures: [String] = []

func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures.append(name) }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    checks += 1
    if actual != expected { failures.append("\(name): got \(actual), want \(expected)") }
}

func recordLine(_ timestamp: String, responseID: String?, input: Int, cached: Int?,
                output: Int, reasoning: Int, turnOutput: Int = 999999) -> String {
    var fields: [String] = []
    if let rid = responseID {
        fields.append("\"response_id\":\"\(rid)\"")
    }
    let cachedField = cached.map { "\"cached_input_tokens\":\($0)," } ?? ""
    fields.append("\"usage\":{\"input_tokens\":\(input),\(cachedField)\"output_tokens\":\(output)," +
                  "\"reasoning_output_tokens\":\(reasoning),\"total_tokens\":\(input + output)}")
    fields.append("\"turn_token_usage\":{\"input_tokens\":999999,\"cached_input_tokens\":999999," +
                  "\"output_tokens\":\(turnOutput)}")
    fields.append("\"thread_token_usage\":{\"input_tokens\":888888,\"cached_input_tokens\":888888," +
                  "\"output_tokens\":888888}")
    return "{\"timestamp\":\"\(timestamp)\",\"ordinal\":1,\"type\":\"token_usage_record\"," +
           "\"payload\":{\(fields.joined(separator: ","))}}"
}

func tokenCountLine(_ timestamp: String, input: Int, cached: Int, output: Int,
                    reasoning: Int, credits: String?) -> String {
    var payload = "\"type\":\"token_count\",\"info\":{" +
        "\"total_token_usage\":{\"input_tokens\":999999,\"cached_input_tokens\":999999,\"output_tokens\":999999}," +
        "\"last_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)," +
        "\"output_tokens\":\(output),\"reasoning_output_tokens\":\(reasoning)}}"
    if let credits = credits {
        payload += ",\"rate_limits\":{\"credits\":\(credits)}"
    }
    return "{\"timestamp\":\"\(timestamp)\",\"ordinal\":2,\"type\":\"event_msg\",\"payload\":{\(payload)}}"
}

let iso = ISO8601DateFormatter()
let shanghai = TimeZone(identifier: "Asia/Shanghai")!
let fixedNow = iso.date(from: "2026-11-13T04:00:00Z")!

func aggregate(_ lines: [String], day: String = "2026-11-13") -> CodexUsageSnapshot {
    return CodexUsageProvider.aggregate(lines: lines, day: day, timeZone: shanghai, now: fixedNow)
}

// 1. token_usage_record sums output/input/cached.
var snap = aggregate([recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_1",
                                 input: 1000, cached: 900, output: 50, reasoning: 0)])
checkEqual(snap.todayOutputTokens, Int64(50), "1 record output")
checkEqual(snap.todayInputTokens, Int64(1000), "1 record input")
checkEqual(snap.todayCachedInputTokens, Int64(900), "1 record cached")
checkEqual(snap.cacheHitPercent, 90.0, "1 record hit percent")
checkEqual(snap.scannedFiles, 1, "1 record scannedFiles")
checkEqual(snap.lastUpdated, fixedNow, "1 record lastUpdated")
check(snap.message == nil, "1 record message nil")
check(snap.credits == nil, "1 record credits nil")

// 2. Duplicate response_id counted once.
let dup = recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_dup",
                     input: 1000, cached: 900, output: 50, reasoning: 0)
snap = aggregate([dup, dup])
checkEqual(snap.todayOutputTokens, Int64(50), "2 duplicate output once")
checkEqual(snap.todayInputTokens, Int64(1000), "2 duplicate input once")

// 3. Mixed record + token_count: record wins, credits still read.
snap = aggregate([
    recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_mix",
               input: 1000, cached: 900, output: 50, reasoning: 0),
    tokenCountLine("2026-11-13T02:05:00.000Z", input: 111, cached: 100, output: 11, reasoning: 0,
                   credits: "{\"has_credits\":true,\"unlimited\":false,\"balance\":\"42\"}")
])
checkEqual(snap.todayOutputTokens, Int64(50), "3 mixed record only output")
checkEqual(snap.todayInputTokens, Int64(1000), "3 mixed record only input")
checkEqual(snap.credits?.balance, "42", "3 mixed credits from token_count")

// 4. token_count-only file uses last_token_usage increments.
snap = aggregate([
    tokenCountLine("2026-11-13T02:00:00.000Z", input: 100, cached: 80, output: 10, reasoning: 4, credits: nil),
    tokenCountLine("2026-11-13T02:01:00.000Z", input: 100, cached: 80, output: 10, reasoning: 4, credits: nil)
])
checkEqual(snap.todayOutputTokens, Int64(20), "4 fallback output")
checkEqual(snap.todayInputTokens, Int64(200), "4 fallback input")
checkEqual(snap.todayCachedInputTokens, Int64(160), "4 fallback cached")
checkEqual(snap.cacheHitPercent, 80.0, "4 fallback hit percent")

// 5. Cumulative turn/thread usage must not be added.
snap = aggregate([
    recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_t1",
               input: 100, cached: 0, output: 20, reasoning: 0, turnOutput: 70),
    recordLine("2026-11-13T02:00:10.000Z", responseID: "resp_t2",
               input: 100, cached: 0, output: 30, reasoning: 0, turnOutput: 100)
])
checkEqual(snap.todayOutputTokens, Int64(50), "5 turn increments output")
checkEqual(snap.todayInputTokens, Int64(200), "5 turn increments input")

// 6. Local-day boundaries in Asia/Shanghai.
snap = aggregate([
    recordLine("2026-11-12T16:30:00.000Z", responseID: "resp_b1", input: 10, cached: 0, output: 5, reasoning: 0),
    recordLine("2026-11-13T15:59:00.000Z", responseID: "resp_b2", input: 20, cached: 10, output: 7, reasoning: 0),
    recordLine("2026-11-13T16:00:00.000Z", responseID: "resp_b3", input: 1000, cached: 0, output: 100, reasoning: 0),
    recordLine("2026-11-12T15:59:59.000Z", responseID: "resp_b4", input: 2000, cached: 0, output: 200, reasoning: 0)
])
checkEqual(snap.todayOutputTokens, Int64(12), "6 timezone output")
checkEqual(snap.todayInputTokens, Int64(30), "6 timezone input")
checkEqual(snap.todayCachedInputTokens, Int64(10), "6 timezone cached")
checkEqual(snap.cacheHitPercent, 100.0 * 10.0 / 30.0, "6 timezone hit percent")

// 6b. 近 7 日趋势：旧→新、今天在最后，按本机时区切天。
let weekLabels = ["2026-11-07", "2026-11-08", "2026-11-09", "2026-11-10",
                  "2026-11-11", "2026-11-12", "2026-11-13"]
snap = aggregate([recordLine("2026-11-10T02:00:00.000Z", responseID: "resp_w1",
                             input: 1000, cached: 900, output: 50, reasoning: 0)])
checkEqual(snap.recentDayLabels, weekLabels, "6b labels oldest to newest")
checkEqual(snap.recentDayTokens, [0, 0, 0, 1050, 0, 0, 0], "6b record bucketed by local day")
checkEqual(snap.todayOutputTokens, Int64(0), "6b older day not counted as today")

snap = aggregate([tokenCountLine("2026-11-11T02:00:00.000Z", input: 100, cached: 80,
                                 output: 10, reasoning: 0, credits: nil)])
checkEqual(snap.recentDayTokens, [0, 0, 0, 0, 110, 0, 0], "6b fallback bucket uses increments")
checkEqual(snap.todayOutputTokens, Int64(0), "6b fallback older day not today")

// 记录型优先于 token_count，按文件整体生效，旧日也一样。
snap = aggregate([
    recordLine("2026-11-09T02:00:00.000Z", responseID: "resp_w2",
               input: 100, cached: 0, output: 10, reasoning: 0),
    tokenCountLine("2026-11-09T02:00:01.000Z", input: 999, cached: 0, output: 999, reasoning: 0, credits: nil)
])
checkEqual(snap.recentDayTokens, [0, 0, 110, 0, 0, 0, 0], "6b record wins inside an older bucket")

// response_id 去重覆盖整个 7 日窗口。
let windowDup = recordLine("2026-11-08T02:00:00.000Z", responseID: "resp_wdup",
                           input: 40, cached: 0, output: 4, reasoning: 0)
snap = aggregate([windowDup, windowDup])
checkEqual(snap.recentDayTokens, [0, 44, 0, 0, 0, 0, 0], "6b duplicate response_id counted once")

// 窗口边界：本机 00:00 属于新的一天，窗口前一天 23:59:59 被丢弃。
snap = aggregate([
    recordLine("2026-11-06T15:59:59.000Z", responseID: "resp_w_old", input: 999, cached: 0, output: 999, reasoning: 0),
    recordLine("2026-11-06T16:00:00.000Z", responseID: "resp_w_edge", input: 10, cached: 0, output: 5, reasoning: 0),
    recordLine("2026-11-12T15:59:59.000Z", responseID: "resp_w_prev", input: 20, cached: 0, output: 7, reasoning: 0),
    recordLine("2026-11-12T16:00:00.000Z", responseID: "resp_w_today", input: 30, cached: 0, output: 8, reasoning: 0)
])
checkEqual(snap.recentDayTokens, [15, 0, 0, 0, 0, 27, 38], "6b window edges use local midnight")
checkEqual(snap.todayOutputTokens, Int64(8), "6b today output")
checkEqual(snap.todayInputTokens, Int64(30), "6b today input")
checkEqual(snap.recentDayTokens.last, Int64(38), "6b last bucket equals today totals")

// 无日志也给 7 个日期标签（0 只是“无记录”，界面画槽位）。
snap = aggregate([])
checkEqual(snap.recentDayLabels, weekLabels, "6b empty logs still label the week")
checkEqual(snap.recentDayTokens, [0, 0, 0, 0, 0, 0, 0], "6b empty logs all zero")

// 跨文件同一天相加溢出的用例见 6c（需要两个 fixture 文件）。
let huge = Int64.max / 2 + 1

// 7. Cache hit edge cases.
snap = aggregate([recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_h1",
                             input: 1000, cached: 900, output: 5, reasoning: 0)])
checkEqual(snap.cacheHitPercent, 90.0, "7 hit 90")
snap = aggregate([recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_h2",
                             input: 0, cached: 0, output: 5, reasoning: 0)])
check(snap.cacheHitPercent == nil, "7 input zero hit nil")
checkEqual(snap.todayOutputTokens, Int64(5), "7 input zero output still counted")
snap = aggregate([recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_h3",
                             input: 500, cached: nil, output: 1, reasoning: 0)])
checkEqual(snap.cacheHitPercent, 0.0, "7 missing cached treated as zero")
checkEqual(snap.todayCachedInputTokens, Int64(0), "7 missing cached counter zero")

// 8. reasoning_output_tokens is not added to output.
snap = aggregate([recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_r1",
                             input: 100, cached: 0, output: 50, reasoning: 777)])
checkEqual(snap.todayOutputTokens, Int64(50), "8 reasoning not added")

// 9. Bad lines are skipped, valid lines still counted.
let nonNumeric = "{\"timestamp\":\"2026-11-13T02:00:00.000Z\",\"type\":\"token_usage_record\"," +
    "\"payload\":{\"usage\":{\"input_tokens\":\"abc\",\"output_tokens\":10}}}"
snap = aggregate([
    "{oops not json",
    recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_neg", input: -5, cached: 0, output: 10, reasoning: 0),
    nonNumeric,
    recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_ok", input: 1000, cached: 900, output: 50, reasoning: 0)
])
checkEqual(snap.todayOutputTokens, Int64(50), "9 bad lines skipped")
checkEqual(snap.todayInputTokens, Int64(1000), "9 bad lines input")
checkEqual(snap.cacheHitPercent, 90.0, "9 bad lines hit")

// 10 (aggregate side). Invalid day yields a message instead of a crash.
snap = aggregate([], day: "2026-13-99")
check(snap.message != nil, "10 invalid day message")
check(snap.recentDayTokens.isEmpty && snap.recentDayLabels.isEmpty, "10 invalid day no trend")

// 11. Credits selection and edge cases.
let creditsNewest = "{\"has_credits\":true,\"unlimited\":true,\"balance\":\"1336.8076402500\"}"
snap = aggregate([
    tokenCountLine("2026-11-13T02:00:00.000Z", input: 0, cached: 0, output: 0, reasoning: 0,
                   credits: "{\"has_credits\":true,\"unlimited\":false,\"balance\":\"100\"}"),
    tokenCountLine("2026-11-13T04:00:00.000Z", input: 0, cached: 0, output: 0, reasoning: 0,
                   credits: creditsNewest),
    tokenCountLine("2026-11-13T03:00:00.000Z", input: 0, cached: 0, output: 0, reasoning: 0,
                   credits: "{\"has_credits\":true,\"unlimited\":false,\"balance\":\"200\"}")
])
checkEqual(snap.credits?.balance, "1336.8076402500", "11 credits newest balance")
checkEqual(snap.credits?.unlimited, true, "11 credits newest unlimited")
checkEqual(snap.credits?.observedAt, iso.date(from: "2026-11-13T04:00:00Z"), "11 credits observedAt")

snap = aggregate([
    tokenCountLine("2026-11-13T04:00:00.000Z", input: 0, cached: 0, output: 0, reasoning: 0,
                   credits: "{\"has_credits\":false,\"unlimited\":false,\"balance\":\"0\"}")
])
check(snap.credits != nil, "11 has_credits false still returns struct")
checkEqual(snap.credits?.hasCredits, false, "11 has_credits false flag")
checkEqual(snap.credits?.balance, "0", "11 has_credits false balance zero")

snap = aggregate([
    tokenCountLine("2026-11-13T04:00:00.000Z", input: 0, cached: 0, output: 0, reasoning: 0, credits: nil),
    recordLine("2026-11-13T04:00:00.000Z", responseID: "resp_nc", input: 1, cached: 0, output: 1, reasoning: 0)
])
check(snap.credits == nil, "11 no credits nil")

// Provider-level fixtures.
let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default

func fixtureURL(_ root: URL, _ relative: String) -> URL {
    let url = root.appendingPathComponent(relative)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return url
}

func writeFixture(_ text: String, to url: URL) {
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        checks += 1
        failures.append("could not write fixture \(url.lastPathComponent)")
    }
}

func appendFixture(_ text: String, to url: URL) {
    guard let data = text.data(using: .utf8), let handle = try? FileHandle(forWritingTo: url) else {
        checks += 1
        failures.append("could not append fixture \(url.lastPathComponent)")
        return
    }
    handle.seekToEndOfFile()
    handle.write(data)
    handle.closeFile()
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = shanghai

func refreshSnapshot(_ provider: CodexUsageProvider, force: Bool = true,
                     timeout: TimeInterval = 30) -> (CodexUsageSnapshot, Bool) {
    var result: CodexUsageSnapshot?
    var onMain = false
    provider.refresh(force: force) { snapshot in
        onMain = Thread.isMainThread
        result = snapshot
    }
    let deadline = Date().addingTimeInterval(timeout)
    while result == nil && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    if result == nil {
        checks += 1
        failures.append("refresh timed out after \(timeout)s")
        return (CodexUsageSnapshot(), onMain)
    }
    return (result!, onMain)
}

// 10 (provider side). Trailing partial line is not counted and the offset is not advanced.
let partialRoot = base.appendingPathComponent("partial-sessions", isDirectory: true)
let partialFile = fixtureURL(partialRoot, "2026/11/13/rollout-2026-11-13T10-00-00.jsonl")
writeFixture(recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_p1",
                        input: 1000, cached: 900, output: 50, reasoning: 0) + "\n", to: partialFile)
writeFixture(recordLine("2026-11-13T02:01:00.000Z", responseID: "resp_ignore",
                        input: 7, cached: 0, output: 7, reasoning: 0), to:
    fixtureURL(partialRoot, "2026/11/13/notes.txt"))
let partialProvider = CodexUsageProvider(sessionsDirectory: partialRoot, calendar: calendar,
                                         now: { fixedNow }, cacheLifetime: 60)
var result = refreshSnapshot(partialProvider)
checkEqual(result.0.todayOutputTokens, Int64(50), "10 partial first refresh output")
checkEqual(result.0.scannedFiles, 1, "10 partial only jsonl scanned")
check(result.1, "10 partial callback on main thread")

appendFixture(recordLine("2026-11-13T02:02:00.000Z", responseID: "resp_p2",
                         input: 1000, cached: 900, output: 70, reasoning: 0), to: partialFile)
result = refreshSnapshot(partialProvider)
checkEqual(result.0.todayOutputTokens, Int64(50), "10 partial line not counted")
checkEqual(result.0.todayInputTokens, Int64(1000), "10 partial line input unchanged")

appendFixture("\n", to: partialFile)
result = refreshSnapshot(partialProvider)
checkEqual(result.0.todayOutputTokens, Int64(120), "10 partial counted after newline")
checkEqual(result.0.todayInputTokens, Int64(2000), "10 partial input after newline")
checkEqual(result.0.recentDayLabels, weekLabels, "10 partial recent labels")
checkEqual(result.0.recentDayTokens, [0, 0, 0, 0, 0, 0, 2120], "10 partial recent today bucket")

// 13 (provider cache). cacheLifetime returns the cached snapshot without touching disk.
let cacheRoot = base.appendingPathComponent("cache-sessions", isDirectory: true)
let cacheFile = fixtureURL(cacheRoot, "2026/11/13/rollout-cache.jsonl")
writeFixture(recordLine("2026-11-13T02:00:00.000Z", responseID: "resp_c1",
                        input: 100, cached: 50, output: 50, reasoning: 0) + "\n", to: cacheFile)
let cacheProvider = CodexUsageProvider(sessionsDirectory: cacheRoot, calendar: calendar,
                                       now: { fixedNow }, cacheLifetime: 60)
result = refreshSnapshot(cacheProvider, force: false)
checkEqual(result.0.todayOutputTokens, Int64(50), "13 first cached scan")
appendFixture(recordLine("2026-11-13T02:00:01.000Z", responseID: "resp_c2",
                         input: 100, cached: 50, output: 25, reasoning: 0) + "\n", to: cacheFile)
result = refreshSnapshot(cacheProvider, force: false)
checkEqual(result.0.todayOutputTokens, Int64(50), "13 cacheLifetime serves cached snapshot")
result = refreshSnapshot(cacheProvider, force: true)
checkEqual(result.0.todayOutputTokens, Int64(75), "13 forced refresh sees appended record")
checkEqual(result.0.recentDayTokens.last, Int64(275), "13 forced refresh trend today bucket")
result = refreshSnapshot(cacheProvider, force: true)
checkEqual(result.0.todayOutputTokens, Int64(75), "13 repeated forced refresh no double count")
checkEqual(result.0.recentDayTokens.last, Int64(275), "13 repeated forced refresh trend stable")

// 6c. 两个文件的同一天相加溢出 → 整组趋势作废，今日数字不受影响。
let overflowRoot = base.appendingPathComponent("overflow-sessions", isDirectory: true)
writeFixture(recordLine("2026-11-10T02:00:00.000Z", responseID: "resp_o1",
                        input: Int(huge), cached: 0, output: 0, reasoning: 0) + "\n",
             to: fixtureURL(overflowRoot, "2026/11/10/rollout-a.jsonl"))
writeFixture(recordLine("2026-11-10T02:00:01.000Z", responseID: "resp_o2",
                        input: Int(huge), cached: 0, output: 0, reasoning: 0) + "\n",
             to: fixtureURL(overflowRoot, "2026/11/10/rollout-b.jsonl"))
let overflowProvider = CodexUsageProvider(sessionsDirectory: overflowRoot, calendar: calendar,
                                          now: { fixedNow }, cacheLifetime: 60)
result = refreshSnapshot(overflowProvider)
check(result.0.recentDayTokens.isEmpty && result.0.recentDayLabels.isEmpty,
      "6c cross-file overflow drops the whole trend")
checkEqual(result.0.todayOutputTokens, Int64(0), "6c today unaffected")

// 12. Missing directory.
let missingProvider = CodexUsageProvider(
    sessionsDirectory: base.appendingPathComponent("missing-sessions", isDirectory: true),
    calendar: calendar, now: { fixedNow }, cacheLifetime: 60)
result = refreshSnapshot(missingProvider)
checkEqual(result.0.message, "找不到 ~/.codex/sessions", "12 missing dir message")
check(result.0.todayOutputTokens == nil, "12 missing dir output nil")
check(result.0.todayInputTokens == nil, "12 missing dir input nil")
check(result.0.todayCachedInputTokens == nil, "12 missing dir cached nil")
check(result.0.cacheHitPercent == nil, "12 missing dir hit nil")
check(result.0.credits == nil, "12 missing dir credits nil")
check(result.0.lastUpdated == nil, "12 missing dir lastUpdated nil")
checkEqual(result.0.scannedFiles, 0, "12 missing dir scannedFiles zero")
check(result.0.recentDayTokens.isEmpty && result.0.recentDayLabels.isEmpty,
      "12 missing dir no trend")
check(result.1, "12 missing dir callback on main thread")

// 14. Real log performance (read-only; skipped when unavailable).
let realDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
if fm.fileExists(atPath: realDir.path) {
    let realProvider = CodexUsageProvider(sessionsDirectory: realDir, calendar: Calendar.current,
                                          now: Date.init, cacheLifetime: 0)
    let started = Date()
    result = refreshSnapshot(realProvider, force: true, timeout: 180)
    let elapsed = Date().timeIntervalSince(started)
    let hit = result.0.cacheHitPercent.map { String(format: "%.2f", $0) } ?? "nil"
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"
    dayFormatter.timeZone = Calendar.current.timeZone
    print("PERF: day=\(dayFormatter.string(from: Date())) files=\(result.0.scannedFiles) " +
          "elapsed=\(String(format: "%.3f", elapsed))s " +
          "output=\(result.0.todayOutputTokens.map(String.init) ?? "nil") " +
          "input=\(result.0.todayInputTokens.map(String.init) ?? "nil") " +
          "cached=\(result.0.todayCachedInputTokens.map(String.init) ?? "nil") hit=\(hit)")
    check(result.0.scannedFiles > 0, "14 real logs scanned")
    checkEqual(result.0.recentDayTokens.count, 7, "14 real logs trend week")
    print("PERF trend: " + result.0.recentDayTokens.map(String.init).joined(separator: ","))
    check(result.0.message == nil, "14 real logs no message")
    check(elapsed < 2.0, "14 real logs under 2 seconds")
} else {
    print("PERF: skipped, ~/.codex/sessions not found")
}

if failures.isEmpty {
    print("SWIFT_CHECKS: \(checks)")
} else {
    print("SWIFT_FAILURES: \(failures.count)")
    for failure in failures {
        print("FAIL: \(failure)")
    }
    exit(1)
}
'''


def main():
    if not os.path.isfile(PROVIDER):
        print("FAIL: missing provider at %s" % PROVIDER)
        return 1

    temp_dir = tempfile.mkdtemp(prefix="codex-usage-tests-")
    try:
        main_swift = os.path.join(temp_dir, "main.swift")
        executable = os.path.join(temp_dir, "codex-usage-tests")
        with open(main_swift, "w", encoding="utf-8") as handle:
            handle.write(SWIFT_TEST)

        compile_command = [
            "xcrun", "swiftc", "-O", "-swift-version", "5",
            PROVIDER, main_swift, "-o", executable,
        ]
        compile_result = subprocess.run(compile_command, capture_output=True, text=True)
        if compile_result.returncode != 0:
            sys.stdout.write(compile_result.stdout)
            sys.stderr.write(compile_result.stderr)
            print("FAIL: swiftc could not build the provider tests")
            return 1

        run_result = subprocess.run([executable, temp_dir], capture_output=True, text=True, timeout=300)
        sys.stdout.write(run_result.stdout)
        if run_result.returncode != 0:
            sys.stderr.write(run_result.stderr)
            print("FAIL: codex usage checks failed")
            return 1

        match = re.search(r"SWIFT_CHECKS:\s*(\d+)", run_result.stdout)
        if not match:
            print("FAIL: test binary did not report a check count")
            return 1
        print("PASS: %s codex usage checks" % match.group(1))
        return 0
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
