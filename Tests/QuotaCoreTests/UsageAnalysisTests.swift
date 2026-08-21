import XCTest
import Foundation
@testable import QuotaCore

/// Reconstructing consumption from levels: which readings are worth storing,
/// where one cycle ends, how well a cycle was watched, and how fast the current
/// one is burning.
final class UsageAnalysisTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")

    // MARK: - Admission

    func testTheFirstReadingOfASeriesIsAlwaysStored() {
        XCTAssertTrue(UsageAnalysis.isAdmissible(sample(at: start, percent: 0), after: nil))
    }

    /// The deadband exists to keep three months in under a megabyte; the boundary
    /// is exact because everything below it is discarded forever.
    func testTheDeadbandBoundaryIsExact() {
        let previous = sample(at: start, percent: 40)
        let later = start.addingTimeInterval(60)
        XCTAssertFalse(UsageAnalysis.isAdmissible(sample(at: later, percent: 40.49), after: previous))
        XCTAssertTrue(UsageAnalysis.isAdmissible(sample(at: later, percent: 40.5), after: previous))
        XCTAssertTrue(UsageAnalysis.isAdmissible(sample(at: later, percent: 39.5), after: previous))
        XCTAssertFalse(UsageAnalysis.isAdmissible(sample(at: later, percent: 39.51), after: previous))
    }

    /// A flat stretch still gets a reading every hour, so "nothing changed" is
    /// distinguishable from "nothing was sampled" when coverage is scored.
    func testTheHeartbeatStoresAnUnchangedReadingAfterAnHour() {
        let previous = sample(at: start, percent: 40)
        XCTAssertFalse(UsageAnalysis.isAdmissible(
            sample(at: start.addingTimeInterval(UsageAnalysis.heartbeat - 1), percent: 40), after: previous))
        XCTAssertTrue(UsageAnalysis.isAdmissible(
            sample(at: start.addingTimeInterval(UsageAnalysis.heartbeat), percent: 40), after: previous))
    }

    /// A reading that is not newer cannot extend the series, whatever it says.
    func testAReadingThatIsNotNewerIsRefused() {
        let previous = sample(at: start, percent: 40)
        XCTAssertFalse(UsageAnalysis.isAdmissible(sample(at: start, percent: 90), after: previous))
        XCTAssertFalse(UsageAnalysis.isAdmissible(
            sample(at: start.addingTimeInterval(-60), percent: 90), after: previous))
    }

    /// A reset is worth recording even when the percentage barely moved, because
    /// it is the boundary the whole segmentation hangs off.
    func testABoundaryIsStoredEvenInsideTheDeadband() {
        let previous = sample(at: start, percent: 0.2, resetAt: start.addingTimeInterval(600))
        let after = sample(at: start.addingTimeInterval(700), percent: 0.1,
                           resetAt: start.addingTimeInterval(700 + 5 * 3_600))
        XCTAssertTrue(UsageAnalysis.isAdmissible(after, after: previous))
    }

    // MARK: - Cycle boundaries

    func testUsageFallingFarEnoughIsAReset() {
        XCTAssertTrue(UsageAnalysis.isCycleBoundary(previous: sample(at: start, percent: 90),
                                                    current: sample(at: start.addingTimeInterval(900), percent: 2)))
    }

    /// Both halves of the drop rule are needed. A fall from 100 to 60 is large in
    /// absolute terms but is not a window starting over, and a rolling window
    /// decaying would otherwise register as a reset on every sample.
    func testALargeDropThatIsNotAResetIsNotABoundary() {
        XCTAssertFalse(UsageAnalysis.isCycleBoundary(previous: sample(at: start, percent: 100),
                                                     current: sample(at: start.addingTimeInterval(900), percent: 60)))
        // Small absolute drop, even though it more than halves.
        XCTAssertFalse(UsageAnalysis.isCycleBoundary(previous: sample(at: start, percent: 4),
                                                     current: sample(at: start.addingTimeInterval(900), percent: 1)))
    }

    /// The trap this rule exists for: Gemini's reset time is parsed from
    /// "resets in 5h" into `now + interval`, so it jitters on every probe. That
    /// jitter must never be read as a new cycle.
    func testGeminiResetJitterIsNotABoundary() {
        let previous = sample(at: start, percent: 30, resetAt: start.addingTimeInterval(5 * 3_600))
        // An hour later the CLI still says "5h", so the parsed reset slides an
        // hour further out while the real deadline has not moved.
        let jittered = sample(at: start.addingTimeInterval(3_600), percent: 31,
                              resetAt: start.addingTimeInterval(3_600 + 5 * 3_600))
        XCTAssertFalse(UsageAnalysis.isCycleBoundary(previous: previous, current: jittered))
    }

    func testAResetJumpingAFullWindowForwardIsABoundary() {
        let previous = sample(at: start, percent: 30, resetAt: start.addingTimeInterval(600))
        let after = sample(at: start.addingTimeInterval(300), percent: 30,
                           resetAt: start.addingTimeInterval(300 + 24 * 3_600))
        XCTAssertTrue(UsageAnalysis.isCycleBoundary(previous: previous, current: after))
    }

    /// A window that sat at 0% across its own reset has no drop to observe, so
    /// crossing the reset instant is the only signal there is.
    func testCrossingAKnownResetIsABoundaryEvenWithNoChange() {
        let previous = sample(at: start, percent: 0, resetAt: start.addingTimeInterval(600))
        XCTAssertFalse(UsageAnalysis.isCycleBoundary(
            previous: previous, current: sample(at: start.addingTimeInterval(500), percent: 0)))
        XCTAssertTrue(UsageAnalysis.isCycleBoundary(
            previous: previous, current: sample(at: start.addingTimeInterval(700), percent: 0)))
    }

    func testWithoutAResetTimeOnlyTheDropRuleApplies() {
        let previous = sample(at: start, percent: 50)
        XCTAssertFalse(UsageAnalysis.isCycleBoundary(
            previous: previous, current: sample(at: start.addingTimeInterval(30 * 86_400), percent: 51)))
        XCTAssertTrue(UsageAnalysis.isCycleBoundary(
            previous: previous, current: sample(at: start.addingTimeInterval(900), percent: 1)))
    }

    // MARK: - Segmentation

    func testCyclesAreSplitAtEveryReset() throws {
        var samples: [UsageSample] = []
        // Three five-hour cycles, each ramping 0 → 90.
        for cycle in 0..<3 {
            let base = start.addingTimeInterval(Double(cycle) * 5 * 3_600)
            for step in 0..<5 {
                let at = base.addingTimeInterval(Double(step) * 3_600)
                samples.append(sample(at: at, percent: Double(step) * 22.5,
                                      resetAt: base.addingTimeInterval(5 * 3_600)))
            }
        }
        let cycles = UsageAnalysis.cycles(for: samples)
        XCTAssertEqual(cycles.count, 3)
        // First is incomplete — we joined it partway through and cannot know its
        // real start. Last is incomplete — it is still running.
        XCTAssertEqual(cycles.map(\.isComplete), [false, true, false])
        XCTAssertEqual(try XCTUnwrap(cycles[1]).peakPercent, 90, accuracy: 0.01)
    }

    func testAnEmptyHistoryHasNoCycles() {
        XCTAssertTrue(UsageAnalysis.cycles(for: []).isEmpty)
    }

    /// `quotabar history --json` publishes these cycles in a documented order, so
    /// the expectation is built from `UsageAnalysis.order` itself. Comparing one
    /// grouping with a grouping of the same samples reversed would not pin it:
    /// `Dictionary(grouping:)` iterates in an order fixed by the per-process hash
    /// seed, so both calls agree with each other whether or not the sort is there.
    func testCyclesAreGroupedPerSeriesInTheDocumentedOrder() {
        let expected = Self.documentedSeriesOrder
        // One sample per series, so each series contributes exactly one cycle.
        let samples = expected.reversed().map { sample(series: $0, at: start, percent: 5) }

        XCTAssertEqual(UsageAnalysis.cycles(for: samples).map(\.series), expected)
        // And the input order does not reach the output.
        XCTAssertEqual(UsageAnalysis.cycles(for: samples.reversed()).map(\.series), expected)
    }

    /// A cycle watched end to end scores 1; the same cycle with the laptop shut
    /// for most of it does not. This is the number every recommendation is gated
    /// on, so both ends are pinned.
    func testCoverageReflectsHowMuchOfTheCycleWasWatched() throws {
        let complete = try XCTUnwrap(closedCycle(sampleEvery: 900))
        XCTAssertEqual(complete.observedFraction, 1, accuracy: 0.02)

        let sparse = try XCTUnwrap(closedCycle(sampleEvery: 5 * 3_600))
        XCTAssertLessThan(sparse.observedFraction, 0.5)
    }

    /// Joining a cycle late must read as poorly observed, or a week whose first
    /// three days went unrecorded would look like a quiet week.
    func testTimeBeforeTheFirstSampleCountsAgainstCoverage() throws {
        // Two cycles: the second is joined only for its final hour.
        var samples: [UsageSample] = []
        let firstReset = start.addingTimeInterval(24 * 3_600)
        for step in 0..<24 {
            samples.append(sample(at: start.addingTimeInterval(Double(step) * 3_600),
                                  percent: Double(step), resetAt: firstReset))
        }
        let secondReset = firstReset.addingTimeInterval(24 * 3_600)
        // One sample, right at the end of the second cycle.
        samples.append(sample(at: secondReset.addingTimeInterval(-1_800), percent: 3, resetAt: secondReset))
        samples.append(sample(at: secondReset.addingTimeInterval(600), percent: 0,
                              resetAt: secondReset.addingTimeInterval(24 * 3_600)))

        let cycles = UsageAnalysis.cycles(for: samples)
        let second = try XCTUnwrap(cycles.first { $0.isComplete })
        XCTAssertLessThan(second.observedFraction, 0.2)
    }

    // MARK: - Burn rate

    func testBurnRateIsThePerHourSlope() throws {
        let samples = (0..<8).map { sample(at: start.addingTimeInterval(Double($0) * 900),
                                           percent: Double($0) * 2.5) }
        let now = start.addingTimeInterval(8 * 900)
        XCTAssertEqual(try XCTUnwrap(UsageAnalysis.burnRate(samples, now: now)), 10, accuracy: 0.001)
    }

    /// Why Theil–Sen and not least squares: the deadband turns usage into steps,
    /// and one step dominates an OLS fit while barely moving a median.
    func testASingleStepDoesNotDominateTheBurnRate() throws {
        var samples = (0..<8).map { sample(at: start.addingTimeInterval(Double($0) * 900),
                                           percent: Double($0) * 2.5) }
        samples.append(sample(at: start.addingTimeInterval(8 * 900), percent: 95))
        let now = start.addingTimeInterval(9 * 900)
        let rate = try XCTUnwrap(UsageAnalysis.burnRate(samples, now: now))
        XCTAssertLessThan(rate, 40, "one jump must not drag the median to the jump's own slope")
        XCTAssertGreaterThan(rate, 9)
    }

    func testBurnRateNeedsTwoReadingsInsideTheWindow() {
        XCTAssertNil(UsageAnalysis.burnRate([], now: start))
        XCTAssertNil(UsageAnalysis.burnRate([sample(at: start, percent: 10)],
                                            now: start.addingTimeInterval(60)))
        // Both readings older than the window.
        let stale = [sample(at: start, percent: 10), sample(at: start.addingTimeInterval(60), percent: 20)]
        XCTAssertNil(UsageAnalysis.burnRate(stale, now: start.addingTimeInterval(10 * 3_600)))
    }

    func testAFlatOrFallingSeriesProjectsNothing() throws {
        let flat = (0..<4).map { sample(at: start.addingTimeInterval(Double($0) * 900), percent: 40) }
        let now = start.addingTimeInterval(4 * 900)
        XCTAssertEqual(try XCTUnwrap(UsageAnalysis.burnRate(flat, now: now)), 0, accuracy: 0.001)
        XCTAssertNil(UsageAnalysis.projectedExhaustion(from: sample(at: now, percent: 40),
                                                       burnRatePerHour: 0))
        XCTAssertNil(UsageAnalysis.projectedExhaustion(from: sample(at: now, percent: 40),
                                                       burnRatePerHour: -5))
    }

    func testProjectionIsTheRemainingHeadroomOverTheRate() throws {
        let latest = sample(at: start, percent: 40)
        let eta = try XCTUnwrap(UsageAnalysis.projectedExhaustion(from: latest, burnRatePerHour: 12))
        XCTAssertEqual(eta.timeIntervalSince(start), 5 * 3_600, accuracy: 1)
        // Already full: there is nothing left to project.
        XCTAssertNil(UsageAnalysis.projectedExhaustion(from: sample(at: start, percent: 100),
                                                       burnRatePerHour: 12))
    }

    // MARK: - Statistics

    func testMedianHandlesOddEvenAndEmpty() throws {
        XCTAssertNil(UsageAnalysis.median([]))
        XCTAssertEqual(try XCTUnwrap(UsageAnalysis.median([3, 1, 2])), 2)
        XCTAssertEqual(try XCTUnwrap(UsageAnalysis.median([4, 1, 3, 2])), 2.5)
    }

    /// Nearest-rank, so with a handful of cycles p90 is effectively the busiest.
    /// That is deliberate: "even the busiest week stayed low" is the claim.
    func testPercentileIsNearestRank() throws {
        XCTAssertNil(UsageAnalysis.percentile([], 0.9))
        XCTAssertEqual(try XCTUnwrap(UsageAnalysis.percentile([10, 20, 30, 40], 0.9)), 40)
        XCTAssertEqual(try XCTUnwrap(UsageAnalysis.percentile([10, 20, 30, 40], 0.5)), 20)
        XCTAssertEqual(try XCTUnwrap(UsageAnalysis.percentile([5], 0.9)), 5)
    }

    // MARK: - Snapshot conversion

    /// The rule that keeps the data honest: a failed probe is re-served with the
    /// previous windows attached, and storing that would draw a flat line the
    /// user never used.
    func testOnlySuccessfulSnapshotsBecomeSamples() {
        let good = QuotaSnapshot(provider: .codex,
                                 windows: [QuotaWindow(label: "Session", usedPercent: 40, resetAt: nil)])
        let failed = QuotaSnapshot(provider: .claude,
                                   windows: [QuotaWindow(label: "Weekly", usedPercent: 10, resetAt: nil)],
                                   error: "Refresh failed", probeSucceeded: false)
        let empty = QuotaSnapshot(provider: .gemini)

        let samples = UsageRecorder.samples(from: [good, failed, empty], now: start)
        XCTAssertEqual(samples.map(\.series.provider), [.codex])
        XCTAssertEqual(samples.first?.at, start)
    }

    /// One instant for the whole batch, so buckets and cycle spans line up across
    /// providers instead of scattering by however long each probe took.
    func testEverySampleInABatchSharesOneTimestamp() {
        let snapshots = [
            QuotaSnapshot(provider: .codex, windows: [
                QuotaWindow(label: "Session", usedPercent: 40, resetAt: nil),
                QuotaWindow(label: "Weekly", usedPercent: 10, resetAt: nil)]),
            QuotaSnapshot(provider: .claude, windows: [
                QuotaWindow(label: "Session", usedPercent: 5, resetAt: nil)])
        ]
        let samples = UsageRecorder.samples(from: snapshots, now: start)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(Set(samples.map(\.at)), [start])
    }

    /// Identity is the window key, so a provider renaming a label keeps its history.
    func testSamplesAreKeyedOnTheWindowKeyNotItsLabel() {
        let snapshot = QuotaSnapshot(provider: .codex,
                                     windows: [QuotaWindow(label: "5-hour limit", usedPercent: 40, resetAt: nil)])
        XCTAssertEqual(UsageRecorder.samples(from: [snapshot], now: start).first?.series.windowKey,
                       "5-hour-limit")
    }

    // MARK: - Fixtures

    /// A full cycle bracketed by resets, sampled every `sampleEvery` seconds.
    private func closedCycle(sampleEvery: TimeInterval) -> CycleSummary? {
        let length: TimeInterval = 24 * 3_600
        var samples: [UsageSample] = []
        // A first cycle so the second has a known start.
        samples.append(sample(at: start, percent: 90, resetAt: start.addingTimeInterval(60)))
        let base = start.addingTimeInterval(120)
        var offset: TimeInterval = 0
        while offset < length {
            samples.append(sample(at: base.addingTimeInterval(offset), percent: offset / length * 80,
                                  resetAt: base.addingTimeInterval(length)))
            offset += sampleEvery
        }
        samples.append(sample(at: base.addingTimeInterval(length + 60), percent: 0,
                              resetAt: base.addingTimeInterval(length * 2)))
        return UsageAnalysis.cycles(for: samples).first { $0.isComplete }
    }

    private func sample(series: HistorySeriesID? = nil, at: Date, percent: Double,
                        resetAt: Date? = nil) -> UsageSample {
        UsageSample(series: series ?? session, at: at, usedPercent: percent, resetAt: resetAt)
    }

    /// Every provider crossed with several window keys, arranged the way this
    /// module documents. Which arrangement that is stays out of the assertion on
    /// purpose — the test pins that the output follows `order`, not what `order`
    /// says. Fifteen series rather than two because an unsorted grouping picks an
    /// arrangement out of the hash seed: with two it would match by luck about
    /// half the time, with fifteen there are 15! ways to be wrong.
    private static let documentedSeriesOrder: [HistorySeriesID] = Provider.allCases
        .flatMap { provider in
            ["5h", "24h", "session", "weekly", "monthly"].map {
                HistorySeriesID(provider: provider, windowKey: $0)
            }
        }
        .sorted { UsageAnalysis.order($0) < UsageAnalysis.order($1) }
}
