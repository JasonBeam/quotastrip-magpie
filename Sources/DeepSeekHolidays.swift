import Foundation

/// 一年份的中国法定节假日表：`offDays` 为放假日期，`workdays` 为调休上班日期。
/// 数据来自国务院办公厅公布的放假安排（经 NateScarlet/holiday-cn 整理）。
struct DeepSeekHolidayTable: Equatable {
    let year: Int
    let offDays: Set<String>
    let workdays: Set<String>
    /// `bundled` / `cached` / `remote`，用于菜单里说明数据来源。
    let source: String
}

enum DeepSeekHolidayParser {
    struct Failure: Error {}

    static let maximumBytes = 256 * 1024

    private struct Payload: Decodable {
        let year: Int
        let days: [Day]
        struct Day: Decodable { let date: String; let isOffDay: Bool }
    }

    /// 严格解析：年份必须匹配、日期必须是合法的 `yyyy-MM-dd`、条数有上限。
    static func parse(_ data: Data, expectedYear: Int, source: String) throws -> DeepSeekHolidayTable {
        guard data.count <= maximumBytes, !data.isEmpty else { throw Failure() }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.year == expectedYear, !payload.days.isEmpty, payload.days.count <= 400 else { throw Failure() }

        var offDays = Set<String>()
        var workdays = Set<String>()
        for day in payload.days {
            guard isDate(day.date, year: expectedYear) else { throw Failure() }
            if day.isOffDay {
                offDays.insert(day.date)
            } else {
                workdays.insert(day.date)
            }
        }
        guard !offDays.isEmpty else { throw Failure() }
        return DeepSeekHolidayTable(year: payload.year, offDays: offDays, workdays: workdays, source: source)
    }

    static func isDate(_ text: String, year: Int) -> Bool {
        guard text.count == 10, text.hasPrefix(String(year) + "-") else { return false }
        let parts = text.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return false }
        return true
    }
}

/// 节假日表按年缓存：优先用 App 内置的已公布年份，缺失的年份才联网获取，
/// 取到的数据写入 Application Support，离线时继续可用；获取失败只影响未来的年份，
/// 判断结果退化为 `.unknown`，不会误判成高峰。
final class DeepSeekHolidayStore {
    static let shared = DeepSeekHolidayStore()

    /// 带年份的官方原文链接，仅用于菜单展示来源。
    private(set) var tables: [Int: DeepSeekHolidayTable] = [:]
    /// 主线程回调：表格变化后重绘 Touch Bar。
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "app.quotastrip.holidays")
    private var lastAttempt: Date?
    private var inFlight = false

    static let remoteBase = URL(string: "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/")!

    private init() {}

    var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("QuotaStrip/holidays", isDirectory: true)
    }

    func table(for year: Int) -> DeepSeekHolidayTable? { tables[year] }

    func availableYears() -> [Int] { tables.keys.sorted() }

    /// 读取内置表与本地缓存，不会联网。
    func loadLocal(bundle: Bundle = .main) {
        for year in 2026...2030 {
            let name = "deepseek-holidays-\(year)"
            if let url = bundle.url(forResource: name, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let table = try? DeepSeekHolidayParser.parse(data, expectedYear: year, source: "bundled") {
                tables[year] = table
            }
        }
        loadCached()
    }

    private func loadCached() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                      includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let year = Int(name), tables[year] == nil,
                  let data = try? Data(contentsOf: file),
                  let table = try? DeepSeekHolidayParser.parse(data, expectedYear: year, source: "cached") else { continue }
            tables[year] = table
        }
    }

    /// 需要哪一年：北京时间当前年与下一年（好让 12 月就拿到次年的表）。
    private static func neededYears(now: Date) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DeepSeekPricingClock.beijing
        let year = calendar.component(.year, from: now)
        return [year, year + 1]
    }

    /// 只在缺表且距上次尝试超过 24 小时时联网；重复调用代价很低。
    func refreshIfNeeded(now: Date = Date()) {
        DispatchQueue.main.async { self.refreshOnMain(now: now, force: false) }
    }

    func forceRefresh(now: Date = Date()) {
        DispatchQueue.main.async { self.refreshOnMain(now: now, force: true) }
    }

    private func refreshOnMain(now: Date, force: Bool) {
        guard !inFlight else { return }
        if !force, let lastAttempt = lastAttempt, now.timeIntervalSince(lastAttempt) < 24 * 3600 { return }
        let missing = Self.neededYears(now: now).filter { tables[$0] == nil }
        guard !missing.isEmpty else { return }
        inFlight = true
        lastAttempt = now

        queue.async { [weak self] in
            guard let self = self else { return }
            var updates: [DeepSeekHolidayTable] = []
            for year in missing {
                if let table = self.fetch(year: year) { updates.append(table) }
            }
            DispatchQueue.main.async {
                self.inFlight = false
                guard !updates.isEmpty else { return }
                for table in updates { self.tables[table.year] = table }
                self.onChange?()
            }
        }
    }

    /// 同步抓取单年数据；调用方已在后台队列。
    private func fetch(year: Int) -> DeepSeekHolidayTable? {
        let url = Self.remoteBase.appendingPathComponent("\(year).json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)

        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse?)?
        session.dataTask(with: request) { data, response, _ in
            if let data = data, data.count <= DeepSeekHolidayParser.maximumBytes { result = (data, response) }
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + 30) == .timedOut { session.invalidateAndCancel(); return nil }
        session.finishTasksAndInvalidate()

        guard let (data, response) = result,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let table = try? DeepSeekHolidayParser.parse(data, expectedYear: year, source: "remote") else { return nil }

        // 缓存原文，离线或下次启动时仍可用；写入失败不影响本次判断。
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheDirectory.appendingPathComponent("\(year).json"), options: .atomic)
        return table
    }
}
