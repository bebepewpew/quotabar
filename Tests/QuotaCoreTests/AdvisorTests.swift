import XCTest
import Foundation
@testable import QuotaCore

/// The rules that decide whether a subscription fits. Every threshold is pinned
/// at its exact boundary, because each one is the difference between telling
/// somebody to downgrade and telling them nothing.
final class AdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")
    private let weekly = HistorySeriesID(provider: .codex, windowKey: "weekly")

    // MARK: - Under-utilised

    func testAConsistentlyLowWindowIsCalledOversized() throws {
        let advice = Advisor.recommendations(for: [input(session, peaks: [20, 25, 30, 35])], now: now)
        let found = try XCTUnwrap(advice.first { $0.kind == .underUtilized })
        XCTAssertEqual(found.severity, .opportunity)
        XCTAssertTrue(found.headline.contains("looks oversized"))
        XCTAssertFalse(found.evidence.isEmpty)
    }

    /// Nearest-rank p90 over a handful of cycles is effectively the busiest one,
    /// which is the intended claim: *even the busiest* cycle stayed low. One busy
    /// cycle is enough to withdraw the advice.
    func testOneBusyCycleWithdrawsTheAdvice() {
        let advice = Advisor.recommendations(for: [input(session, peaks: [20, 25, 30, 95])], now: now)
        XCTAssertNil(advice.first { $0.kind == .underUtilized })
    }

    func testTheUnderUtilisedBoundaryIsExact() {
        let atBoundary = Advisor.recommendations(for: [input(session, peaks: [10, 20, 30, 40])], now: now)
        XCTAssertNotNil(atBoundary.first { $0.kind == .underUtilized })

        let justOver = Advisor.recommendations(for: [input(session, peaks: [10, 20, 30, 40.01])], now: now)
        XCTAssertNil(justOver.first { $0.kind == .underUtilized })
    }

    /// An untouched subscription gets its own, stronger wording, and must not
    /// also be reported as merely oversized.
    func testAnUntouchedWindowIsIdleAndNotAlsoUnderUtilised() throws {
        let advice = Advisor.recommendations(for: [input(session, peaks: [0, 0, 1, 0])], now: now)
        XCTAssertNotNil(advice.first { $0.kind == .idle })
        XCTAssertNil(advice.first { $0.kind == .underUtilized })
        XCTAssertTrue(try XCTUnwrap(advice.first).headline.contains("gone unused"))
    }

    func testTheIdleBoundaryIsExact() {
        XCTAssertNotNil(Advisor.recommendations(for: [input(session, peaks: [1, 1, 1, 1])], now: now)
            .first { $0.kind == .idle })
        XCTAssertNil(Advisor.recommendations(for: [input(session, peaks: [1, 1, 1, 1.01])], now: now)
            .first { $0.kind == .idle })
    }

    // MARK: - Exhausted

    func testAWindowThatRunsOutMostCyclesIsCritical() throws {
        let advice = Advisor.recommendations(for: [input(session, peaks: [95, 100, 40, 98])], now: now)
        let found = try XCTUnwrap(advice.first { $0.kind == .chronicallyExhausted })
        XCTAssertEqual(found.severity, .critical)
    }

    func testTheExhaustedShareBoundaryIsExact() {
        // Exactly half.
        XCTAssertNotNil(Advisor.recommendations(for: [input(session, peaks: [95, 95, 10, 10])], now: now)
            .first { $0.kind == .chronicallyExhausted })
        // One short of half.
        XCTAssertNil(Advisor.recommendations(for: [input(session, peaks: [95, 10, 10, 10])], now: now)
            .first { $0.kind == .chronicallyExhausted })
        // 94.99 is not exhausted.
        XCTAssertNil(Advisor.recommendations(for: [input(session, peaks: [94.99, 94.99, 10, 10])], now: now)
            .first { $0.kind == .chronicallyExhausted })
    }

    // MARK: - Evidence gates

    /// The rule that keeps the advisor honest. Below the minimum it says so,
    /// rather than reading a short record as a quiet one.
    func testTooFewCyclesReportsInsufficientDataRatherThanAdvice() throws {
        let advice = Advisor.recommendations(for: [input(session, peaks: [10, 10, 10])], now: now)
        let found = try XCTUnwrap(advice.first)
        XCTAssertEqual(found.kind, .insufficientData)
        XCTAssertEqual(found.severity, .info)
        XCTAssertTrue(found.evidence.contains { $0.contains("3 of 4") })
    }

    func testTheCycleCountBoundaryIsExact() {
        XCTAssertEqual(Advisor.recommendations(for: [input(session, peaks: [10, 10, 10])], now: now).first?.kind,
                       .insufficientData)
        XCTAssertEqual(Advisor.recommendations(for: [input(session, peaks: [10, 10, 10, 10])], now: now).first?.kind,
                       .underUtilized)
    }

    /// A week the laptop was shut for understates its own peak. Advising a
    /// downgrade off that is worse than saying nothing.
    func testPoorlyObservedCyclesAreNotEvidence() {
        let barelyWatched = input(session, peaks: [10, 10, 10, 10], coverage: 0.59)
        XCTAssertEqual(Advisor.recommendations(for: [barelyWatched], now: now).first?.kind, .insufficientData)

        let watched = input(session, peaks: [10, 10, 10, 10], coverage: 0.6)
        XCTAssertEqual(Advisor.recommendations(for: [watched], now: now).first?.kind, .underUtilized)
    }

    /// A cycle we joined partway through has an unknown peak, so it cannot count.
    func testIncompleteCyclesAreNotEvidence() {
        let input = input(session, peaks: [10, 10, 10, 10], isComplete: false)
        XCTAssertEqual(Advisor.recommendations(for: [input], now: now).first?.kind, .insufficientData)
    }

    /// A CLI that has not reported in weeks was probably uninstalled; advising on
    /// its subscription would be noise.
    func testAStaleSeriesIsNotAdvisedOnAtAll() {
        let stale = input(session, peaks: [10, 10, 10, 10],
                          latestAt: now.addingTimeInterval(-46 * 86_400))
        XCTAssertTrue(Advisor.recommendations(for: [stale], now: now).isEmpty)

        let fresh = input(session, peaks: [10, 10, 10, 10],
                          latestAt: now.addingTimeInterval(-44 * 86_400))
        XCTAssertFalse(Advisor.recommendations(for: [fresh], now: now).isEmpty)
    }

    func testASeriesWithNoReadingAtAllIsSkipped() {
        let empty = AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                                 latest: nil, burnRatePerHour: nil)
        XCTAssertTrue(Advisor.recommendations(for: [empty], now: now).isEmpty)
    }

    /// Only the most recent cycles count, so a plan resized last month is not
    /// judged on the quarter before it.
    func testOnlyTheMostRecentCyclesAreConsidered() {
        // Ten quiet cycles then eight busy ones: the busy tail is what counts.
        let peaks = Array(repeating: 5.0, count: 10) + Array(repeating: 99.0, count: 8)
        XCTAssertNotNil(Advisor.recommendations(for: [input(session, peaks: peaks)], now: now)
            .first { $0.kind == .chronicallyExhausted })
    }

    // MARK: - Projection

    func testAProjectionThatLandsBeforeTheResetIsRaised() throws {
        let latest = UsageSample(series: session, at: now, usedPercent: 50,
                                 resetAt: now.addingTimeInterval(10 * 3_600))
        let advice = Advisor.recommendations(
            for: [AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                               latest: latest, burnRatePerHour: 20)], now: now)
        let found = try XCTUnwrap(advice.first { $0.kind == .projectedExhaustion })
        XCTAssertEqual(found.severity, .critical)
        // The reset is carried so the alert can be keyed on the cycle.
        XCTAssertEqual(found.cycleResetAt, latest.resetAt)
    }

    func testAProjectionThatLandsAfterTheResetIsNotRaised() {
        let latest = UsageSample(series: session, at: now, usedPercent: 50,
                                 resetAt: now.addingTimeInterval(3 * 3_600))
        let advice = Advisor.recommendations(
            for: [AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                               latest: latest, burnRatePerHour: 5)], now: now)
        XCTAssertNil(advice.first { $0.kind == .projectedExhaustion })
    }

    func testAWindowWithNoResetOrNoRateProjectsNothing() {
        let noReset = AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                                   latest: UsageSample(series: session, at: now, usedPercent: 50, resetAt: nil),
                                   burnRatePerHour: 20)
        XCTAssertNil(Advisor.recommendations(for: [noReset], now: now)
            .first { $0.kind == .projectedExhaustion })

        let noRate = AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                                  latest: UsageSample(series: session, at: now, usedPercent: 50,
                                                      resetAt: now.addingTimeInterval(3_600)),
                                  burnRatePerHour: nil)
        XCTAssertNil(Advisor.recommendations(for: [noRate], now: now)
            .first { $0.kind == .projectedExhaustion })
    }

    // MARK: - Cross-series rules

    /// Session limits biting while the weekly allowance goes spare is a
    /// scheduling problem. Advising a bigger plan there would be wrong.
    func testBurstyUsageIsReportedWhenSessionsBiteButTheWeekDoesNot() throws {
        let advice = Advisor.recommendations(for: [
            input(session, peaks: [99, 99, 99, 99]),
            input(weekly, peaks: [20, 25, 30, 35])
        ], now: now)
        let found = try XCTUnwrap(advice.first { $0.kind == .burstyUsage })
        XCTAssertEqual(found.severity, .warning)
        XCTAssertTrue(found.evidence.contains { $0.contains("spreading the same work out") })
    }

    func testBurstyUsageNeedsBothWindows() {
        let advice = Advisor.recommendations(for: [input(session, peaks: [99, 99, 99, 99])], now: now)
        XCTAssertNil(advice.first { $0.kind == .burstyUsage })
    }

    func testRebalancePointsAtTheProviderWithHeadroom() throws {
        let full = AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                                latest: UsageSample(series: session, at: now, usedPercent: 97, resetAt: nil),
                                burnRatePerHour: nil)
        let spare = HistorySeriesID(provider: .gemini, windowKey: "pro")
        let idle = AdvisorInput(series: spare, windowLabel: "Pro", cycles: [],
                                latest: UsageSample(series: spare, at: now, usedPercent: 12, resetAt: nil),
                                burnRatePerHour: nil)

        let found = try XCTUnwrap(Advisor.recommendations(for: [full, idle], now: now)
            .first { $0.kind == .rebalance })
        XCTAssertTrue(found.headline.contains("Gemini CLI"))
        XCTAssertEqual(found.severity, .info)
    }

    func testRebalanceStaysQuietWhenNothingHasHeadroom() {
        let full = AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                                latest: UsageSample(series: session, at: now, usedPercent: 97, resetAt: nil),
                                burnRatePerHour: nil)
        let alsoBusy = HistorySeriesID(provider: .gemini, windowKey: "pro")
        let busy = AdvisorInput(series: alsoBusy, windowLabel: "Pro", cycles: [],
                                latest: UsageSample(series: alsoBusy, at: now, usedPercent: 60, resetAt: nil),
                                burnRatePerHour: nil)
        XCTAssertNil(Advisor.recommendations(for: [full, busy], now: now).first { $0.kind == .rebalance })
    }

    // MARK: - Ordering

    /// Two runs over the same data must print the same list, or the tray would
    /// reshuffle itself between refreshes.
    func testOrderingIsBySeverityThenKindAndIsStable() {
        let inputs = [
            input(weekly, peaks: [10, 10, 10, 10]),
            input(session, peaks: [99, 99, 99, 99]),
            input(HistorySeriesID(provider: .gemini, windowKey: "pro"), peaks: [10, 10, 10])
        ]
        let first = Advisor.recommendations(for: inputs, now: now)
        let second = Advisor.recommendations(for: inputs.reversed(), now: now)

        XCTAssertEqual(first.map(\.kind), second.map(\.kind))
        XCTAssertEqual(first.map(\.series), second.map(\.series))
        let severities = first.map(\.severity)
        XCTAssertEqual(severities, severities.sorted {
            (Recommendation.Severity.allCases.firstIndex(of: $0) ?? 0)
                < (Recommendation.Severity.allCases.firstIndex(of: $1) ?? 0)
        })
    }

    /// Two findings of the same kind and severity must not swap places between
    /// refreshes, so provider declaration order breaks the tie.
    func testEqualFindingsAreBrokenByProviderThenWindowKey() {
        let codexSession = input(session, peaks: [10, 10, 10, 10])
        let codexWeekly = input(weekly, peaks: [10, 10, 10, 10])
        let gemini = input(HistorySeriesID(provider: .gemini, windowKey: "pro"),
                           peaks: [10, 10, 10, 10])

        let ordered = Advisor.recommendations(for: [gemini, codexWeekly, codexSession], now: now)
            .filter { $0.kind == .underUtilized }
            .map(\.series)
        let expected = [codexSession, codexWeekly, gemini].map(\.series)
            .sorted { UsageAnalysis.order($0) < UsageAnalysis.order($1) }
        XCTAssertEqual(ordered, expected)
    }

    /// A fractional rate keeps one decimal; a whole one does not carry ".0".
    func testTheProjectedRateIsRenderedWithoutSpuriousPrecision() throws {
        func evidence(rate: Double) throws -> String {
            let latest = UsageSample(series: session, at: now, usedPercent: 50,
                                     resetAt: now.addingTimeInterval(100 * 3_600))
            let advice = Advisor.recommendations(
                for: [AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                                   latest: latest, burnRatePerHour: rate)], now: now)
            return try XCTUnwrap(advice.first { $0.kind == .projectedExhaustion }?.evidence.first)
        }
        XCTAssertTrue(try evidence(rate: 12).contains("rising 12%/h"))
        XCTAssertTrue(try evidence(rate: 12.5).contains("rising 12.5%/h"))
    }

    /// When several providers have room, the emptiest one is the suggestion.
    func testRebalancePicksTheEmptiestAlternative() throws {
        let full = AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                                latest: UsageSample(series: session, at: now, usedPercent: 99, resetAt: nil),
                                burnRatePerHour: nil)
        let some = HistorySeriesID(provider: .claude, windowKey: "session")
        let lots = HistorySeriesID(provider: .gemini, windowKey: "pro")
        let alternatives = [
            AdvisorInput(series: some, windowLabel: "Session", cycles: [],
                         latest: UsageSample(series: some, at: now, usedPercent: 45, resetAt: nil),
                         burnRatePerHour: nil),
            AdvisorInput(series: lots, windowLabel: "Pro", cycles: [],
                         latest: UsageSample(series: lots, at: now, usedPercent: 3, resetAt: nil),
                         burnRatePerHour: nil)
        ]
        let found = try XCTUnwrap(Advisor.recommendations(for: [full] + alternatives, now: now)
            .first { $0.kind == .rebalance })
        XCTAssertTrue(found.headline.hasPrefix("Gemini CLI"), found.headline)
    }

    /// A brand-new install has a reading but no cycles at all.
    func testNoCyclesAtAllStillReportsInsufficientData() throws {
        let fresh = AdvisorInput(series: session, windowLabel: "Session", cycles: [],
                                 latest: UsageSample(series: session, at: now, usedPercent: 5, resetAt: nil),
                                 burnRatePerHour: nil)
        let found = try XCTUnwrap(Advisor.recommendations(for: [fresh], now: now).first)
        XCTAssertEqual(found.kind, .insufficientData)
        XCTAssertTrue(found.evidence.contains { $0.contains("0 of 4") })
    }

    /// The idle wording names when the record starts; with nothing to name it
    /// still has to read as a sentence.
    func testIdleEvidenceNamesTheStartOfTheRecord() throws {
        let advice = Advisor.recommendations(for: [input(session, peaks: [0, 0, 0, 0])], now: now)
        let found = try XCTUnwrap(advice.first { $0.kind == .idle })
        XCTAssertTrue(found.evidence.contains { $0.contains("nothing recorded since 20") }, "\(found.evidence)")
    }

    func testNothingToSayIsAnEmptyList() {
        XCTAssertTrue(Advisor.recommendations(for: [], now: now).isEmpty)
    }

    // MARK: - Assembling inputs

    func testInputsPairHistoryWithCurrentLabels() throws {
        let samples = (0..<4).map {
            UsageSample(series: session, at: now.addingTimeInterval(Double($0) * 900),
                        usedPercent: Double($0) * 10, resetAt: nil)
        }
        let snapshot = QuotaSnapshot(provider: .codex,
                                     windows: [QuotaWindow(key: "session", label: "5-hour limit",
                                                           usedPercent: 30, resetAt: nil)])
        let inputs = Advisor.inputs(history: samples, snapshots: [snapshot],
                                    now: now.addingTimeInterval(4 * 900))
        let found = try XCTUnwrap(inputs.first { $0.series == session })
        XCTAssertEqual(found.windowLabel, "5-hour limit")
        XCTAssertEqual(found.latest?.usedPercent, 30)
        XCTAssertNotNil(found.burnRatePerHour)
    }

    /// A window with history but no live snapshot still gets advised on, or
    /// uninstalling a CLI would hide the very advice about it.
    func testASeriesWithNoLiveSnapshotFallsBackToItsKey() throws {
        let samples = [UsageSample(series: session, at: now, usedPercent: 10, resetAt: nil)]
        let inputs = Advisor.inputs(history: samples, snapshots: [], now: now)
        XCTAssertEqual(try XCTUnwrap(inputs.first).windowLabel, "session")
    }

    // MARK: - Fixtures

    /// One input whose cycles have the given peaks, newest last.
    private func input(_ series: HistorySeriesID, peaks: [Double],
                       coverage: Double = 1, isComplete: Bool = true,
                       latestAt: Date? = nil) -> AdvisorInput {
        let cycles = peaks.enumerated().map { index, peak in
            CycleSummary(series: series,
                         startedAt: now.addingTimeInterval(Double(index - peaks.count) * 86_400),
                         endedAt: now.addingTimeInterval(Double(index - peaks.count + 1) * 86_400),
                         peakPercent: peak, observedFraction: coverage,
                         sampleCount: 10, isComplete: isComplete)
        }
        let at = latestAt ?? now
        return AdvisorInput(series: series, windowLabel: series.windowKey.capitalized, cycles: cycles,
                            latest: UsageSample(series: series, at: at,
                                                usedPercent: peaks.last ?? 0, resetAt: nil),
                            burnRatePerHour: nil)
    }
}
