import XCTest
import Foundation
@testable import QuotaCore

/// How much history one refresh is allowed to read.
///
/// Both front-ends used to materialise and sort the entire log — three months of
/// records — to draw a week of sparkline and forecast the next few hours. These
/// pin the two bounded spans that replaced it: wide enough that the answers are
/// unchanged, and bounded at all, which `read()` was not.
final class AdvisorLookbackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let weekly = HistorySeriesID(provider: .codex, windowKey: "weekly")
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")

    // MARK: - The advice lookback

    func testTheAdviceLookbackCoversEverythingTheAdvisorCanUse() {
        // The cycles `usableCycles` keeps, plus the boundary that opens the
        // oldest of them, at the longest window any provider reports.
        XCTAssertGreaterThanOrEqual(Advisor.adviceLookback,
                                    Double(Advisor.recentCycleCount + 1) * 7 * 86_400)
        // A series silent for longer than this is not advised on at all.
        XCTAssertGreaterThanOrEqual(Advisor.adviceLookback, Advisor.staleAfterDays * 86_400)
        // The menu bar draws its sparklines from the same read.
        XCTAssertGreaterThanOrEqual(Advisor.adviceLookback, 7 * 86_400)
        // And it is still a bound, not the whole retained file.
        XCTAssertLessThan(Advisor.adviceLookback, FileHistoryStore.defaultHorizon)
    }

    /// The claim the bound rests on: the same advice from a fraction of the file.
    func testAdviceOverTheLookbackMatchesAdviceOverTheWholeRecord() {
        let history = twentyWeeklyCycles()
        let recent = history.filter { $0.at >= now.addingTimeInterval(-Advisor.adviceLookback) }
        // A third of the record is never materialised, and the answer is the same.
        XCTAssertLessThan(recent.count, history.count * 2 / 3)

        let full = advice(over: history)
        XCTAssertTrue(full.contains { $0.kind == .underUtilized }, "\(full)")
        XCTAssertEqual(advice(over: recent), full)
    }

    /// And that comparison can fail: a lookback a few cycles short loses the
    /// evidence and the advisor stops being able to say anything.
    func testALookbackTooShortToHoldTheCyclesChangesTheAdvice() {
        let history = twentyWeeklyCycles()
        let tooShort = history.filter { $0.at >= now.addingTimeInterval(-3 * 7 * 86_400) }

        let short = advice(over: tooShort)
        XCTAssertNotEqual(short, advice(over: history))
        XCTAssertTrue(short.contains { $0.kind == .insufficientData }, "\(short)")
    }

    // MARK: - The forecast lookback

    func testAProjectionReadsOnlyTheBurnRateWindow() throws {
        let store = RecordingHistoryStore()

        XCTAssertTrue(Advisor.projections(from: store, for: [], now: now).isEmpty)

        XCTAssertEqual(store.reads.count, 1)
        let range = try XCTUnwrap(store.reads.first)
        XCTAssertEqual(range.from, now.addingTimeInterval(-UsageAnalysis.burnRateWindow))
        XCTAssertEqual(range.to, now)
        // What `read()` would have asked for, and no longer does.
        XCTAssertGreaterThan(range.from, .distantPast)
        XCTAssertLessThan(range.to, .distantFuture)
    }

    /// Nothing older than the burn-rate window can move a forecast, so bounding
    /// the read has to leave it identical to one taken over everything.
    func testAProjectionIsUnchangedByTheRecordsTheBoundExcludes() {
        let store = RecordingHistoryStore()
        store.samples = threeMonthsOfNoise() + aRisingSession()
        let snapshots = [QuotaSnapshot(provider: .codex,
                                       windows: [QuotaWindow(key: "session", label: "5-hour limit",
                                                             usedPercent: 88, resetAt: reset)])]

        let bounded = Advisor.projections(from: store, for: snapshots, now: now)
        let unbounded = Advisor
            .recommendations(for: Advisor.inputs(history: store.samples, snapshots: snapshots, now: now),
                             now: now)
            .filter { $0.kind == .projectedExhaustion }

        XCTAssertEqual(bounded.map(\.kind), [.projectedExhaustion])
        XCTAssertEqual(bounded, unbounded)
        XCTAssertEqual(bounded.first?.series, session)
    }

    /// Only forecasts. A quiet window still produces `insufficientData` from the
    /// advisor, and a notification path must not deliver that as an alert.
    func testAProjectionPassReturnsNothingButForecasts() {
        let store = RecordingHistoryStore()
        store.samples = [UsageSample(series: session, at: now.addingTimeInterval(-600),
                                     usedPercent: 5, resetAt: reset)]
        XCTAssertTrue(Advisor.projections(from: store, for: [], now: now).isEmpty)
        XCTAssertEqual(store.reads.count, 1)
    }

    /// One read per pass, whatever it finds: the notify path used to build a
    /// second store and scan the file again on every tick.
    func testEachProjectionPassReadsExactlyOnce() {
        let store = RecordingHistoryStore()
        store.samples = aRisingSession()
        for _ in 0..<3 { _ = Advisor.projections(from: store, for: [], now: now) }
        XCTAssertEqual(store.reads.count, 3)
    }

    // MARK: - Fixtures

    private var reset: Date { now.addingTimeInterval(2 * 3_600) }

    private func advice(over history: [UsageSample]) -> [Recommendation] {
        Advisor.recommendations(for: Advisor.inputs(history: history, snapshots: [], now: now), now: now)
    }

    /// Twenty weekly cycles, the older eleven exhausted and the recent nine
    /// light, sampled every two hours so every one of them is fully observed.
    /// The newest is three days in, the way a running cycle is.
    private func twentyWeeklyCycles() -> [UsageSample] {
        let length: TimeInterval = 7 * 86_400
        let step = UsageAnalysis.coverageCredit
        let currentStart = now.addingTimeInterval(-3 * 86_400)
        var samples: [UsageSample] = []
        for index in 0..<20 {
            let start = currentStart.addingTimeInterval(-Double(19 - index) * length)
            let reset = start.addingTimeInterval(length)
            let peak = index < 11 ? 98.0 : 30.0
            var at = start
            while at < min(reset, now) {
                samples.append(UsageSample(series: weekly, at: at,
                                           usedPercent: peak * at.timeIntervalSince(start) / length,
                                           resetAt: reset))
                at = at.addingTimeInterval(step)
            }
        }
        return samples
    }

    /// A session window climbing four points a quarter of an hour — enough of a
    /// rate to run out before the reset two hours from now.
    private func aRisingSession() -> [UsageSample] {
        (0..<8).map {
            UsageSample(series: session, at: now.addingTimeInterval(Double($0 - 8) * 900),
                        usedPercent: 60 + Double($0) * 4, resetAt: reset)
        }
    }

    /// The part of the file a bounded read never touches.
    private func threeMonthsOfNoise() -> [UsageSample] {
        (0..<600).map {
            UsageSample(series: session,
                        at: now.addingTimeInterval(-90 * 86_400 + Double($0) * 3_600),
                        usedPercent: Double($0 % 100), resetAt: nil)
        }
    }

    // MARK: - Stubs

    /// A store that honours the range it is handed and remembers what it was, so
    /// the span a caller reads is assertable without a file.
    private final class RecordingHistoryStore: HistoryStore, @unchecked Sendable {
        var samples: [UsageSample] = []
        private(set) var reads: [(from: Date, to: Date)] = []

        func append(_ samples: [UsageSample]) -> Int {
            self.samples += samples
            return samples.count
        }

        func read(from: Date, to: Date) -> HistoryReadResult {
            reads.append((from: from, to: to))
            return HistoryReadResult(samples: samples.filter { $0.at >= from && $0.at <= to }
                .sorted { $0.at < $1.at })
        }

        func heads() -> [HistorySeriesID: UsageSample] { [:] }
        func compact(now: Date, horizon: TimeInterval) -> Int { 0 }
        func needsCompaction(now: Date, horizon: TimeInterval) -> Bool { false }
        func removeAll() { samples = [] }
    }
}
