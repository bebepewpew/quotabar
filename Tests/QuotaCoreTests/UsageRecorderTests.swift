import XCTest
import Foundation
@testable import QuotaCore

/// The recorder is what every front-end calls after a refresh. It has to apply
/// the deadband, keep retention from running in the hot path, and never let a
/// history problem become a refresh problem.
final class UsageRecorderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testARefreshRecordsOneSamplePerWindow() {
        let store = ScriptedHistoryStore()
        let recorder = UsageRecorder(store: store)

        XCTAssertEqual(recorder.record([snapshot(.codex, [("Session", 40), ("Weekly", 10)])], now: start), 2)
        XCTAssertEqual(store.appended.count, 2)
    }

    /// The point of the deadband: a quota that has not moved is not re-recorded
    /// every fifteen minutes for three months.
    func testAnUnchangedReadingIsNotRecordedAgain() {
        let store = ScriptedHistoryStore()
        let recorder = UsageRecorder(store: store)

        XCTAssertEqual(recorder.record([snapshot(.codex, [("Session", 40)])], now: start), 1)
        XCTAssertEqual(recorder.record([snapshot(.codex, [("Session", 40)])],
                                       now: start.addingTimeInterval(900)), 0)
        XCTAssertEqual(recorder.record([snapshot(.codex, [("Session", 41)])],
                                       now: start.addingTimeInterval(1_800)), 1)
        XCTAssertEqual(store.appended.count, 2)
    }

    /// The head is read once and then kept, so a long-running app does not scan
    /// the file on every refresh.
    func testTheStoreIsOnlyReadForHeadsOnce() {
        let store = ScriptedHistoryStore()
        let recorder = UsageRecorder(store: store)

        for minute in 0..<5 {
            recorder.record([snapshot(.codex, [("Session", Double(minute) * 10)])],
                            now: start.addingTimeInterval(Double(minute) * 900))
        }
        XCTAssertEqual(store.headsCalls, 1)
    }

    /// A recorder starting up mid-cycle must not re-record what is already there.
    func testAnExistingHeadSuppressesADuplicateFirstReading() {
        let store = ScriptedHistoryStore()
        store.storedHeads = [
            HistorySeriesID(provider: .codex, windowKey: "session"):
                UsageSample(series: HistorySeriesID(provider: .codex, windowKey: "session"),
                            at: start, usedPercent: 40, resetAt: nil)
        ]
        let recorder = UsageRecorder(store: store)
        XCTAssertEqual(recorder.record([snapshot(.codex, [("Session", 40)])],
                                       now: start.addingTimeInterval(60)), 0)
    }

    func testASnapshotCarryingAnErrorIsNotRecorded() {
        let store = ScriptedHistoryStore()
        let recorder = UsageRecorder(store: store)
        var failed = snapshot(.codex, [("Session", 40)])
        failed.error = "Refresh failed"
        failed.probeSucceeded = false

        XCTAssertEqual(recorder.record([failed], now: start), 0)
        XCTAssertTrue(store.appended.isEmpty)
    }

    func testNothingToRecordTouchesNeitherTheFileNorRetention() {
        let store = ScriptedHistoryStore()
        let recorder = UsageRecorder(store: store)

        XCTAssertEqual(recorder.record([], now: start), 0)
        XCTAssertEqual(store.appendCalls, 0)
        XCTAssertEqual(store.needsCompactionCalls, 0)
    }

    /// Retention is asked about on every refresh but only ever runs when the file
    /// has actually aged, so the common path stays one append.
    func testCompactionRunsOnlyWhenTheStoreSaysItIsDue() {
        let store = ScriptedHistoryStore()
        let recorder = UsageRecorder(store: store)

        recorder.record([snapshot(.codex, [("Session", 10)])], now: start)
        XCTAssertEqual(store.needsCompactionCalls, 1)
        XCTAssertEqual(store.compactCalls, 0)

        store.compactionDue = true
        recorder.record([snapshot(.codex, [("Session", 80)])], now: start.addingTimeInterval(900))
        XCTAssertEqual(store.compactCalls, 1)
    }

    func testTheHorizonReachesTheStore() {
        let store = ScriptedHistoryStore()
        store.compactionDue = true
        let recorder = UsageRecorder(store: store, horizon: 42 * 86_400)

        recorder.record([snapshot(.codex, [("Session", 10)])], now: start)
        XCTAssertEqual(store.lastHorizon, 42 * 86_400)
    }

    /// A history file that cannot be written must never turn a working refresh
    /// into a failure, so the recorder reports zero rather than throwing.
    func testAStoreThatCannotWriteIsTolerated() {
        let store = ScriptedHistoryStore()
        store.refuseWrites = true
        let recorder = UsageRecorder(store: store)

        XCTAssertEqual(recorder.record([snapshot(.codex, [("Session", 40)])], now: start), 0)
    }

    // MARK: - Fixtures

    private func snapshot(_ provider: Provider, _ windows: [(String, Double)]) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider,
                      windows: windows.map { QuotaWindow(label: $0.0, usedPercent: $0.1, resetAt: nil) })
    }

    // MARK: - Stubs

    /// A `HistoryStore` that records what it was asked to do, so the recorder's
    /// decisions are visible without a file.
    private final class ScriptedHistoryStore: HistoryStore, @unchecked Sendable {
        var storedHeads: [HistorySeriesID: UsageSample] = [:]
        var appended: [UsageSample] = []
        var appendCalls = 0
        var headsCalls = 0
        var compactCalls = 0
        var needsCompactionCalls = 0
        var compactionDue = false
        var refuseWrites = false
        var lastHorizon: TimeInterval?

        func append(_ samples: [UsageSample]) -> Int {
            appendCalls += 1
            guard !refuseWrites else { return 0 }
            appended += samples
            return samples.count
        }

        func read(from: Date, to: Date) -> HistoryReadResult {
            HistoryReadResult(samples: appended.filter { $0.at >= from && $0.at <= to })
        }

        func heads() -> [HistorySeriesID: UsageSample] {
            headsCalls += 1
            return storedHeads
        }

        func compact(now: Date, horizon: TimeInterval) -> Int {
            compactCalls += 1
            lastHorizon = horizon
            return 0
        }

        func needsCompaction(now: Date, horizon: TimeInterval) -> Bool {
            needsCompactionCalls += 1
            lastHorizon = horizon
            return compactionDue
        }

        func removeAll() { appended = [] }
    }
}
