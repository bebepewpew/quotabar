import XCTest
import Foundation
@testable import QuotaCore

/// The coordinator exists to order three things against each other: a refresh
/// appending, a refresh reading back, and the user pressing "Delete history".
/// These tests are about the orderings, not about the advisor rules, which
/// `AdvisorTests` already covers.
final class UsageHistoryCoordinatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")

    // MARK: - The ordinary path

    func testAReloadRecordsTheRefreshAndReportsWhatIsStored() {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store, span: 3_600, buckets: 4)

        let overview = coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)], now: start)

        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(overview?.strips[session], [nil, nil, nil, 40])
        XCTAssertEqual(overview?.recommendations.map(\.kind), [.insufficientData])
        // The label is display data carried by the live snapshot, not by the key.
        XCTAssertEqual(overview?.recommendations.first?.windowLabel, "Session")
    }

    func testAStripCoversOnlyTheSparklineSpan() {
        let store = ScriptedHistoryStore()
        store.seed([sample(at: start.addingTimeInterval(-7_200), 10),
                    sample(at: start.addingTimeInterval(-1_800), 60)])
        let coordinator = UsageHistoryCoordinator(history: store, span: 3_600, buckets: 4)

        let overview = coordinator.reload(recording: [], snapshots: [snapshot(60)], now: start)

        XCTAssertEqual(overview?.strips[session], [nil, nil, 60, nil],
                       "the reading from two hours ago is outside a one-hour span")
    }

    /// A reload asks for the span it can actually use, never the whole file: the
    /// panel promises never to hold three months of samples, and a refresh that
    /// materialised them to throw almost all away would break that promise.
    func testAReloadReadsOnlyTheSpanItCanUse() throws {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store)

        _ = coordinator.reload(recording: [], snapshots: [], now: start)

        let range = try XCTUnwrap(store.reads.first)
        XCTAssertEqual(store.reads.count, 1)
        XCTAssertEqual(range.to, start)
        XCTAssertEqual(range.from, start.addingTimeInterval(-Advisor.adviceLookback))
        XCTAssertGreaterThan(range.from, .distantPast)
        XCTAssertLessThan(range.to, .distantFuture)
    }

    /// The advisor's lookback is the floor, not the answer: a caller drawing a
    /// longer strip than that has to be given the samples to draw it with.
    func testAStripLongerThanTheAdvisorsLookbackWidensTheRead() throws {
        let store = ScriptedHistoryStore()
        let span = Advisor.adviceLookback + 86_400
        let coordinator = UsageHistoryCoordinator(history: store, span: span)

        _ = coordinator.reload(recording: [], snapshots: [], now: start)

        let range = try XCTUnwrap(store.reads.first)
        XCTAssertEqual(range.from, start.addingTimeInterval(-span))
    }

    // MARK: - Clearing against an in-flight reload

    /// The headline of the issue: a clear that lands mid-reload must not be
    /// undone by results the reload computed before it.
    func testAClearWhileTheReloadIsInsideTheStoreLeavesNothingToPublish() {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store)
        let removal = Box<(@Sendable () -> Void)?>(nil)
        // Pressed while the reload sits between its append and its return.
        store.onRead = { removal.value = coordinator.clear() }

        let overview = coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)], now: start)

        XCTAssertNil(overview, "a reload the clear overtook must publish nothing")
        XCTAssertEqual(store.appendCalls, 1, "the append it had already started still completed")
        removal.value?()
        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertEqual(UsageHistoryCoordinator.overview(from: store.samples, snapshots: [], now: start),
                       .empty, "zero samples, zero recommendations, zero strips")
    }

    /// A reload that has not recorded yet must not record at all: appending to a
    /// history the user just deleted is the half of the bug the UI cannot hide.
    func testAClearBeforeTheReloadRecordsStopsItRecordingAtAll() {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store)
        let started = coordinator.generation

        let remove = coordinator.clear()

        XCTAssertNil(coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)],
                                        now: start, since: started))
        XCTAssertEqual(store.appendCalls, 0)
        remove()
        XCTAssertTrue(store.samples.isEmpty)
    }

    /// The window the generation alone cannot close. `clear` bumps it
    /// synchronously and hands the unlink back as a closure the caller runs
    /// later, off its actor; a reload starting in between captures the
    /// *post*-clear generation, so every generation check agrees while the file
    /// is still on disk and still condemned. It would append to a file about to
    /// be deleted and publish an overview built from the samples the user just
    /// deleted.
    func testAReloadStartedBeforeThePendingRemovalRunsRecordsAndPublishesNothing() {
        let store = ScriptedHistoryStore()
        store.seed([sample(at: start.addingTimeInterval(-60), 80)])
        let coordinator = UsageHistoryCoordinator(history: store, span: 3_600, buckets: 4)

        let remove = coordinator.clear()
        // Captured after the clear, exactly as `QuotaStore.reloadHistory` does
        // when the main actor reaches it before the detached removal runs.
        let overview = coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)],
                                          now: start, since: coordinator.generation)

        XCTAssertNil(overview, "the file it would describe is already condemned")
        XCTAssertEqual(store.appendCalls, 0, "nothing is appended to a history awaiting removal")
        remove()
        XCTAssertTrue(store.samples.isEmpty)
    }

    /// Two clears pressed before either removal runs. Releasing the first must
    /// not make the file look usable while the second unlink is still coming.
    func testASecondPendingRemovalKeepsAReloadWaitingAfterTheFirstHasRun() {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store, span: 3_600, buckets: 4)

        let first = coordinator.clear()
        let second = coordinator.clear()
        first()
        // Twice, because a caller that runs one removal again must not release
        // the other one's hold on the file.
        first()

        XCTAssertNil(coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)],
                                        now: start, since: coordinator.generation))
        XCTAssertEqual(store.appendCalls, 0)

        second()

        XCTAssertNotNil(coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)],
                                           now: start, since: coordinator.generation),
                        "once every removal has run the history is usable again")
        XCTAssertEqual(store.samples.count, 1)
    }

    /// Pause an in-flight reload, clear, resume it. The removal waits for the
    /// append rather than interleaving with it, and still wins.
    func testAPausedReloadResumedAfterAClearFinishesWithAnEmptyHistory() {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store)
        let inside = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        store.onHeads = {
            inside.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 10), .success)
        }

        let result = Box<UsageOverview?>(.empty)
        let refreshed = snapshot(40)
        let began = start
        let reloaded = expectation(description: "reload returned")
        DispatchQueue.global().async {
            result.value = coordinator.reload(recording: [refreshed], snapshots: [refreshed], now: began)
            reloaded.fulfill()
        }
        XCTAssertEqual(inside.wait(timeout: .now() + 10), .success)

        let remove = coordinator.clear()
        let removed = expectation(description: "removal returned")
        DispatchQueue.global().async {
            remove()
            removed.fulfill()
        }
        resume.signal()
        wait(for: [reloaded, removed], timeout: 20)

        XCTAssertNil(result.value)
        XCTAssertEqual(store.appendCalls, 1)
        XCTAssertEqual(store.removeAllCalls, 1)
        XCTAssertTrue(store.samples.isEmpty)
    }

    // MARK: - Clearing on its own

    func testClearingWithNoReloadRunningTakesEffectAtOnce() {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store)
        XCTAssertNotNil(coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)], now: start))
        let before = coordinator.generation

        let remove = coordinator.clear()

        XCTAssertNotEqual(coordinator.generation, before,
                          "the observable half of a clear is synchronous")
        XCTAssertEqual(store.removeAllCalls, 0,
                       "the file half is not, so it never takes a lock on the main actor")
        remove()
        XCTAssertEqual(store.removeAllCalls, 1)
        XCTAssertTrue(store.samples.isEmpty)
    }

    /// The recorder caches the newest sample per series. After a clear that head
    /// describes something that no longer exists, and leaving it in place makes
    /// the deadband swallow the first reading of the fresh history.
    func testARefreshBegunAfterAClearRecordsNormally() {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store, span: 3_600, buckets: 4)
        XCTAssertNotNil(coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)], now: start))
        XCTAssertEqual(store.samples.count, 1)

        coordinator.clear()()
        XCTAssertTrue(store.samples.isEmpty)

        let after = coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)],
                                       now: start.addingTimeInterval(300))

        XCTAssertEqual(store.samples.count, 1, "the same reading is new again once history is gone")
        XCTAssertEqual(after?.strips[session]?.compactMap { $0 }, [40])
    }

    func testAReloadAfterAClearIsPublishedRatherThanDiscarded() {
        let store = ScriptedHistoryStore()
        let coordinator = UsageHistoryCoordinator(history: store)
        coordinator.clear()()

        let started = coordinator.generation
        let after = coordinator.reload(recording: [snapshot(40)], snapshots: [snapshot(40)],
                                       now: start, since: started)

        XCTAssertNotNil(after, "only a clear that came later invalidates a reload")
    }

    // MARK: - Fixtures

    private func snapshot(_ used: Double) -> QuotaSnapshot {
        QuotaSnapshot(provider: .codex,
                      windows: [QuotaWindow(label: "Session", usedPercent: used, resetAt: nil)])
    }

    private func sample(at: Date, _ used: Double) -> UsageSample {
        UsageSample(series: session, at: at, usedPercent: used, resetAt: nil)
    }

    // MARK: - Stubs

    /// A `HistoryStore` with hooks, so a clear can be pressed at an exact point
    /// inside a reload without a sleep.
    private final class ScriptedHistoryStore: HistoryStore, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UsageSample] = []
        private var counters = (append: 0, read: 0, removeAll: 0)
        private var hooks: (heads: (@Sendable () -> Void)?, read: (@Sendable () -> Void)?)
        private var ranges: [(from: Date, to: Date)] = []

        var samples: [UsageSample] { lock.withLock { stored } }
        /// The spans `read` was asked for, so a test can assert the reload does
        /// not ask for the whole file.
        var reads: [(from: Date, to: Date)] { lock.withLock { ranges } }
        var appendCalls: Int { lock.withLock { counters.append } }
        var removeAllCalls: Int { lock.withLock { counters.removeAll } }
        var onHeads: (@Sendable () -> Void)? {
            get { lock.withLock { hooks.heads } }
            set { lock.withLock { hooks.heads = newValue } }
        }
        var onRead: (@Sendable () -> Void)? {
            get { lock.withLock { hooks.read } }
            set { lock.withLock { hooks.read = newValue } }
        }

        func seed(_ samples: [UsageSample]) { lock.withLock { stored += samples } }

        func append(_ samples: [UsageSample]) -> Int {
            lock.withLock {
                counters.append += 1
                stored += samples
            }
            return samples.count
        }

        func read(from: Date, to: Date) -> HistoryReadResult {
            let hook = onRead
            hook?()
            return HistoryReadResult(samples: lock.withLock {
                counters.read += 1
                ranges.append((from: from, to: to))
                return stored.filter { $0.at >= from && $0.at <= to }
            })
        }

        func heads() -> [HistorySeriesID: UsageSample] {
            let hook = onHeads
            hook?()
            return lock.withLock {
                var latest: [HistorySeriesID: UsageSample] = [:]
                for sample in stored where (latest[sample.series]?.at ?? .distantPast) <= sample.at {
                    latest[sample.series] = sample
                }
                return latest
            }
        }

        func compact(now: Date, horizon: TimeInterval) -> Int { 0 }
        func needsCompaction(now: Date, horizon: TimeInterval) -> Bool { false }

        func removeAll() {
            lock.withLock {
                counters.removeAll += 1
                stored = []
            }
        }
    }

    /// A mutable slot two threads can share, so a result produced off the test
    /// thread can be asserted on it.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) { stored = value }

        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
