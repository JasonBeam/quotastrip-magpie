#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Compiles the shipped top-up-round logic straight out of Sources/ and checks it.

The declarations are extracted by brace balance (not copied), so a regression in
Sources/main.swift or Sources/DeepSeekTouchBarView.swift fails this test. No network,
no Keychain, no real defaults domain: the harness supplies its own storage.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VIEW = ROOT / "Sources" / "DeepSeekTouchBarView.swift"
DSH = ROOT / "Sources" / "DSHBalanceProvider.swift"
MAIN = ROOT / "Sources" / "main.swift"


def extract(path: pathlib.Path, marker: str) -> str:
    text = path.read_text(encoding="utf-8")
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise SystemExit(f"unbalanced braces around {marker!r} in {path.name}")


def as_test_member(block: str) -> str:
    """private -> internal and UserDefaults.standard -> harness storage, inside the same type."""
    block = block.replace("private ", "")
    block = block.replace("UserDefaults.standard.data(forKey:", "defaultsData(")
    block = block.replace("UserDefaults.standard.set(data, forKey:", "setData(data,")
    block = block.replace("UserDefaults.standard.removeObject(forKey:", "remove(")
    return block


def view_logic() -> str:
    block = "\n".join([
        extract(VIEW, "    enum Round {"),
        extract(VIEW, "    private func effectiveStartingBalance() -> Decimal? {"),
        extract(VIEW, "    func round() -> Round {"),
        extract(VIEW, "    private var remainingRatio: Decimal? {"),
    ])
    return as_test_member(block)


def round_logic() -> str:
    block = "\n".join([
        extract(MAIN, "    private struct TopUpRound: Codable {"),
        extract(MAIN, "    private func roundKey(_ currency: String) -> String {"),
        extract(MAIN, "    private var currentRound: TopUpRound? {"),
        extract(MAIN, "    private func storeRound(_ round: TopUpRound, currency: String? = nil) {"),
        extract(MAIN, "    private func decimalString(_ value: Decimal) -> String {"),
        extract(MAIN, "    private func updateTopUpRound(balance: Decimal?, stale: Bool) {"),
        extract(MAIN, "    private var currentStartingBalance: Decimal? {"),
        extract(MAIN, "    private func effectiveStartingBalance() -> Decimal? {"),
    ])
    return as_test_member(block)


SNAPSHOT = extract(DSH, "struct DeepSeekSnapshot {")

HARNESS = r"""
import AppKit

SNAPSHOT_CODE

func d(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

final class Painter {
    var snapshot: DeepSeekSnapshot?
    static let blue = NSColor.systemBlue
    static let smallAmount = d("0.01")
    static func amount(_ value: Decimal?, currency: String) -> String { "x" }
    static func tokens(_ count: Int64?) -> String { "0" }
VIEW_LOGIC
}

final class Rounds {
    var deepSeekSnapshot = DeepSeekSnapshot()
    var storage: [String: Any] = [:]
    func defaultsData(_ key: String) -> Data? { storage[key] as? Data }
    func setData(_ value: Data?, _ key: String) { storage[key] = value }
    func remove(_ key: String) { storage.removeValue(forKey: key) }
ROUND_LOGIC
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard condition() else { print("FAIL: \(name)"); exit(1) }
}

let painter = Painter()
func pct(_ balance: String?, starting: String?) -> String {
    var snap = DeepSeekSnapshot()
    snap.balance = balance.map(d)
    snap.startingBalance = starting.map(d)
    painter.snapshot = snap
    switch painter.round() {
    case .known(_, let value): return "\(value)%"
    case .waiting: return "waiting"
    case .unknown: return "unknown"
    }
}

// The table from the user's request: 20 / 20 / 15 / 10 / 5 / 0.
check(pct("20", starting: "20") == "100%", "20 of 20 = 100%")
check(pct("15", starting: "20") == "75%", "15 of 20 = 75%")
check(pct("10", starting: "20") == "50%", "10 of 20 = 50%")
check(pct("5", starting: "20") == "25%", "5 of 20 = 25%")
check(pct("0", starting: "20") == "0%", "0 of 20 = 0%")
check(pct("19.99", starting: "20") == "99%", "rounding never inflates")
check(pct("0.009", starting: "20") == "0%", "tiny balance stays 0%")
check(pct("10.10", starting: "10.10") == "100%", "decimal equality")
// Never above 100% and never negative.
check(pct("25", starting: "20") == "waiting", "balance above start waits for the new round")
check(pct("100", starting: "20") == "waiting", "never over 100%")
check(pct("-1", starting: "20") == "0%", "negative clamps to 0%")
// Unknown stays unknown; zero-start is not a denominator.
check(pct(nil, starting: "20") == "unknown", "no balance is unknown")
check(pct("10", starting: nil) == "unknown", "no start is unknown")
check(pct("10", starting: "0") == "unknown", "zero start is not a denominator")
check(pct(nil, starting: nil) == "unknown", "empty snapshot is unknown")

// Unknown must not be drawn as an empty (0%) track.
func ratio(_ balance: String?, starting: String?) -> Decimal? {
    var snap = DeepSeekSnapshot()
    snap.balance = balance.map(d)
    snap.startingBalance = starting.map(d)
    painter.snapshot = snap
    return painter.remainingRatio
}
check(ratio("10", starting: "20") != nil, "known ratio present")
check(ratio("10", starting: nil) == nil, "unknown hides the fill")
check(ratio("30", starting: "20") == nil, "waiting hides the fill")

// Round detection: first sighting, deposit, stale readings, currency isolation.
let rounds = Rounds()
func observe(_ balance: String?, stale: Bool = false) {
    rounds.deepSeekSnapshot.balance = balance.map(d)
    rounds.updateTopUpRound(balance: rounds.deepSeekSnapshot.balance, stale: stale)
    rounds.deepSeekSnapshot.startingBalance = rounds.effectiveStartingBalance()
}
observe("10")
check(rounds.effectiveStartingBalance() == d("10"), "first sighting records the current balance as the round start")
check(rounds.currentRound?.startSource == "auto", "the automatic baseline is labelled as such")
observe("4")
check(rounds.effectiveStartingBalance() == d("10"), "spending keeps the recorded baseline")
check(rounds.currentRound?.startBalance == "10", "baseline is not rewritten by spending")
observe("30", stale: true)
check(rounds.currentRound?.lastSeen == "4", "a stale reading never rewrites the last fresh balance")
check(rounds.currentRound?.startBalance == "10", "a stale reading never opens a round")
observe("21")
check(rounds.effectiveStartingBalance() == d("21"), "a deposit opens a new round at the post-deposit balance")
check((rounds.currentRound?.amount ?? "?") == "17", "deposit amount is the rise since the last reading")
check(rounds.currentRound?.startBalance == "21", "round starts at the balance after the deposit")
check(rounds.currentRound?.startSource == "topup", "a detected deposit is labelled as a top-up")
observe("20.5")
check(rounds.effectiveStartingBalance() == d("21"), "new round baseline holds")
check(rounds.currentRound?.lastSeen == "20.5", "last fresh reading follows spending")
// A balance above the stored start without a fresh refresh must show waiting, not a fake round.
rounds.deepSeekSnapshot.balance = d("40")
check(rounds.effectiveStartingBalance() == nil, "unrecorded deposit hides the bar")
rounds.deepSeekSnapshot.balance = d("10")
check(rounds.effectiveStartingBalance() == d("21"), "known start at or above balance is used")
rounds.storage.removeAll()
rounds.deepSeekSnapshot.balance = d("10")
observe("10")
check(rounds.effectiveStartingBalance() == d("10"), "a fresh first sighting seeds the round so the bar has progress")
check(rounds.currentRound?.lastSeen == "10", "first sighting records the last reading")
check(rounds.currentRound?.startBalance == "10", "first sighting stores the observed balance as the baseline")
observe(nil)
check(rounds.currentRound?.lastSeen == "10", "missing balance keeps the last reading")

// Manual baseline (what the menu dialog writes) is authoritative until a deposit is seen.
rounds.storage.removeAll()
rounds.deepSeekSnapshot.balance = d("12")
rounds.storeRound(Rounds.TopUpRound(startBalance: "20", amount: nil, lastSeen: "20"))
check(rounds.currentStartingBalance == d("20"), "stored baseline is read back")
check(rounds.effectiveStartingBalance() == d("20"), "stored baseline drives the bar")
rounds.deepSeekSnapshot.balance = d("25")
check(rounds.effectiveStartingBalance() == nil, "balance above the baseline waits for the next refresh")

print("PASS: \(checks) top-up round checks (shipped code extracted, no network, no defaults writes)")
"""


def main() -> int:
    source = (
        "import AppKit\nimport Foundation\n\n"
        + HARNESS.replace("SNAPSHOT_CODE", SNAPSHOT).replace("VIEW_LOGIC", view_logic()).replace("ROUND_LOGIC", round_logic())
    )
    with tempfile.TemporaryDirectory(prefix="quotastrip-round-") as folder:
        path = pathlib.Path(folder) / "main.swift"
        path.write_text(source, encoding="utf-8")
        binary = pathlib.Path(folder) / "rounds"
        compile_result = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", str(path), "-o", str(binary)],
            capture_output=True, text=True, timeout=180)
        if compile_result.returncode != 0:
            sys.stderr.write(compile_result.stderr)
            return 1
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
