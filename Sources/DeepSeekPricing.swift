import Foundation

/// DeepSeek 官方计费时段：北京时间工作日 09:00–12:00、14:00–18:00 为高峰，
/// 其余时间（含周末与法定节假日）为闲时。
///
/// 工作日与节假日来自 `DeepSeekHolidayTable`：内置已公布年份，缺失年份联网补齐。
/// 拿不到某年的表时，工作日高峰候选时段返回 `.unknown`，宁可显示中性图标，
/// 也不把未知日期当成高峰。
enum DeepSeekPricePhase: Equatable {
    case peak
    case offPeak
    case unknown
}

enum DeepSeekPricingClock {

    static let beijing = TimeZone(identifier: "Asia/Shanghai")!

    /// 测试可替换：按年份提供节假日表。生产环境读本地商店（内置 + 缓存 + 远程）。
    static var tableLookup: (Int) -> DeepSeekHolidayTable? = { DeepSeekHolidayStore.shared.table(for: $0) }

    static func phase(at date: Date = Date()) -> DeepSeekPricePhase {
        phase(at: date, table: tableLookup)
    }

    static func phase(at date: Date, table: (Int) -> DeepSeekHolidayTable?) -> DeepSeekPricePhase {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else {
            return .unknown
        }

        // 时段之外一律闲时，与年份、节假日无关。
        let currentMinute = hour * 60 + minute
        let morning = (9 * 60)..<(12 * 60)
        let afternoon = (14 * 60)..<(18 * 60)
        guard morning.contains(currentMinute) || afternoon.contains(currentMinute) else { return .offPeak }

        let dateKey = String(format: "%04d-%02d-%02d", year, month, day)
        guard let table = table(year) else { return .unknown }

        if table.offDays.contains(dateKey) { return .offPeak }
        // 调休上班的周末按工作日计费；没有证据的周末仍是闲时。
        if weekday == 1 || weekday == 7 {
            return table.workdays.contains(dateKey) ? .peak : .offPeak
        }
        return .peak
    }

    /// 距离下一个时段边界还有多久，供定时器挑选重绘时机。
    static func secondsUntilNextBoundary(from date: Date = Date()) -> TimeInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return nil }
        let now = TimeInterval(hour * 3600 + minute * 60 + second)
        let boundaries: [TimeInterval] = [9, 12, 14, 18].map { TimeInterval($0 * 3600) }
        // 18:00 之后的下一个边界是次日 09:00。
        if let next = boundaries.first(where: { $0 > now }) { return next - now }
        return 24 * 3600 - now + 9 * 3600
    }
}
