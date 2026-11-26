#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Checks the DeepSeek peak/off-peak clock and the holiday-table parser.

Two rules matter: workdays 09:00-12:00 and 14:00-18:00 (Beijing) are peak, holidays
are off-peak, and a year without a verified table must never report peak. Pure data
and date maths: no network, no files outside a temp dir.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources" / "DeepSeekPricing.swift",
    ROOT / "Sources" / "DeepSeekHolidays.swift",
]

MAIN = r'''
import Foundation

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL:", label) }
}
func at(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

// The parser is fed the same JSON shape the app bundles / downloads.
func parse(_ text: String, year: Int, source: String = "bundled") -> DeepSeekHolidayTable? {
    try? DeepSeekHolidayParser.parse(Data(text.utf8), expectedYear: year, source: source)
}
let table2026 = parse(#"{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true},{"name":"春节","date":"2026-02-17","isOffDay":true},{"name":"国庆节","date":"2026-10-01","isOffDay":true},{"name":"春节","date":"2026-02-14","isOffDay":false},{"name":"国庆节","date":"2026-10-10","isOffDay":false}]}"#, year: 2026)
expect(table2026 != nil, "bundled table parses")
expect(table2026?.offDays.contains("2026-10-01") == true, "off day parsed")
expect(table2026?.workdays.contains("2026-10-10") == true, "make-up workday parsed")
expect(parse(#"{"year":2025,"days":[{"date":"2026-01-01","isOffDay":true}]}"#, year: 2026) == nil, "wrong year rejected")
expect(parse(#"{"year":2026,"days":[]}"#, year: 2026) == nil, "empty table rejected")
expect(parse(#"{"year":2026,"days":[{"date":"2026-1-1","isOffDay":true}]}"#, year: 2026) == nil, "bad date rejected")
expect(parse(#"{"year":2026,"days":[{"date":"2026-01-01"}]}"#, year: 2026) == nil, "missing flag rejected")
expect(parse(String(repeating: " ", count: 256 * 1024 + 1), year: 2026) == nil, "payload bound enforced")
let unknownYearTable = parse(#"{"year":2027,"days":[{"date":"2027-01-01","isOffDay":true}]}"#, year: 2027)
expect(unknownYearTable?.offDays.contains("2027-01-01") == true, "2027 table parses once available")

let lookup: (Int) -> DeepSeekHolidayTable? = { year in
    switch year {
    case 2026: return table2026
    case 2027: return unknownYearTable
    default: return nil
    }
}
func phase(_ text: String) -> DeepSeekPricePhase {
    DeepSeekPricingClock.phase(at: at(text), table: lookup)
}

// 2026-11-13 is a Friday.
expect(phase("2026-11-13 08:59") == .offPeak, "before 09:00 is off-peak")
expect(phase("2026-11-13 09:00") == .peak, "09:00 opens the morning peak")
expect(phase("2026-11-13 11:59") == .peak, "morning peak runs to 11:59")
expect(phase("2026-11-13 12:00") == .offPeak, "12:00 closes the morning peak")
expect(phase("2026-11-13 13:30") == .offPeak, "lunch is off-peak")
expect(phase("2026-11-13 14:00") == .peak, "14:00 opens the afternoon peak")
expect(phase("2026-11-13 17:59") == .peak, "afternoon peak runs to 17:59")
expect(phase("2026-11-13 18:00") == .offPeak, "18:00 closes the afternoon peak")

// Weekend: no table entry means off-peak, a make-up workday means peak.
expect(phase("2026-11-14 10:00") == .offPeak, "ordinary saturday is off-peak")
expect(phase("2026-02-14 10:00") == .peak, "make-up workday on a saturday is peak")
expect(phase("2026-10-10 15:00") == .peak, "make-up workday counts inside the afternoon window")
expect(phase("2026-10-10 19:00") == .offPeak, "make-up workday is off-peak outside the window")

// Holidays win over weekdays.
expect(phase("2026-10-01 10:00") == .offPeak, "national day is off-peak")
expect(phase("2026-01-01 10:00") == .offPeak, "new year is off-peak")
expect(phase("2026-10-09 10:00") == .peak, "the workday after the holiday is peak")

// Unknown years: no table, no peak claim; outside the window still off-peak.
expect(phase("2028-01-04 10:00") == .unknown, "2028 weekday peak window is unknown")
expect(phase("2028-01-04 13:00") == .offPeak, "2028 outside the window is off-peak")
// The 2027 sample table has no entry for 2027-02-15 (a Monday), so it is peak.
expect(phase("2027-02-15 10:00") == .peak, "ordinary 2027 monday is peak once the table exists")

let remaining = DeepSeekPricingClock.secondsUntilNextBoundary(from: at("2026-11-13 13:00")) ?? -1
expect(remaining == 3600, "13:00 is one hour from the 14:00 boundary")
let closed = DeepSeekPricingClock.secondsUntilNextBoundary(from: at("2026-11-13 19:00")) ?? -1
expect(closed == 14 * 3600, "19:00 counts to the next day's 09:00")

print(failures == 0 ? "PASS: \(checks) pricing and holiday checks"
                    : "FAIL: \(failures)/\(checks) pricing and holiday checks")
exit(failures == 0 ? 0 : 1)
'''


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="quotastrip-pricing-") as folder:
        path = pathlib.Path(folder) / "main.swift"
        path.write_text(MAIN, encoding="utf-8")
        binary = pathlib.Path(folder) / "pricing"
        build = subprocess.run([*SWIFTC_CMD, "-swift-version", "5"] + [str(s) for s in SOURCES] + [str(path), "-o", str(binary)],
                               capture_output=True, text=True, timeout=240)
        if build.returncode != 0:
            sys.stderr.write(build.stderr)
            return 1
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
