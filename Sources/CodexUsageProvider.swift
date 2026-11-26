import Foundation

// MARK: - Public contract

/// One observed Codex credits balance. `balance` stays a string on purpose: the
/// on-disk value carries more precision than Double, and "0" is a real balance.
struct CodexCredits {
    var balance: String
    var hasCredits: Bool
    var unlimited: Bool
    var observedAt: Date
}

/// Local-only usage for the current natural day. Nil counters mean "not read"
/// (for example the sessions directory is missing); 0 means "read, nothing used".
struct CodexUsageSnapshot {
    var todayOutputTokens: Int64? = nil
    var todayInputTokens: Int64? = nil
    var todayCachedInputTokens: Int64? = nil
    /// cached / input * 100. Nil when input is missing or <= 0.
    var cacheHitPercent: Double? = nil
    var credits: CodexCredits? = nil
    var lastUpdated: Date? = nil
    var scannedFiles: Int = 0
    var message: String? = nil
    /// 近 7 日（旧→新）本地日期 "yyyy-MM-dd"，与 `recentDayTokens` 一一对应。
    /// 数组为空表示没有可用数据；无记录的那天为 0。
    var recentDayLabels: [String] = []
    var recentDayTokens: [Int64] = []
}

/// Reads Codex's local rollout logs. Only `~/.codex/sessions` (or the injected
/// directory) is touched; credentials, auth files, prompts and payloads are never
/// read, retained or logged. All provider state is main-thread confined.
final class CodexUsageProvider {
    private struct FileCache {
        var size: Int64
        var modified: Date
        /// Byte offset after the last complete line already parsed.
        var offset: Int64
        var hasRecord: Bool
        var record: CodexUsageCounters
        var fallback: CodexUsageCounters
        /// 近 7 日分桶（旧→新，最后一个是今天），随增量偏移一起缓存。
        var recordRecent: [CodexUsageCounters] = emptyCodexRecentCounters()
        var fallbackRecent: [CodexUsageCounters] = emptyCodexRecentCounters()
    }

    private struct ScanOutput {
        var fileCaches: [String: FileCache]
        var seen: Set<String>
        var credits: CodexCredits?
        var creditsDate: Date?
        var scannedFiles: Int
        var message: String?
        var available: Bool
    }

    private let sessionsDirectory: URL
    private let calendar: Calendar
    private let now: () -> Date
    private let cacheLifetime: TimeInterval

    private var fileCaches: [String: FileCache] = [:]
    private var seenResponseIDs = Set<String>()
    private var credits: CodexCredits?
    private var creditsDate: Date?
    private var cachedSnapshot: CodexUsageSnapshot?
    private var cachedSnapshotDate: Date?
    private var cachedDay: String?
    private var isScanning = false
    private var pending: [(CodexUsageSnapshot) -> Void] = []

    /// `sessionsDirectory == nil` means `~/.codex/sessions`. The directory is
    /// inspected read-only; missing/permission failures surface through `message`.
    init(sessionsDirectory: URL? = nil,
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init,
         cacheLifetime: TimeInterval = 60) {
        if let sessionsDirectory = sessionsDirectory {
            self.sessionsDirectory = sessionsDirectory
        } else {
            self.sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        self.calendar = calendar
        self.now = now
        self.cacheLifetime = cacheLifetime
    }

    func refresh(force: Bool, completion: @escaping (CodexUsageSnapshot) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh(force: force, completion: completion) }
            return
        }
        if isScanning {
            pending.append(completion)
            return
        }

        let moment = now()
        let day = Self.dayString(moment, calendar: calendar)
        if !force, let snapshot = cachedSnapshot, cachedDay == day,
           let cachedAt = cachedSnapshotDate,
           moment.timeIntervalSince(cachedAt) < cacheLifetime {
            DispatchQueue.main.async { completion(snapshot) }
            return
        }

        if cachedDay != day {
            reset(day: day)
        }

        pending.append(completion)
        isScanning = true
        let directory = sessionsDirectory
        let scanCalendar = calendar
        let caches = fileCaches
        let seen = seenResponseIDs
        let currentCredits = credits
        let currentCreditsDate = creditsDate
        DispatchQueue.global(qos: .utility).async {
            let output = Self.scan(directory: directory,
                                   calendar: scanCalendar,
                                   day: day,
                                   initialCaches: caches,
                                   initialSeen: seen,
                                   initialCredits: currentCredits,
                                   initialCreditsDate: currentCreditsDate)
            DispatchQueue.main.async { self.finish(output, day: day) }
        }
    }

    /// Pure aggregation over one file's text lines (or one synthetic batch).
    /// `payload.usage` / `payload.info.last_token_usage` are single-response
    /// increments; `turn_token_usage` and `thread_token_usage` are cumulative and
    /// intentionally ignored.
    static func aggregate(lines: [String], day: String, timeZone: TimeZone, now: Date) -> CodexUsageSnapshot {
        guard let parsedDay = CodexUsageDay(string: day) else {
            return CodexUsageSnapshot(message: "日期格式无效")
        }
        let parser = CodexUsageLineParser(day: parsedDay, timeZone: timeZone,
                                          seen: [], credits: nil, creditsDate: nil)
        var result = CodexUsageFileResult()
        for line in lines {
            parser.consume(line, into: &result)
        }
        var snapshot = CodexUsageSnapshot()
        let totals = result.hasRecord ? result.record : result.fallback
        snapshot.todayOutputTokens = totals.output
        snapshot.todayInputTokens = totals.input
        snapshot.todayCachedInputTokens = totals.cached
        if totals.input > 0 {
            snapshot.cacheHitPercent = Double(totals.cached) * 100.0 / Double(totals.input)
        }
        snapshot.credits = parser.credits
        snapshot.lastUpdated = now
        snapshot.scannedFiles = lines.isEmpty ? 0 : 1
        let recent = result.hasRecord ? result.recordRecent : result.fallbackRecent
        if let tokens = recentTokenTotals(recent) {
            snapshot.recentDayLabels = Self.recentDayStrings(day: day, calendar: calendar(timeZone: timeZone))
            snapshot.recentDayTokens = tokens
        }
        return snapshot
    }

    /// input + output（input 已含 cached），与今日统计同口径；溢出返回 nil。
    private static func recentTokenTotals(_ recent: [CodexUsageCounters]) -> [Int64]? {
        guard recent.count >= codexRecentDayCount else { return nil }
        var result: [Int64] = []
        result.reserveCapacity(codexRecentDayCount)
        for index in 0..<codexRecentDayCount {
            let sum = recent[index].input.addingReportingOverflow(recent[index].output)
            guard !sum.overflow else { return nil }
            result.append(sum.partialValue)
        }
        return result
    }

    private static func recentDayStrings(day: String, calendar: Calendar) -> [String] {
        guard let parsed = CodexUsageDay(string: day) else { return [] }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        var components = DateComponents()
        components.year = parsed.year
        components.month = parsed.month
        components.day = parsed.day
        guard let start = local.date(from: components) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var result: [String] = []
        result.reserveCapacity(codexRecentDayCount)
        for offset in stride(from: codexRecentDayCount - 1, through: 0, by: -1) {
            guard let date = local.date(byAdding: .day, value: -offset, to: start) else { return [] }
            result.append(formatter.string(from: date))
        }
        return result
    }

    private static func calendar(timeZone: TimeZone) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }

    // MARK: Main-thread state

    private func reset(day: String) {
        fileCaches.removeAll()
        seenResponseIDs.removeAll()
        credits = nil
        creditsDate = nil
        cachedSnapshot = nil
        cachedSnapshotDate = nil
        cachedDay = day
    }

    private func finish(_ output: ScanOutput, day: String) {
        isScanning = false
        fileCaches = output.fileCaches
        seenResponseIDs = output.seen
        credits = output.credits
        creditsDate = output.creditsDate
        cachedDay = day

        var snapshot = CodexUsageSnapshot()
        snapshot.scannedFiles = output.scannedFiles
        snapshot.message = output.message
        snapshot.credits = output.credits
        let moment = now()
        snapshot.lastUpdated = output.available ? moment : nil
        if output.available {
            var totals = CodexUsageCounters()
            // 近 7 日按天汇总；任何一天溢出就整组作废，不展示半截数据。
            var recent = [Int64](repeating: 0, count: codexRecentDayCount)
            var recentValid = true
            for cache in output.fileCaches.values {
                let value = cache.hasRecord ? cache.record : cache.fallback
                _ = totals.add(output: value.output, input: value.input, cached: value.cached)
                let buckets = cache.hasRecord ? cache.recordRecent : cache.fallbackRecent
                guard buckets.count >= codexRecentDayCount else {
                    recentValid = false
                    continue
                }
                for index in 0..<codexRecentDayCount {
                    let sum = buckets[index].input.addingReportingOverflow(buckets[index].output)
                    guard !sum.overflow else { recentValid = false; continue }
                    let total = recent[index].addingReportingOverflow(sum.partialValue)
                    guard !total.overflow else { recentValid = false; continue }
                    recent[index] = total.partialValue
                }
            }
            snapshot.todayOutputTokens = totals.output
            snapshot.todayInputTokens = totals.input
            snapshot.todayCachedInputTokens = totals.cached
            if totals.input > 0 {
                snapshot.cacheHitPercent = Double(totals.cached) * 100.0 / Double(totals.input)
            }
            if recentValid {
                snapshot.recentDayLabels = Self.recentDayStrings(day: day, calendar: calendar)
                snapshot.recentDayTokens = recent
            }
        }
        cachedSnapshot = snapshot
        cachedSnapshotDate = moment

        let callbacks = pending
        pending.removeAll()
        callbacks.forEach { $0(snapshot) }
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    // MARK: Directory scan (background)

    private struct FileInfo {
        let url: URL
        let path: String
        let size: Int64
        let modified: Date
    }

    private static func scan(directory: URL, calendar: Calendar, day: String,
                             initialCaches: [String: FileCache],
                             initialSeen: Set<String>,
                             initialCredits: CodexCredits?,
                             initialCreditsDate: Date?) -> ScanOutput {
        let unavailable = { (message: String) -> ScanOutput in
            ScanOutput(fileCaches: [:], seen: [], credits: nil, creditsDate: nil,
                       scannedFiles: 0, message: message, available: false)
        }
        guard let parsedDay = CodexUsageDay(string: day) else {
            return unavailable("日期格式无效")
        }

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return unavailable("找不到 ~/.codex/sessions")
        }
        guard manager.isReadableFile(atPath: directory.path) else {
            return unavailable("无法读取 ~/.codex/sessions（权限不足）")
        }

        // Enumerate every rollout file; `.jsonl.zst` archives are deliberately not
        // decompressed (no third-party dependency, and the live log is plain text).
        var urls: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(at: directory,
                                                  includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles],
                                                  errorHandler: { _, _ in true }) else {
            return unavailable("无法读取 ~/.codex/sessions（权限不足）")
        }
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            urls.append(url)
            if urls.count > codexUsageMaxFiles { break }
        }
        let truncated = urls.count > codexUsageMaxFiles
        if truncated {
            urls = Array(urls.prefix(codexUsageMaxFiles))
        }
        urls.sort { $0.path < $1.path }

        var files: [FileInfo] = []
        files.reserveCapacity(urls.count)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { continue }
            files.append(FileInfo(url: url, path: url.path, size: Int64(size), modified: modified))
        }

        // A vanished or shrunken file invalidates offsets/dedup state for every file,
        // so rebuild from scratch rather than mixing stale aggregates.
        var caches = initialCaches
        let present = Set(files.map { $0.path })
        var resetAll = caches.keys.contains { !present.contains($0) }
        if !resetAll {
            for file in files {
                if let cached = caches[file.path], file.size < cached.size {
                    resetAll = true
                    break
                }
            }
        }
        var seen = initialSeen
        var credits = initialCredits
        var creditsDate = initialCreditsDate
        if resetAll {
            caches.removeAll()
            seen.removeAll()
            credits = nil
            creditsDate = nil
        }

        let parser = CodexUsageLineParser(day: parsedDay, timeZone: calendar.timeZone,
                                          seen: seen, credits: credits, creditsDate: creditsDate)
        var notices: [String] = []
        if truncated {
            notices.append("会话文件过多，仅统计前 \(codexUsageMaxFiles) 个")
        }
        var readFailures = false

        for file in files {
            if let cached = caches[file.path],
               cached.size == file.size,
               cached.modified == file.modified {
                continue
            }
            let cached = caches[file.path]
            var offset = cached?.offset ?? 0
            if offset < 0 || offset > file.size {
                offset = 0
            }
            var result = CodexUsageFileResult(hasRecord: cached?.hasRecord ?? false,
                                              record: cached?.record ?? CodexUsageCounters(),
                                              fallback: cached?.fallback ?? CodexUsageCounters(),
                                              recordRecent: cached?.recordRecent ?? emptyCodexRecentCounters(),
                                              fallbackRecent: cached?.fallbackRecent ?? emptyCodexRecentCounters())
            if offset < file.size {
                guard let handle = try? FileHandle(forReadingFrom: file.url) else {
                    readFailures = true
                    continue
                }
                handle.seek(toFileOffset: UInt64(offset))
                let scanner = CodexUsageFileScanner(parser: parser, result: result)
                var read: Int64 = 0
                while true {
                    let chunk = handle.readData(ofLength: codexUsageReadChunk)
                    if chunk.isEmpty { break }
                    scanner.feed(chunk)
                    read += Int64(chunk.count)
                }
                handle.closeFile()
                result = scanner.result
                offset += read - Int64(scanner.uncommittedBytes)
                if offset < 0 { offset = 0 }
                if offset > file.size { offset = file.size }
            }
            caches[file.path] = FileCache(size: file.size, modified: file.modified,
                                          offset: offset, hasRecord: result.hasRecord,
                                          record: result.record, fallback: result.fallback,
                                          recordRecent: result.recordRecent,
                                          fallbackRecent: result.fallbackRecent)
        }

        if readFailures {
            notices.append("部分会话文件无法读取")
        }
        return ScanOutput(fileCaches: caches,
                          seen: parser.seenResponseIDs,
                          credits: parser.credits,
                          creditsDate: parser.creditsDate,
                          scannedFiles: files.count,
                          message: notices.isEmpty ? nil : notices.joined(separator: "；"),
                          available: true)
    }
}

// MARK: - Timestamp parsing

/// Manual ISO8601 `yyyy-MM-ddTHH:mm:ss[.fff]Z` parser. ISO8601DateFormatter costs
/// tens of microseconds per call, and a full scan parses tens of thousands of
/// timestamps, so the hot path avoids it.
private enum CodexISO8601 {
    static func parse(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count >= 20,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58 else { return nil }

        func digit(_ index: Int) -> Int? {
            let value = bytes[index]
            guard value >= 48, value <= 57 else { return nil }
            return Int(value - 48)
        }
        func number(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for index in start..<(start + count) {
                guard let part = digit(index) else { return nil }
                value = value * 10 + part
            }
            return value
        }

        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60 else { return nil }

        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= monthLengths[month - 1] else { return nil }

        var index = 19
        var fraction = 0.0
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            var scale = 0.1
            var digits = 0
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                digits += 1
                index += 1
            }
            guard digits > 0 else { return nil }
        }
        guard index == bytes.count - 1, bytes[index] == 90 else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + Int64(hour * 3_600 + minute * 60 + second)
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Days since 1970-01-01 (Howard Hinnant's civil-date algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        var adjustedYear = year
        if month <= 2 { adjustedYear -= 1 }
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let monthPrime = (month + 9) % 12
        let dayOfYear = (153 * monthPrime + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era) * 146_097 + Int64(dayOfEra) - 719_468
    }
}

// MARK: - Counters

private let codexUsageMaxLineBytes = 1 << 20      // 1 MiB
private let codexUsageMaxFiles = 2000
private let codexUsageReadChunk = 4 << 20          // 4 MiB
/// 面板趋势条固定 7 天（含今天）：0 = 6 天前，6 = 今天。
private let codexRecentDayCount = 7

private func emptyCodexRecentCounters() -> [CodexUsageCounters] {
    [CodexUsageCounters](repeating: CodexUsageCounters(), count: codexRecentDayCount)
}

private struct CodexUsageCounters {
    var output: Int64 = 0
    var input: Int64 = 0
    var cached: Int64 = 0

    /// Rejects the line instead of wrapping; token totals are far below Int64.max.
    mutating func add(output: Int64, input: Int64, cached: Int64) -> Bool {
        let o = self.output.addingReportingOverflow(output)
        let i = self.input.addingReportingOverflow(input)
        let c = self.cached.addingReportingOverflow(cached)
        guard !o.overflow, !i.overflow, !c.overflow else { return false }
        self.output = o.partialValue
        self.input = i.partialValue
        self.cached = c.partialValue
        return true
    }
}

private struct CodexUsageFileResult {
    var hasRecord = false
    var record = CodexUsageCounters()
    var fallback = CodexUsageCounters()
    var recordRecent: [CodexUsageCounters] = emptyCodexRecentCounters()
    var fallbackRecent: [CodexUsageCounters] = emptyCodexRecentCounters()
}

private struct CodexUsageDay {
    let year: Int
    let month: Int
    let day: Int

    init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }
}

// MARK: - Incremental byte scanner

/// Splits appended bytes into complete lines and parses only lines that can be a
/// token record, token count or credits record. The trailing partial line is left
/// uncommitted so the next refresh can read it again.
private final class CodexUsageFileScanner {
    private static let recordMarker = Data("\"token_usage_record\"".utf8)
    private static let tokenCountMarker = Data("\"token_count\"".utf8)

    private let parser: CodexUsageLineParser
    private var storedResult: CodexUsageFileResult
    private var line = Data()
    private var lineLength = 0
    private var skipping = false

    init(parser: CodexUsageLineParser, result: CodexUsageFileResult) {
        self.parser = parser
        self.storedResult = result
    }

    var result: CodexUsageFileResult { storedResult }
    /// Bytes of the incomplete trailing line: never committed to the parsed offset.
    var uncommittedBytes: Int { lineLength }

    func feed(_ chunk: Data) {
        chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let total = raw.count
            var cursor = 0
            while cursor < total {
                let pointer = base.advanced(by: cursor)
                guard let newline = memchr(pointer, 0x0A, total - cursor) else {
                    appendSegment(pointer, total - cursor)
                    return
                }
                let length = UnsafeRawPointer(newline) - pointer
                appendSegment(pointer, length)
                finishLine()
                cursor += length + 1
            }
        }
    }

    private func appendSegment(_ pointer: UnsafeRawPointer, _ count: Int) {
        guard count > 0 else { return }
        lineLength += count
        guard !skipping else { return }
        if lineLength > codexUsageMaxLineBytes {
            skipping = true
            line = Data()
            return
        }
        line.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: count))
    }

    private func finishLine() {
        if !skipping, !line.isEmpty,
           line.range(of: Self.recordMarker) != nil || line.range(of: Self.tokenCountMarker) != nil,
           let text = String(data: line, encoding: .utf8) {
            parser.consume(text, into: &storedResult)
        }
        line = Data()
        lineLength = 0
        skipping = false
    }
}

// MARK: - Line parser

private final class CodexUsageLineParser {
    private struct Envelope: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let usage: TokenUsage?
            let info: Info?
            let rate_limits: RateLimits?
            let response_id: String?
        }

        struct TokenUsage: Decodable {
            let input_tokens: Int64?
            let cached_input_tokens: Int64?
            let output_tokens: Int64?
        }

        struct Info: Decodable {
            let last_token_usage: TokenUsage?
        }

        struct RateLimits: Decodable {
            let credits: CreditPayload?
        }

        struct CreditPayload: Decodable {
            let has_credits: Bool?
            let unlimited: Bool?
            let balance: String?
        }
    }

    private let dayStart: Date
    private let dayEnd: Date
    /// 7 个本地自然日边界（旧→新），windowStarts[6] == dayStart。
    private let windowStarts: [Date]
    private let decoder = JSONDecoder()
    private let fractionalFormatter: ISO8601DateFormatter
    private let plainFormatter: ISO8601DateFormatter

    private(set) var seenResponseIDs: Set<String>
    private(set) var credits: CodexCredits?
    private(set) var creditsDate: Date?

    init(day: CodexUsageDay, timeZone: TimeZone,
         seen: Set<String>, credits: CodexCredits?, creditsDate: Date?) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        // One interval check per line instead of Calendar.dateComponents, which is
        // far too slow to run for every token record in a full scan.
        let start = local.date(from: components) ?? Date(timeIntervalSince1970: 0)
        self.dayStart = start
        self.dayEnd = local.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        var starts: [Date] = []
        starts.reserveCapacity(codexRecentDayCount)
        for offset in stride(from: codexRecentDayCount - 1, through: 0, by: -1) {
            starts.append(local.date(byAdding: .day, value: -offset, to: start) ?? start)
        }
        self.windowStarts = starts

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        self.fractionalFormatter = fractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plain.timeZone = TimeZone(secondsFromGMT: 0)
        self.plainFormatter = plain

        self.seenResponseIDs = seen
        self.credits = credits
        self.creditsDate = creditsDate
    }

    func consume(_ line: String, into result: inout CodexUsageFileResult) {
        guard !line.isEmpty else { return }
        let data = Data(line.utf8)
        guard data.count <= codexUsageMaxLineBytes else { return }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return }

        switch envelope.type {
        case "token_usage_record":
            // Presence of the preferred record type is per-file, independent of
            // whether this particular day/usage is valid: never double-count with
            // the token_count fallback.
            result.hasRecord = true
            consumeRecord(envelope, into: &result)
        case "event_msg":
            guard envelope.payload?.type == "token_count" else { return }
            consumeTokenCount(envelope, into: &result)
        default:
            return
        }
    }

    private func consumeRecord(_ envelope: Envelope, into result: inout CodexUsageFileResult) {
        guard let payload = envelope.payload,
              let usage = payload.usage,
              let timestamp = date(from: envelope.timestamp),
              let index = windowIndex(timestamp) else { return }
        let input = usage.input_tokens ?? 0
        let output = usage.output_tokens ?? 0
        let cached = usage.cached_input_tokens ?? 0
        guard input >= 0, output >= 0, cached >= 0 else { return }

        var responseID: String?
        if let value = payload.response_id, !value.isEmpty {
            if seenResponseIDs.contains(value) { return }
            responseID = value
        }
        var bucket = result.recordRecent[index]
        guard bucket.add(output: output, input: input, cached: cached) else { return }
        var today = result.record
        if index == codexRecentDayCount - 1 {
            guard today.add(output: output, input: input, cached: cached) else { return }
        }
        result.recordRecent[index] = bucket
        if index == codexRecentDayCount - 1 { result.record = today }
        if let responseID = responseID {
            seenResponseIDs.insert(responseID)
        }
    }

    private func consumeTokenCount(_ envelope: Envelope, into result: inout CodexUsageFileResult) {
        guard let payload = envelope.payload,
              let timestamp = date(from: envelope.timestamp) else { return }

        // Credits are independent of the day being aggregated: keep the newest
        // observation in the batch (or in the retained incremental state).
        if let raw = payload.rate_limits?.credits,
           let hasCredits = raw.has_credits,
           let balance = raw.balance {
            let unlimited = raw.unlimited ?? false
            if creditsDate == nil || timestamp >= creditsDate! {
                credits = CodexCredits(balance: balance, hasCredits: hasCredits,
                                       unlimited: unlimited, observedAt: timestamp)
                creditsDate = timestamp
            }
        }

        guard let index = windowIndex(timestamp),
              let last = payload.info?.last_token_usage else { return }
        let input = last.input_tokens ?? 0
        let output = last.output_tokens ?? 0
        let cached = last.cached_input_tokens ?? 0
        guard input >= 0, output >= 0, cached >= 0 else { return }
        var bucket = result.fallbackRecent[index]
        guard bucket.add(output: output, input: input, cached: cached) else { return }
        var today = result.fallback
        if index == codexRecentDayCount - 1 {
            guard today.add(output: output, input: input, cached: cached) else { return }
        }
        result.fallbackRecent[index] = bucket
        if index == codexRecentDayCount - 1 { result.fallback = today }
    }

    private func date(from string: String?) -> Date? {
        guard let string = string, !string.isEmpty else { return nil }
        if let fast = CodexISO8601.parse(string) { return fast }
        // Slow path for timestamps that are not the canonical Z form.
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    /// 0 = 6 天前 ... 6 = 今天；窗口外返回 nil。
    private func windowIndex(_ date: Date) -> Int? {
        guard date >= windowStarts[0], date < dayEnd else { return nil }
        var index = codexRecentDayCount - 1
        while index > 0, date < windowStarts[index] { index -= 1 }
        return index
    }
}
