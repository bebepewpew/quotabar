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

    /// One row per series, in the order this module documents, so the expectation
    /// comes from `UsageAnalysis.order`. Rendering the same samples twice and
    /// comparing the two texts would not pin it: `Dictionary(grouping:)` iterates
    /// in an order fixed by the per-process hash seed, so both renderings agree
    /// with each other whether or not the sort is there.
    func testSeriesAreRenderedInTheDocumentedOrder() {
        let expected = Self.documentedSeriesOrder.map { UsageReport.name(for: $0, labels: [:]) }
        let samples = Self.documentedSeriesOrder.reversed().flatMap { ramp($0, from: 0, to: 10, count: 2) }

        let text = UsageReport.history(samples: samples, from: start, to: start.addingTimeInterval(900))
        // Every line but the trailing scale footer names one series, padded out
        // to a common width before the sparkline.
        let rows = text.split(separator: "\n").dropLast()
        let named = rows.map { row in expected.first { row.hasPrefix($0) } ?? String(row) }
        XCTAssertEqual(named, expected)
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

    /// A percentage only ever reaches CSV through `percentField`, so an absurd one
    /// out of a hand-edited cache or a damaged record cannot land in the column a
    /// spreadsheet sums.
    func testCSVClampsAPercentageOutsideZeroToOneHundred() {
        XCTAssertTrue(UsageReport.csv(samples: [
            UsageSample(series: session, at: start, usedPercent: 150, resetAt: nil)
        ]).hasSuffix(",100.00,"))
        XCTAssertTrue(UsageReport.csv(samples: [
            UsageSample(series: session, at: start, usedPercent: -12, resetAt: nil)
        ]).hasSuffix(",0.00,"))
        XCTAssertTrue(UsageReport.csv(samples: [
            UsageSample(series: session, at: start, usedPercent: .nan, resetAt: nil)
        ]).hasSuffix(",0.00,"))
    }

    /// A window key is the only free-form column, and a cache file is not a
    /// trusted writer: a separator inside one has to be quoted rather than allowed
    /// to split the row.
    func testCSVQuotesAWindowKeyThatCarriesASeparator() {
        let awkward = HistorySeriesID(provider: .codex, windowKey: "we,ird\n\"key\"")
        let row = String(UsageReport.csv(samples: [
            UsageSample(series: awkward, at: start, usedPercent: 10, resetAt: nil)
        ]).dropFirst(UsageReport.csvHeader.count + 1))
        XCTAssertEqual(row, "codex,\"we,ird\n\"\"key\"\"\",2023-11-14T22:13:20Z,10.00,")
    }

    // MARK: - CSV, status snapshot

    private func window(_ label: String, _ used: Double, resetAt: Date? = nil) -> QuotaWindow {
        QuotaWindow(label: label, usedPercent: used, resetAt: resetAt)
    }

    private func snapshot(_ provider: Provider, _ windows: [QuotaWindow],
                          at: Date, error: String? = nil) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, windows: windows, error: error,
                      probeSucceeded: error == nil, updatedAt: at)
    }

    func testStatusCSVCarriesAHeaderAndOneRowPerWindow() {
        let text = UsageReport.csv(snapshots: [
            snapshot(.codex, [window("Session", 41.5, resetAt: start.addingTimeInterval(3_600)),
                              window("Weekly", 66.666)], at: start),
            snapshot(.claude, [window("5-hour limit", 7)], at: start)
        ])
        XCTAssertEqual(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), [
            "provider,window_key,at,used_percent,reset_at",
            "codex,session,2023-11-14T22:13:20Z,41.50,2023-11-14T23:13:20Z",
            "codex,weekly,2023-11-14T22:13:20Z,66.67,",
            "claude,5-hour-limit,2023-11-14T22:13:20Z,7.00,"
        ])
    }

    /// Windows are identified by key, never by the label the provider prints, so
    /// the column that a consumer joins on has to be the key.
    func testStatusCSVWritesTheWindowKeyRatherThanItsLabel() {
        let text = UsageReport.csv(snapshots: [
            snapshot(.gemini, [QuotaWindow(key: "pro", label: "Gemini 3 Pro", usedPercent: 12,
                                           resetAt: nil)], at: start)
        ])
        XCTAssertTrue(text.hasSuffix("gemini,pro,2023-11-14T22:13:20Z,12.00,"), text)
        XCTAssertFalse(text.contains("Gemini 3 Pro"), text)
    }

    /// An unknown reset is an empty cell: a placeholder date would be read as a
    /// real one, and dropping the column would shift every later field.
    func testStatusCSVLeavesTheResetCellEmptyWhenTheResetIsUnknown() {
        let text = UsageReport.csv(snapshots: [snapshot(.codex, [window("Session", 0)], at: start)])
        let row = String(text.split(separator: "\n")[1])
        XCTAssertEqual(row.filter { $0 == "," }.count, 4)
        XCTAssertTrue(row.hasSuffix(",0.00,"), row)
    }

    /// The stamp is the reading's own, not the moment of the call: a reading
    /// retained through a failed refresh is stale and the row has to admit it.
    func testStatusCSVStampsEachRowWithTheSnapshotsOwnTime() {
        let text = UsageReport.csv(snapshots: [
            snapshot(.codex, [window("Session", 30)], at: start.addingTimeInterval(-86_400),
                     error: "Refresh failed: timed out")
        ])
        XCTAssertTrue(text.contains(",2023-11-13T22:13:20Z,30.00,"), text)
    }

    /// A provider with nothing to report has no number to record. The CLI names it
    /// on stderr and exits non-zero; a row of blanks would be a reading.
    func testStatusCSVOfProvidersWithoutWindowsIsStillJustAHeader() {
        XCTAssertEqual(UsageReport.csv(snapshots: []), UsageReport.csvHeader)
        XCTAssertEqual(UsageReport.csv(snapshots: [
            snapshot(.gemini, [], at: start, error: "not authenticated")
        ]), UsageReport.csvHeader)
    }

    /// Both writers emit the same columns, so `quotabar --format csv` appended by a
    /// cron job and an export of `quotabar history --format csv` are one table.
    func testStatusAndHistoryCSVShareTheirColumns() {
        XCTAssertEqual(UsageReport.csv(snapshots: []), UsageReport.csv(samples: []))
    }

    /// `--watch` writes the header once. A later cycle that saw nothing renders as
    /// the empty string, which the CLI prints as nothing rather than a blank row.
    func testStatusCSVCanOmitTheHeaderForALaterWatchCycle() {
        XCTAssertEqual(UsageReport.csv(snapshots: [snapshot(.codex, [window("Session", 5)], at: start)],
                                       includeHeader: false),
                       "codex,session,2023-11-14T22:13:20Z,5.00,")
        XCTAssertEqual(UsageReport.csv(snapshots: [], includeHeader: false), "")
    }

    func testStatusCSVQuotesAWindowKeyThatCarriesASeparator() {
        let text = UsageReport.csv(snapshots: [
            snapshot(.codex, [QuotaWindow(key: "we,ird", label: "Session", usedPercent: 10,
                                          resetAt: nil)], at: start)
        ], includeHeader: false)
        XCTAssertEqual(text, "codex,\"we,ird\",2023-11-14T22:13:20Z,10.00,")
    }

    func testStatusCSVClampsAPercentageOutsideZeroToOneHundred() {
        let text = UsageReport.csv(snapshots: [
            snapshot(.codex, [window("High", 150), window("Low", -12), window("Broken", .nan)],
                     at: start)
        ])
        let cells = text.split(separator: "\n").dropFirst().map { $0.split(separator: ",")[3] }
        XCTAssertEqual(cells.map(String.init), ["100.00", "0.00", "0.00"])
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

    /// Every provider crossed with several window keys, arranged the way the
    /// reports document. Which arrangement that is stays out of the assertion on
    /// purpose — the test pins that the rows follow `order`, not what `order`
    /// says. Fifteen series rather than two because an unsorted grouping picks an
    /// arrangement out of the hash seed: with two it would match by luck about
    /// half the time, with fifteen there are 15! ways to be wrong. No key is a
    /// prefix of another, so a row belongs to exactly one series.
    private static let documentedSeriesOrder: [HistorySeriesID] = Provider.allCases
        .flatMap { provider in
            ["5h", "24h", "session", "weekly", "monthly"].map {
                HistorySeriesID(provider: provider, windowKey: $0)
            }
        }
        .sorted { UsageAnalysis.order($0) < UsageAnalysis.order($1) }

    private func cycle(peak: Double, coverage: Double, isComplete: Bool = true) -> CycleSummary {
        CycleSummary(series: session, startedAt: start, endedAt: start.addingTimeInterval(86_400),
                     peakPercent: peak, observedFraction: coverage, sampleCount: 96,
                     isComplete: isComplete)
    }
}
