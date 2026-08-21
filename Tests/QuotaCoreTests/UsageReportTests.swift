import XCTest
import Foundation
@testable import QuotaCore

/// What `quotabar history` and `quotabar advise` actually print, plus the
/// sparkline and bucketing they are built from.
final class UsageReportTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")
    private let weekly = HistorySeriesID(provider: .claude, windowKey: "weekly")

    // MARK: - Sparkline

    /// The ramp is pinned end to end: 0% must not render as the same glyph as
    /// 14%, or an empty quota would look used.
    func testSparklineCoversItsRangeAtBothEnds() {
        XCTAssertEqual(QuotaFormatting.sparkline([0]), "\u{2581}")
        XCTAssertEqual(QuotaFormatting.sparkline([100]), "\u{2588}")
        // Half-way rounds up onto the fifth of eight levels.
        XCTAssertEqual(QuotaFormatting.sparkline([50]), "\u{2585}")
        XCTAssertEqual(QuotaFormatting.sparkline([0, 100]), "\u{2581}\u{2588}")
    }

    /// Untrusted numbers reach this: a clamp failure would index off the ramp.
    func testSparklineClampsRatherThanIndexingOffTheRamp() {
        XCTAssertEqual(QuotaFormatting.sparkline([1e9]), "\u{2588}")
        XCTAssertEqual(QuotaFormatting.sparkline([-50]), "\u{2581}")
    }

    /// A bucket nothing was sampled in is a gap, not a zero. Drawing it as a low
    /// bar would claim the quota was empty when it was simply unwatched.
    func testAnUnsampledBucketRendersAsAGap() {
        XCTAssertEqual(QuotaFormatting.sparkline([nil]), " ")
        XCTAssertEqual(QuotaFormatting.sparkline([0, nil, 100]), "\u{2581} \u{2588}")
    }

    func testAnEmptySparklineIsEmpty() {
        XCTAssertEqual(QuotaFormatting.sparkline([]), "")
    }

    // MARK: - Bucketing

    /// Maximum per bucket, not mean: a downsampled chart that loses the peak has
    /// lost the only number that matters.
    func testBucketsKeepThePeakRatherThanAveragingItAway() throws {
        let points = [(at: start, usedPercent: 10.0),
                      (at: start.addingTimeInterval(60), usedPercent: 90.0),
                      (at: start.addingTimeInterval(120), usedPercent: 20.0)]
        let cells = QuotaFormatting.buckets(points, from: start, to: start.addingTimeInterval(180), count: 1)
        XCTAssertEqual(try XCTUnwrap(cells.first), 90)
    }

    func testBucketsSpreadPointsAcrossTheRange() {
        let points = (0..<4).map { (at: start.addingTimeInterval(Double($0) * 900), usedPercent: Double($0) * 10) }
        let cells = QuotaFormatting.buckets(points, from: start, to: start.addingTimeInterval(3_600), count: 4)
        XCTAssertEqual(cells, [0, 10, 20, 30])
    }

    func testPointsOutsideTheRangeAreDropped() {
        let points = [(at: start.addingTimeInterval(-60), usedPercent: 99.0),
                      (at: start.addingTimeInterval(60), usedPercent: 10.0),
                      (at: start.addingTimeInterval(6_000), usedPercent: 99.0)]
        let cells = QuotaFormatting.buckets(points, from: start, to: start.addingTimeInterval(3_600), count: 2)
        XCTAssertEqual(cells, [10, nil])
    }

    func testDegenerateBucketRequestsAreHandled() {
        XCTAssertTrue(QuotaFormatting.buckets([], from: start, to: start, count: 0).isEmpty)
        // A zero-width range still has to answer with something rather than
        // dividing by zero.
        let cells = QuotaFormatting.buckets([(at: start, usedPercent: 40)], from: start, to: start, count: 2)
        XCTAssertEqual(cells, [40, 40])
    }

    // MARK: - History text

    func testHistoryNamesEverySeriesAndItsCurrentAndPeakReadings() {
        let text = UsageReport.history(samples: ramp(session, from: 0, to: 60, count: 8),
                                       from: start, to: start.addingTimeInterval(7 * 900),
                                       labels: [session: "5-hour limit"])
        XCTAssertTrue(text.contains("Codex 5-hour limit"), text)
        XCTAssertTrue(text.contains("now"), text)
        XCTAssertTrue(text.contains("peak"), text)
        XCTAssertTrue(text.contains("8 samples"), text)
    }

    /// A sparkline without a scale invites reading a 90-day chart as a day.
    func testHistoryStatesTheSpanAndTheCellWidth() {
        let text = UsageReport.history(samples: ramp(session, from: 0, to: 60, count: 8),
                                       from: start, to: start.addingTimeInterval(7 * 86_400),
                                       width: 7)
        XCTAssertTrue(text.contains("each cell 1d"), text)
    }

    func testHistoryFallsBackToTheWindowKeyWhenNoLabelIsKnown() {
        let text = UsageReport.history(samples: ramp(session, from: 0, to: 10, count: 2),
                                       from: start, to: start.addingTimeInterval(900))
        XCTAssertTrue(text.contains("Codex session"), text)
    }

    func testAnEmptyHistoryExplainsItself() {
        let text = UsageReport.history(samples: [], from: start, to: start.addingTimeInterval(900))
        XCTAssertTrue(text.contains("No usage recorded yet"), text)
    }

    /// Damage is reported rather than swallowed, so a truncated file is visible
    /// instead of silently shortening the chart.
    func testADiagnosticIsCarriedIntoTheOutput() {
        let empty = UsageReport.history(samples: [], from: start, to: start.addingTimeInterval(900),
                                        diagnostic: "2 damaged records ignored")
        XCTAssertTrue(empty.contains("2 damaged records ignored"), empty)

        let populated = UsageReport.history(samples: ramp(session, from: 0, to: 10, count: 2),
                                            from: start, to: start.addingTimeInterval(900),
                                            diagnostic: "2 damaged records ignored")
        XCTAssertTrue(populated.contains("2 damaged records ignored"), populated)
    }

    func testSeriesAreOrderedStably() {
        let samples = ramp(weekly, from: 0, to: 10, count: 2) + ramp(session, from: 0, to: 10, count: 2)
        let forward = UsageReport.history(samples: samples, from: start, to: start.addingTimeInterval(900))
        let reversed = UsageReport.history(samples: samples.reversed(),
                                           from: start, to: start.addingTimeInterval(900))
        XCTAssertEqual(forward, reversed)
    }

    // MARK: - Cycles text

    func testCyclesListPeakAndCoveragePerCycle() {
        let text = UsageReport.cycles([cycle(peak: 91.5, coverage: 0.82)], labels: [session: "Session"])
        XCTAssertTrue(text.contains("Codex Session"), text)
        XCTAssertTrue(text.contains("91.5%"), text)
        XCTAssertTrue(text.contains("82%"), text)
    }

    /// An in-progress cycle has no peak yet, so listing it would be misleading.
    func testIncompleteCyclesAreNotListed() {
        let text = UsageReport.cycles([cycle(peak: 50, coverage: 1, isComplete: false)])
        XCTAssertTrue(text.contains("No complete cycles"), text)
    }

    // MARK: - Advice text

    func testAdviceRendersTheHeadlineAndItsEvidence() {
        let text = UsageReport.advice([Recommendation(
            kind: .underUtilized, severity: .opportunity, series: session, windowLabel: "Session",
            headline: "Codex Session looks oversized", evidence: ["peaked at 22%", "median 15%"])])
        XCTAssertTrue(text.contains("OPPORTUNITY"), text)
        XCTAssertTrue(text.contains("Codex Session looks oversized"), text)
        XCTAssertTrue(text.contains("· peaked at 22%"), text)
        XCTAssertTrue(text.contains("· median 15%"), text)
    }

    func testNoAdviceSaysSoRatherThanPrintingNothing() {
        XCTAssertTrue(UsageReport.advice([]).contains("Nothing to suggest"))
    }

    /// The badges are fixed width so evidence lines under them align.
    func testEverySeverityHasAFixedWidthBadge() {
        let widths = Set(Recommendation.Severity.allCases.map { UsageReport.badge($0).count })
        XCTAssertEqual(widths.count, 1)
    }

    // MARK: - CSV

    func testCSVCarriesAHeaderAndOneRowPerSample() {
        let text = UsageReport.csv(samples: [
            UsageSample(series: session, at: start, usedPercent: 41.5,
                        resetAt: start.addingTimeInterval(3_600))
        ])
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.first, "provider,window_key,at,used_percent,reset_at")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[1]),
                       "codex,session,2023-11-14T22:13:20Z,41.50,2023-11-14T23:13:20Z")
    }

    func testCSVLeavesTheResetColumnEmptyWhenThereIsNone() {
        let text = UsageReport.csv(samples: [
            UsageSample(series: session, at: start, usedPercent: 0, resetAt: nil)
        ])
        XCTAssertTrue(text.hasSuffix(",0.00,"), text)
    }

    func testCSVOfNothingIsStillAHeader() {
        XCTAssertEqual(UsageReport.csv(samples: []), "provider,window_key,at,used_percent,reset_at")
    }

    /// A CSV export covers the `--since` window, not the whole retained log:
    /// `quotabar history` reads the file, keeps `from...to`, and hands only that
    /// to `csv`. README.md and `--help` promise exactly this, so the count the
    /// renderer receives is pinned on both sides of the boundary — the default
    /// window is 7 days against 120 days of retention, and an export that
    /// silently dropped the difference would be a backup with a hole in it.
    func testCSVReceivesOnlyTheSinceWindowIncludingItsBoundarySamples() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(url: directory.appendingPathComponent("history.bin"),
                                     catalog: HistorySeriesCatalog(store: MemoryStateStore()))

        let now = start
        let from = now.addingTimeInterval(-7 * 86_400)
        // Oldest first: the header epoch is the day the first sample landed in,
        // and a record before it cannot be encoded.
        XCTAssertEqual(store.append([
            sample(at: now.addingTimeInterval(-100 * 86_400), percent: 10),
            sample(at: from.addingTimeInterval(-60), percent: 20),
            sample(at: from, percent: 30),
            sample(at: now.addingTimeInterval(-3_600), percent: 40),
            sample(at: now, percent: 50),
            sample(at: now.addingTimeInterval(60), percent: 60)
        ]), 6)
        XCTAssertEqual(store.read().samples.count, 6)

        let windowed = store.read(from: from, to: now).samples
        XCTAssertEqual(windowed.count, 3)
        let rows = UsageReport.csv(samples: windowed).split(separator: "\n").dropFirst()
        XCTAssertEqual(rows.count, 3)
        // Both boundary samples are kept; the three outside the window are gone,
        // not merely reordered.
        XCTAssertEqual(rows.map { String($0.split(separator: ",")[3]) },
                       ["30.00", "40.00", "50.00"])
        for dropped in ["10.00", "20.00", "60.00"] {
            XCTAssertFalse(rows.contains { $0.hasSuffix(",\(dropped),") }, dropped)
        }
    }

    // MARK: - JSON payloads

    func testHistoryPayloadGroupsPointsBySeries() throws {
        let payload = UsageReport.historyPayload(
            samples: ramp(session, from: 0, to: 30, count: 4) + ramp(weekly, from: 0, to: 10, count: 2),
            cycles: [cycle(peak: 90, coverage: 1)],
            from: start, to: start.addingTimeInterval(3_600),
            labels: [session: "5-hour limit"], damagedRecords: 3)

        XCTAssertEqual(payload.series.count, 2)
        XCTAssertEqual(payload.damagedRecords, 3)
        let codex = try XCTUnwrap(payload.series.first { $0.windowKey == "session" })
        XCTAssertEqual(codex.provider, "codex")
        XCTAssertEqual(codex.windowLabel, "5-hour limit")
        XCTAssertEqual(codex.points.count, 4)
        XCTAssertEqual(payload.cycles.count, 1)
    }

    func testAdvicePayloadFlattensEveryField() throws {
        let payload = UsageReport.advicePayload([Recommendation(
            kind: .idle, severity: .opportunity, series: session, windowLabel: "Session",
            headline: "unused", evidence: ["four cycles"])])
        let item = try XCTUnwrap(payload.recommendations.first)
        XCTAssertEqual(item.kind, "idle")
        XCTAssertEqual(item.severity, "opportunity")
        XCTAssertEqual(item.provider, "codex")
        XCTAssertEqual(item.windowKey, "session")
        XCTAssertEqual(item.evidence, ["four cycles"])
    }

    func testPayloadsEncodeToJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertNoThrow(try encoder.encode(UsageReport.historyPayload(
            samples: ramp(session, from: 0, to: 10, count: 2), cycles: [],
            from: start, to: start.addingTimeInterval(900))))
        XCTAssertNoThrow(try encoder.encode(UsageReport.advicePayload([])))
    }

    // MARK: - Span text

    func testSpanTextPicksASensibleUnit() {
        XCTAssertEqual(UsageReport.spanText(30), "30s")
        XCTAssertEqual(UsageReport.spanText(600), "10m")
        XCTAssertEqual(UsageReport.spanText(7_200), "2h")
        XCTAssertEqual(UsageReport.spanText(86_400), "1d")
        XCTAssertEqual(UsageReport.spanText(7 * 86_400), "7d")
    }

    // MARK: - Fixtures

    private func ramp(_ series: HistorySeriesID, from: Double, to: Double, count: Int) -> [UsageSample] {
        (0..<count).map { index in
            let fraction = count > 1 ? Double(index) / Double(count - 1) : 0
            return UsageSample(series: series,
                               at: start.addingTimeInterval(Double(index) * 900),
                               usedPercent: from + (to - from) * fraction,
                               resetAt: nil)
        }
    }

    private func sample(at: Date, percent: Double) -> UsageSample {
        UsageSample(series: session, at: at, usedPercent: percent, resetAt: nil)
    }

    private func cycle(peak: Double, coverage: Double, isComplete: Bool = true) -> CycleSummary {
        CycleSummary(series: session, startedAt: start, endedAt: start.addingTimeInterval(86_400),
                     peakPercent: peak, observedFraction: coverage, sampleCount: 96,
                     isComplete: isComplete)
    }
}

// MARK: - Stubs

/// In-memory `StateStore` so the series catalogue the history file needs lives
/// beside the temporary log rather than in the invoking user's state.
private final class MemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var numbers: [String: Int] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { blobs[key] } }
    func setData(_ value: Data?, forKey key: String) { lock.withLock { blobs[key] = value } }
    func integer(forKey key: String) -> Int? { lock.withLock { numbers[key] } }
    func setInteger(_ value: Int?, forKey key: String) { lock.withLock { numbers[key] = value } }
}
