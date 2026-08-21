import XCTest
import Foundation
@testable import QuotaCore

/// Covers `Formatting.swift`: the urgency thresholds every front-end colours by,
/// the percentage and reset wording shared between macOS and Linux, the ASCII
/// usage bar, and the waybar payload. Percentages arrive from untrusted CLI
/// output, so the clamping paths are exercised alongside the ordinary ones.
final class FormattingTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(_ provider: Provider, _ window: String, _ used: Double?,
                     reset: String = "", error: String? = nil) -> QuotaRow {
        QuotaRow(provider: provider, window: window, usedPercent: used,
                 percentText: used.map(QuotaFormatting.percent) ?? "—",
                 resetText: reset, urgency: used.map(QuotaUrgency.init(usedPercent:)) ?? .normal,
                 error: error)
    }

    /// The bytes a status bar actually reads, keys sorted the way
    /// `Output.waybar` sorts them.
    private func encoded(_ payload: WaybarPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    // MARK: - QuotaUrgency

    /// The thresholds are exact: 80 warns, 95 is critical, and the value just
    /// below each boundary must stay in the lower band.
    func testUrgencyAtEveryBoundary() {
        let cases: [(Double, QuotaUrgency)] = [
            (-100, .normal), (0, .normal), (79, .normal), (79.99, .normal),
            (80, .warning), (80.01, .warning), (87.5, .warning), (94.99, .warning),
            (95, .critical), (95.01, .critical), (100, .critical), (250, .critical)
        ]
        for (value, expected) in cases {
            XCTAssertEqual(QuotaUrgency(usedPercent: value), expected, "usedPercent \(value)")
        }
    }

    func testUrgencyRawValuesAreTheStableClassNames() throws {
        XCTAssertEqual(QuotaUrgency.normal.rawValue, "normal")
        XCTAssertEqual(QuotaUrgency.warning.rawValue, "warning")
        XCTAssertEqual(QuotaUrgency.critical.rawValue, "critical")
        for urgency in [QuotaUrgency.normal, .warning, .critical] {
            let data = try JSONEncoder().encode(urgency)
            XCTAssertEqual(try JSONDecoder().decode(QuotaUrgency.self, from: data), urgency)
        }
    }

    // MARK: - percent

    func testPercentPrintsWholeNumbersWithoutADecimal() {
        XCTAssertEqual(QuotaFormatting.percent(0), "0%")
        XCTAssertEqual(QuotaFormatting.percent(23), "23%")
        XCTAssertEqual(QuotaFormatting.percent(100), "100%")
    }

    /// Values within 0.05 of an integer collapse onto it; anything further out
    /// keeps a single decimal so a 42.5% reading is not shown as 43%.
    func testPercentRoundingEdges() {
        XCTAssertEqual(QuotaFormatting.percent(23.02), "23%")
        XCTAssertEqual(QuotaFormatting.percent(22.98), "23%")
        XCTAssertEqual(QuotaFormatting.percent(99.99), "100%")
        XCTAssertEqual(QuotaFormatting.percent(0.02), "0%")

        XCTAssertEqual(QuotaFormatting.percent(42.5), "42.5%")
        XCTAssertEqual(QuotaFormatting.percent(23.2), "23.2%")
        XCTAssertEqual(QuotaFormatting.percent(23.06), "23.1%")
        XCTAssertEqual(QuotaFormatting.percent(0.4), "0.4%")
        XCTAssertEqual(QuotaFormatting.percent(99.9), "99.9%")
        XCTAssertEqual(QuotaFormatting.percent(33.333), "33.3%")
        XCTAssertEqual(QuotaFormatting.percent(66.666), "66.7%")
    }

    /// CLI output is untrusted, so out-of-range readings are clamped rather than
    /// rendered as negative or above-100 percentages.
    func testPercentClampsOutOfRangeReadings() {
        XCTAssertEqual(QuotaFormatting.percent(-0.5), "0%")
        XCTAssertEqual(QuotaFormatting.percent(-1_000), "0%")
        XCTAssertEqual(QuotaFormatting.percent(100.4), "100%")
        XCTAssertEqual(QuotaFormatting.percent(9_999), "100%")
        XCTAssertEqual(QuotaFormatting.percent(.infinity), "100%")
        XCTAssertEqual(QuotaFormatting.percent(-.infinity), "0%")
    }

    // MARK: - relativeReset

    func testRelativeResetForNowAndThePast() {
        XCTAssertEqual(QuotaFormatting.relativeReset(epoch, from: epoch), "now")
        XCTAssertEqual(QuotaFormatting.relativeReset(epoch.addingTimeInterval(-1), from: epoch), "now")
        XCTAssertEqual(QuotaFormatting.relativeReset(epoch.addingTimeInterval(-86_400), from: epoch), "now")
        XCTAssertEqual(QuotaFormatting.relativeReset(epoch.addingTimeInterval(0.4), from: epoch), "now",
                       "sub-second remainders round down to zero")
    }

    func testRelativeResetUnderAMinute() {
        XCTAssertEqual(QuotaFormatting.relativeReset(epoch.addingTimeInterval(1), from: epoch), "in under a minute")
        XCTAssertEqual(QuotaFormatting.relativeReset(epoch.addingTimeInterval(30), from: epoch), "in under a minute")
        XCTAssertEqual(QuotaFormatting.relativeReset(epoch.addingTimeInterval(59), from: epoch), "in under a minute")
        XCTAssertEqual(QuotaFormatting.relativeReset(epoch.addingTimeInterval(59.4), from: epoch), "in under a minute")
    }

    func testRelativeResetMinutesHoursAndDays() {
        // Spelled as literals rather than arithmetic: the mixed-expression form
        // compiles on Linux but exceeds the macOS type-checker's budget, which
        // fails the build rather than a test.
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400
        var cases: [(TimeInterval, String)] = []
        cases.append((minute, "in 1m"))
        cases.append((119, "in 1m"))
        cases.append((30 * minute, "in 30m"))
        cases.append((59 * minute, "in 59m"))
        cases.append((hour, "in 1h"))
        cases.append((3_659, "in 1h"))
        cases.append((hour + 2 * minute, "in 1h 2m"))
        cases.append((2 * hour + 15 * minute, "in 2h 15m"))
        cases.append((day, "in 1d"))
        cases.append((day + 3_599, "in 1d"))
        cases.append((day + hour, "in 1d 1h"))
        cases.append((3 * day + 4 * hour + 30 * minute, "in 3d 4h"))
        cases.append((10 * day, "in 10d"))
        for (offset, expected) in cases {
            XCTAssertEqual(QuotaFormatting.relativeReset(epoch.addingTimeInterval(offset), from: epoch), expected,
                           "offset \(offset)")
        }
    }

    // MARK: - rows

    func testRowsFlattenWindowsAndKeepFailedProvidersVisible() {
        let snapshots = [
            QuotaSnapshot(provider: .gemini,
                          windows: [QuotaWindow(label: "Pro", usedPercent: 96, resetAt: epoch.addingTimeInterval(2 * 3_600)),
                                    QuotaWindow(label: "Flash", usedPercent: 10, resetAt: nil)]),
            QuotaSnapshot(provider: .claude, windows: [], error: "claude is not installed", probeSucceeded: false),
            QuotaSnapshot(provider: .codex, windows: [], probeSucceeded: false)
        ]
        let rows = QuotaFormatting.rows(for: snapshots, now: epoch)
        XCTAssertEqual(rows.count, 4)

        XCTAssertEqual(rows[0].window, "Pro")
        XCTAssertEqual(rows[0].percentText, "96%")
        XCTAssertEqual(rows[0].resetText, "resets in 2h")
        XCTAssertEqual(rows[0].urgency, .critical)
        XCTAssertNil(rows[0].error)

        XCTAssertEqual(rows[1].resetText, "", "a window without a reset time gets no reset text")
        XCTAssertEqual(rows[1].urgency, .normal)

        XCTAssertEqual(rows[2].provider, .claude)
        XCTAssertNil(rows[2].usedPercent)
        XCTAssertEqual(rows[2].percentText, "—")
        XCTAssertEqual(rows[2].error, "claude is not installed")

        XCTAssertEqual(rows[3].provider, .codex)
        XCTAssertEqual(rows[3].error, "No quota data", "a silent failure still needs a reason")
    }

    func testRowsCarryTheSnapshotErrorOntoCachedWindows() {
        let snapshot = QuotaSnapshot(provider: .codex,
                                     windows: [QuotaWindow(label: "Session", usedPercent: 12, resetAt: nil)],
                                     error: "Refresh failed: timed out", probeSucceeded: false)
        let rows = QuotaFormatting.rows(for: [snapshot], now: epoch)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].usedPercent, 12)
        XCTAssertEqual(rows[0].error, "Refresh failed: timed out")
    }

    func testRowsForNoSnapshotsIsEmpty() {
        XCTAssertTrue(QuotaFormatting.rows(for: [], now: epoch).isEmpty)
    }

    // MARK: - bar

    func testBarFillsProportionallyAndClamps() {
        XCTAssertEqual(QuotaFormatting.bar(0), "░░░░░░░░░░")
        XCTAssertEqual(QuotaFormatting.bar(50), "█████░░░░░")
        XCTAssertEqual(QuotaFormatting.bar(45), "█████░░░░░", "a half block rounds away from zero")
        XCTAssertEqual(QuotaFormatting.bar(44), "████░░░░░░")
        XCTAssertEqual(QuotaFormatting.bar(100), "██████████")
        XCTAssertEqual(QuotaFormatting.bar(-20), "░░░░░░░░░░")
        XCTAssertEqual(QuotaFormatting.bar(1_000), "██████████")
    }

    func testBarWithoutAReadingIsAllDots() {
        XCTAssertEqual(QuotaFormatting.bar(nil), "··········")
        XCTAssertEqual(QuotaFormatting.bar(nil, width: 3), "···")
        XCTAssertEqual(QuotaFormatting.bar(nil, width: 0), "")
    }

    func testBarAtWidthExtremes() {
        XCTAssertEqual(QuotaFormatting.bar(50, width: 0), "")
        XCTAssertEqual(QuotaFormatting.bar(100, width: 0), "")
        XCTAssertEqual(QuotaFormatting.bar(49, width: 1), "░")
        XCTAssertEqual(QuotaFormatting.bar(50, width: 1), "█")
        XCTAssertEqual(QuotaFormatting.bar(100, width: 1), "█")
        XCTAssertEqual(QuotaFormatting.bar(0, width: 1), "░")
        XCTAssertEqual(QuotaFormatting.bar(3, width: 40), String(repeating: "█", count: 1) + String(repeating: "░", count: 39))
    }

    func testBarAlwaysHasExactlyTheRequestedWidth() {
        for width in [0, 1, 2, 7, 10, 33] {
            for reading in [nil, -50, 0, 0.4, 33.3, 50, 99.6, 100, 400] as [Double?] {
                XCTAssertEqual(QuotaFormatting.bar(reading, width: width).count, width,
                               "width \(width), reading \(String(describing: reading))")
            }
        }
    }

    // MARK: - mostUrgent

    func testMostUrgentPicksTheHighestReading() {
        let rows = [row(.gemini, "Flash", 10), row(.codex, "Session", 87.5), row(.claude, "Weekly", 42)]
        XCTAssertEqual(QuotaFormatting.mostUrgent(rows)?.provider, .codex)
    }

    func testMostUrgentIgnoresRowsWithoutAReading() {
        let rows = [row(.gemini, "—", nil, error: "gemini is not installed"), row(.claude, "Weekly", 3)]
        XCTAssertEqual(QuotaFormatting.mostUrgent(rows)?.provider, .claude)
    }

    /// A bar with nothing to report says "n/a"; it must never elect a row that
    /// has no percentage to show next to the provider name.
    func testMostUrgentWithAnAllNilInputIsNil() {
        let rows = [row(.gemini, "—", nil, error: "gemini is not installed"),
                    row(.claude, "—", nil, error: "No quota data"),
                    row(.codex, "—", nil)]
        XCTAssertNil(QuotaFormatting.mostUrgent(rows))
        XCTAssertNil(QuotaFormatting.mostUrgent([]))
    }

    func testMostUrgentKeepsTheFirstOfEqualReadings() {
        let rows = [row(.gemini, "Flash", 50), row(.codex, "Session", 50)]
        XCTAssertEqual(QuotaFormatting.mostUrgent(rows)?.provider, .gemini)
    }

    // MARK: - WaybarPayload

    /// One healthy window with a reset, one stale window carrying a refresh
    /// error, and one provider that produced nothing at all.
    func testWaybarPayloadForAMixedSnapshotSet() throws {
        let snapshots = [
            QuotaSnapshot(provider: .gemini,
                          windows: [QuotaWindow(label: "Pro", usedPercent: 96, resetAt: epoch.addingTimeInterval(2 * 3_600 + 15 * 60))]),
            QuotaSnapshot(provider: .claude,
                          windows: [QuotaWindow(label: "Weekly limit", usedPercent: 42.5, resetAt: nil)],
                          error: "Refresh failed: timed out", probeSucceeded: false),
            QuotaSnapshot(provider: .codex, windows: [], error: "codex is not installed", probeSucceeded: false)
        ]
        let payload = WaybarPayload(rows: QuotaFormatting.rows(for: snapshots, now: epoch))

        XCTAssertEqual(payload.text, "P 96%")
        XCTAssertEqual(payload.class, "critical")
        XCTAssertEqual(payload.percentage, 96)
        // The leader is the fresh Gemini reading, so the headline is not stale
        // even though two other providers failed; the tooltip carries those.
        XCTAssertFalse(payload.stale)
        XCTAssertEqual(payload.tooltip, """
        Gemini CLI Pro: 96% — resets in 2h 15m
        Claude Code Weekly limit: 42.5% (Refresh failed: timed out)
        Codex: codex is not installed
        """)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        XCTAssertEqual(json?["text"] as? String, "P 96%")
        XCTAssertEqual(json?["class"] as? String, "critical")
        XCTAssertEqual(json?["percentage"] as? Int, 96)
        XCTAssertNotNil(json?["tooltip"] as? String)
        XCTAssertEqual(try encoded(payload), """
        {"class":"critical","percentage":96,"stale":false,"text":"P 96%",\
        "tooltip":"Gemini CLI Pro: 96% \u{2014} resets in 2h 15m\\nClaude Code Weekly limit: \
        42.5% (Refresh failed: timed out)\\nCodex: codex is not installed"}
        """)
    }

    /// A reading `QuotaEngine.retainingLastGood` kept when the refresh failed:
    /// a percentage *and* an error. It used to lead the bar with no marker at
    /// all, while the CLI table drew the same row with a warning glyph.
    func testWaybarPayloadMarksARetainedReadingAsStale() {
        let payload = WaybarPayload(rows: [row(.gemini, "Pro", 96, error: "Gemini did not respond")])
        XCTAssertTrue(payload.stale)
        XCTAssertEqual(payload.text, "P 96% \u{26A0}")
        // The urgency still decides the class: a retained 96% is still critical,
        // so existing CSS keeps colouring it.
        XCTAssertEqual(payload.class, "critical")
        XCTAssertEqual(payload.percentage, 96)
        XCTAssertEqual(payload.tooltip, "Gemini CLI Pro: 96% (Gemini did not respond)")
    }

    /// A stale leader beside a fresh lower reading. The bar shows the retained
    /// number, so it has to admit the number is retained.
    func testWaybarPayloadIsStaleWhenTheLeadingRowIsTheRetainedOne() {
        let payload = WaybarPayload(rows: [row(.codex, "Session", 20),
                                           row(.claude, "Weekly limit", 81, error: "Refresh failed")])
        XCTAssertTrue(payload.stale)
        XCTAssertEqual(payload.text, "W 81% \u{26A0}")
        XCTAssertEqual(payload.class, "warning")
    }

    func testWaybarPayloadIsNotStaleWhenEveryRowIsFresh() {
        let payload = WaybarPayload(rows: [row(.codex, "Session", 20), row(.claude, "Weekly limit", 81)])
        XCTAssertFalse(payload.stale)
        XCTAssertEqual(payload.text, "W 81%")
    }

    func testWaybarPayloadOmitsResetTextWhenThereIsNone() {
        let payload = WaybarPayload(rows: [row(.codex, "Session", 12)])
        XCTAssertEqual(payload.text, "S 12%")
        XCTAssertEqual(payload.class, "normal")
        XCTAssertEqual(payload.percentage, 12)
        XCTAssertEqual(payload.tooltip, "Codex Session: 12%")
    }

    /// A row with neither a reading nor an error still has to say something, and
    /// it is not the `normal` a healthy provider gets.
    func testWaybarPayloadWithNothingToReport() {
        let payload = WaybarPayload(rows: [row(.gemini, "—", nil)])
        XCTAssertEqual(payload.text, "n/a")
        XCTAssertEqual(payload.class, "unavailable")
        XCTAssertNil(payload.percentage)
        XCTAssertFalse(payload.stale)
        XCTAssertEqual(payload.tooltip, "Gemini CLI: unavailable")
    }

    func testWaybarPayloadWithNoRowsAtAll() {
        let payload = WaybarPayload(rows: [])
        XCTAssertEqual(payload.text, "n/a")
        XCTAssertEqual(payload.class, "unavailable")
        XCTAssertNil(payload.percentage)
        XCTAssertFalse(payload.stale)
        XCTAssertEqual(payload.tooltip, "")
    }

    /// Every failing provider, not just one: the class still has to be the
    /// unavailable one rather than a healthy-looking `normal`.
    func testWaybarPayloadWhenNoProviderReportsAReading() {
        let payload = WaybarPayload(rows: QuotaFormatting.rows(for: [
            QuotaSnapshot(provider: .codex, windows: [], error: "codex is not installed",
                          probeSucceeded: false),
            QuotaSnapshot(provider: .claude, windows: [], error: "Not logged in", probeSucceeded: false)
        ], now: epoch))
        XCTAssertEqual(payload.class, "unavailable")
        XCTAssertNil(payload.percentage)
    }

    /// `percentage` is `null`, not missing and not `0`: waybar must not draw a
    /// full-width empty bar claiming the quota is untouched, and a consumer that
    /// reads the key unconditionally must still find it.
    func testWaybarPayloadKeepsThePercentageKeyAsNullWithNoReading() throws {
        let payload = WaybarPayload(rows: [row(.gemini, "—", nil, error: "expect is not installed.")])
        XCTAssertEqual(try encoded(payload), """
        {"class":"unavailable","percentage":null,"stale":false,"text":"n\\/a",\
        "tooltip":"Gemini CLI: expect is not installed."}
        """)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        XCTAssertTrue(json?.keys.contains("percentage") ?? false)
        XCTAssertTrue(json?["percentage"] is NSNull)
        XCTAssertNil(json?["percentage"] as? Int)
    }

    func testWaybarStaleReadingEncodesTheMarkerAndTheFlag() throws {
        let payload = WaybarPayload(rows: [row(.codex, "Session", 12, error: "Refresh failed: timed out")])
        XCTAssertEqual(try encoded(payload), """
        {"class":"normal","percentage":12,"stale":true,"text":"S 12% \u{26A0}",\
        "tooltip":"Codex Session: 12% (Refresh failed: timed out)"}
        """)
    }

    /// The class names are a public interface: `README.md` pins them and users
    /// style on them, so a rename is a breaking change.
    func testWaybarClassNamesAreStable() {
        XCTAssertEqual(WaybarPayload.unavailableClass, "unavailable")
        XCTAssertEqual(WaybarPayload.staleMarker, "\u{26A0}")
        for urgency in [QuotaUrgency.normal, .warning, .critical] {
            XCTAssertNotEqual(WaybarPayload.unavailableClass, urgency.rawValue)
        }
    }

    func testWaybarPayloadRoundsThePercentage() {
        XCTAssertEqual(WaybarPayload(rows: [row(.codex, "Session", 42.4)]).percentage, 42)
        XCTAssertEqual(WaybarPayload(rows: [row(.codex, "Session", 42.6)]).percentage, 43)
        XCTAssertEqual(WaybarPayload(rows: [row(.codex, "Weekly limit", 80)]).class, "warning")
    }
}
