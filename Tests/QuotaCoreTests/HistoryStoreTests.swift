import XCTest
import Foundation
import Dispatch
@testable import QuotaCore

/// The file-backed history log: round-trips, the damage it has to survive, the
/// files it must refuse to touch, retention, and the multi-process append race.
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    /// Shared across every store a test builds, so "reopened" means a new process
    /// on the same machine rather than one that has forgotten its series.
    private var backing: MemoryStateStore!
    /// A fixed instant so every offset in every assertion is arithmetic, not a
    /// race against the wall clock.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")
    private let weekly = HistorySeriesID(provider: .claude, windowKey: "weekly")

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backing = MemoryStateStore()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        backing = nil
        try super.tearDownWithError()
    }

    // MARK: - Round-trip

    /// The values have to survive the file, not just the encoder, so the read is
    /// done through a second store over the same path.
    func testSamplesRoundTripThroughTheFile() throws {
        let store = makeStore()
        let sample = UsageSample(series: session, at: start, usedPercent: 41.5,
                                 resetAt: start.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(store.append([sample]), 1)

        let reopened = makeStore()
        let result = reopened.read()
        XCTAssertNil(result.diagnostic)
        XCTAssertEqual(result.samples.count, 1)
        let restored = try XCTUnwrap(result.samples.first)
        XCTAssertEqual(restored.series, session)
        XCTAssertEqual(restored.at.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(restored.usedPercent, 41.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(restored.resetAt).timeIntervalSince1970,
                       start.addingTimeInterval(3 * 3_600).timeIntervalSince1970, accuracy: 60)
    }

    func testAppendingNothingWritesNothing() {
        let store = makeStore()
        XCTAssertEqual(store.append([]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL().path))
    }

    /// The state directory does not exist on a fresh install, so the first append
    /// has to make it rather than quietly failing.
    func testTheFirstAppendCreatesTheDirectory() {
        let nested = directory.appendingPathComponent("a/b/c/history.bin")
        let store = FileHistoryStore(url: nested, catalog: HistorySeriesCatalog(store: backing))
        XCTAssertEqual(store.append([sample(session, at: start, percent: 10)]), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testReadIsLimitedToTheRequestedRange() {
        let store = makeStore()
        store.append((0..<10).map { sample(session, at: start.addingTimeInterval(Double($0) * 3_600), percent: Double($0)) })

        let window = store.read(from: start.addingTimeInterval(3 * 3_600),
                                to: start.addingTimeInterval(5 * 3_600))
        XCTAssertEqual(window.samples.count, 3)
        XCTAssertEqual(window.samples.map { Int($0.usedPercent.rounded()) }, [3, 4, 5])
    }

    /// Two processes interleave their appends and a clock can step backwards, so
    /// file order is only approximately time order. Reads sort rather than drop:
    /// discarding the late arrival would silently lose the other writer's data.
    func testReadReturnsSamplesInTimeOrderEvenWhenTheFileIsNot() {
        let store = makeStore()
        store.append([sample(session, at: start.addingTimeInterval(300), percent: 30),
                      sample(session, at: start, percent: 10),
                      sample(session, at: start.addingTimeInterval(120), percent: 20)])

        let result = store.read()
        XCTAssertEqual(result.samples.map { Int($0.usedPercent.rounded()) }, [10, 20, 30])
        XCTAssertEqual(result.damagedRecords, 0)
    }

    /// A recorder only needs the latest reading per series to apply a deadband,
    /// and a series that stopped being sampled weeks ago still has one.
    func testHeadsReturnsTheLatestSamplePerSeries() throws {
        let store = makeStore()
        store.append([sample(weekly, at: start, percent: 5),
                      sample(session, at: start.addingTimeInterval(60), percent: 10),
                      sample(session, at: start.addingTimeInterval(120), percent: 20)])

        let heads = store.heads()
        XCTAssertEqual(heads.count, 2)
        XCTAssertEqual(try XCTUnwrap(heads[session]).usedPercent, 20, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(heads[weekly]).usedPercent, 5, accuracy: 0.01)
    }

    func testHeadsIsEmptyForAnAbsentFile() {
        XCTAssertTrue(makeStore().heads().isEmpty)
    }

    /// A sample that cannot be encoded is skipped; the ones beside it still land.
    /// Dropping the whole batch would lose good readings over one bad one.
    func testAnUnrepresentableSampleIsSkippedAndItsNeighboursSurvive() {
        let store = makeStore()
        let written = store.append([sample(session, at: start, percent: 10),
                                    sample(session, at: start.addingTimeInterval(60), percent: .nan),
                                    sample(session, at: start.addingTimeInterval(120), percent: 30)])
        XCTAssertEqual(written, 2)
        XCTAssertEqual(store.read().samples.map { Int($0.usedPercent.rounded()) }, [10, 30])
    }

    // MARK: - Damage

    /// A crash between two writes leaves fewer than a stride at the end. The read
    /// reports it rather than trusting it, and the next append repairs the file
    /// so record boundaries stay aligned.
    func testAPartialTailIsReportedAndThenRepaired() throws {
        let store = makeStore()
        store.append((0..<3).map { sample(session, at: start.addingTimeInterval(Double($0) * 60), percent: Double($0)) })

        let handle = try FileHandle(forUpdating: historyURL())
        let end = try handle.seekToEnd()
        try handle.truncate(atOffset: end - 5)
        try handle.close()

        let damaged = store.read()
        XCTAssertEqual(damaged.samples.count, 2)
        XCTAssertTrue(damaged.hasPartialTail)
        XCTAssertEqual(damaged.diagnostic, "an incomplete final record was discarded")

        store.append([sample(session, at: start.addingTimeInterval(600), percent: 90)])
        let repaired = store.read()
        XCTAssertEqual(repaired.samples.count, 3)
        XCTAssertFalse(repaired.hasPartialTail)
        XCTAssertNil(repaired.diagnostic)
    }

    /// A record whose series is not in the catalogue cannot be placed on any
    /// timeline. It is counted and skipped, never guessed at.
    func testRecordsWithAnUnknownSeriesAreCountedAsDamaged() {
        let catalog = HistorySeriesCatalog(store: backing)
        let store = FileHistoryStore(url: historyURL(), catalog: catalog)
        store.append([sample(session, at: start, percent: 10),
                      sample(weekly, at: start.addingTimeInterval(60), percent: 20)])

        catalog.removeAll()
        let result = store.read()
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertEqual(result.damagedRecords, 2)
        XCTAssertEqual(result.diagnostic, "2 damaged records ignored")
    }

    func testASingleDamagedRecordIsReportedInTheSingular() {
        let catalog = HistorySeriesCatalog(store: backing)
        let store = FileHistoryStore(url: historyURL(), catalog: catalog)
        store.append([sample(session, at: start, percent: 10)])
        catalog.removeAll()
        XCTAssertEqual(store.read().diagnostic, "1 damaged record ignored")
    }

    // MARK: - Files we must not touch

    /// A file a newer build wrote is read by nobody here and written by nobody
    /// here: downgrading and running the old binary must leave it byte-identical,
    /// so the build that understands it still finds it.
    func testANewerFormatIsLeftUntouched() throws {
        var header = HistoryFormat.Header(epoch: start)
        header.version = HistoryFormat.version + 1
        try header.encoded().write(to: historyURL())
        let before = try Data(contentsOf: historyURL())

        let store = makeStore()
        let result = store.read()
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertEqual(result.unreadableVersion, HistoryFormat.version + 1)
        XCTAssertEqual(result.diagnostic,
                       "History was written by a newer QuotaBar (format \(HistoryFormat.version + 1)) and was left unchanged.")

        XCTAssertEqual(store.append([sample(session, at: start, percent: 10)]), 0)
        XCTAssertEqual(try Data(contentsOf: historyURL()), before)
    }

    /// Same for an unfamiliar stride: the fields would be at the wrong offsets,
    /// so appending our own would interleave two incompatible layouts.
    func testAnUnfamiliarStrideIsLeftUntouched() throws {
        var header = HistoryFormat.Header(epoch: start)
        header.stride = 16
        try header.encoded().write(to: historyURL())
        let before = try Data(contentsOf: historyURL())

        let store = makeStore()
        XCTAssertEqual(store.append([sample(session, at: start, percent: 10)]), 0)
        XCTAssertEqual(try Data(contentsOf: historyURL()), before)
    }

    /// A long-enough file with a foreign magic belongs to something else.
    /// Refusing to record is recoverable; overwriting it is not.
    func testAForeignFileIsNeverOverwritten() throws {
        let foreign = Data(repeating: 0x41, count: 128)
        try foreign.write(to: historyURL())

        let store = makeStore()
        XCTAssertEqual(store.append([sample(session, at: start, percent: 10)]), 0)
        XCTAssertTrue(store.read().samples.isEmpty)
        XCTAssertEqual(try Data(contentsOf: historyURL()), foreign)
    }

    /// A file too short to hold a header cannot be anything of ours, so it is
    /// replaced rather than left to block recording forever.
    func testAStubFileIsReplacedWithAFreshHeader() throws {
        try Data(repeating: 0, count: 8).write(to: historyURL())
        let store = makeStore()
        XCTAssertEqual(store.append([sample(session, at: start, percent: 10)]), 1)
        XCTAssertEqual(store.read().samples.count, 1)
    }

    /// Failing to persist history must never become a failed quota refresh, so an
    /// unwritable path returns zero rather than throwing or trapping.
    func testAnUnwritableLocationIsTolerated() throws {
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let store = FileHistoryStore(url: blocker.appendingPathComponent("history.bin"),
                                     catalog: HistorySeriesCatalog(store: backing))

        XCTAssertEqual(store.append([sample(session, at: start, percent: 10)]), 0)
        XCTAssertTrue(store.read().samples.isEmpty)
        XCTAssertTrue(store.heads().isEmpty)
        XCTAssertFalse(store.needsCompaction(now: start))
        XCTAssertEqual(store.compact(now: start, horizon: 60), 0)
    }

    // MARK: - Retention

    func testCompactionDropsExpiredRecordsAndKeepsTheRest() throws {
        let store = makeStore()
        let horizon: TimeInterval = 10 * 86_400
        let now = start.addingTimeInterval(30 * 86_400)
        // Two samples older than the ten-day horizon, then three inside it.
        let ages: [Double] = [-12, -11, -9, -8, -7]
        store.append(ages.enumerated().map { index, days in
            sample(session, at: now.addingTimeInterval(days * 86_400), percent: Double(index))
        })

        XCTAssertTrue(store.needsCompaction(now: now, horizon: horizon))
        XCTAssertEqual(store.compact(now: now, horizon: horizon), 2)

        let result = store.read()
        XCTAssertEqual(result.samples.map { Int($0.usedPercent.rounded()) }, [2, 3, 4])
        XCTAssertNil(result.diagnostic)
        XCTAssertFalse(store.needsCompaction(now: now, horizon: horizon))
    }

    /// The header, and therefore the epoch every surviving offset is relative to,
    /// has to come through compaction unchanged or every kept record moves in time.
    func testCompactionPreservesTheHeaderEpoch() throws {
        let store = makeStore()
        let now = start.addingTimeInterval(30 * 86_400)
        store.append([sample(session, at: start, percent: 1),
                      sample(session, at: now, percent: 2)])
        let before = try XCTUnwrap(HistoryFormat.Header.decode(try Data(contentsOf: historyURL())))

        XCTAssertEqual(store.compact(now: now, horizon: 86_400), 1)

        let after = try XCTUnwrap(HistoryFormat.Header.decode(try Data(contentsOf: historyURL())))
        XCTAssertEqual(after, before)
        XCTAssertEqual(try XCTUnwrap(store.read().samples.first).at.timeIntervalSince1970,
                       now.timeIntervalSince1970, accuracy: 1)
    }

    func testCompactionIsANoOpWhenNothingHasExpired() throws {
        let store = makeStore()
        store.append((0..<3).map { sample(session, at: start.addingTimeInterval(Double($0) * 60), percent: Double($0)) })
        let before = try Data(contentsOf: historyURL())

        XCTAssertFalse(store.needsCompaction(now: start.addingTimeInterval(600)))
        XCTAssertEqual(store.compact(now: start.addingTimeInterval(600), horizon: 86_400), 0)
        XCTAssertEqual(try Data(contentsOf: historyURL()), before)
    }

    func testCompactionOfAnEmptyOrAbsentFileDoesNothing() throws {
        let store = makeStore()
        XCTAssertEqual(store.compact(now: start, horizon: 60), 0)
        XCTAssertFalse(store.needsCompaction(now: start))

        try HistoryFormat.Header(epoch: start).encoded().write(to: historyURL())
        XCTAssertEqual(store.compact(now: start, horizon: 60), 0)
        XCTAssertFalse(store.needsCompaction(now: start))
    }

    /// Age is not the only bound: a pathological refresh interval could fill the
    /// disk well inside the horizon, so size triggers a rewrite on its own.
    func testSizeAloneCanTriggerCompaction() throws {
        let store = makeStore()
        store.append([sample(session, at: start, percent: 10)])
        let padded = try Data(contentsOf: historyURL())
            + Data(repeating: 0, count: FileHistoryStore.maximumFileBytes)
        try padded.write(to: historyURL())
        XCTAssertTrue(store.needsCompaction(now: start, horizon: .greatestFiniteMagnitude))
    }

    func testRemoveAllDeletesTheFileAndForgetsTheSeries() {
        let catalog = HistorySeriesCatalog(store: backing)
        let store = FileHistoryStore(url: historyURL(), catalog: catalog)
        store.append([sample(session, at: start, percent: 10)])
        XCTAssertFalse(catalog.all().isEmpty)

        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL().path))
        XCTAssertTrue(catalog.all().isEmpty)
        XCTAssertTrue(store.read().samples.isEmpty)
    }

    // MARK: - Concurrency

    /// A `--watch` process and a one-shot invocation append at the same time. The
    /// state file solves this by merging under a lock; the log has to solve it by
    /// not losing anyone's records.
    func testConcurrentWritersKeepEveryRecord() {
        let writers = 8
        let perWriter = 12

        // Registration is covered on its own; pre-register so this test is about
        // concurrent appends to the file and nothing else.
        let registrar = HistorySeriesCatalog(store: backing)
        let names = (0..<writers).map { HistorySeriesID(provider: .gemini, windowKey: "w\($0)") }
        for name in names { _ = registrar.hash(for: name) }

        let url = historyURL()
        let origin = start
        let shared: StateStore = backing
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            let store = FileHistoryStore(url: url, catalog: HistorySeriesCatalog(store: shared))
            for index in 0..<perWriter {
                store.append([UsageSample(series: names[writer],
                                          at: origin.addingTimeInterval(Double(index) * 60),
                                          usedPercent: Double(index),
                                          resetAt: nil)])
            }
        }

        let result = FileHistoryStore(url: url, catalog: HistorySeriesCatalog(store: backing)).read()
        XCTAssertEqual(result.samples.count, writers * perWriter)
        XCTAssertEqual(result.damagedRecords, 0)
        XCTAssertFalse(result.hasPartialTail)
    }

    // MARK: - Footprint

    /// The whole point of a fixed-stride record is that three months fits in under
    /// a megabyte. A format change that inflates storage should fail here rather
    /// than on a user's disk.
    func testThreeMonthsOfSamplesStaysUnderOneMegabyte() throws {
        XCTAssertLessThan(try threeMonths(everyMinutes: 15), 1_024 * 1_024)
    }

    /// The same three months at the shortest interval `--watch` now accepts. The
    /// floor is what keeps this a number worth printing: `--interval` used to take
    /// any positive value, and at one minute a refresh the file grows fifteen
    /// times as fast as the default towards the 32 MB backstop.
    func testThreeMonthsAtTheShortestAcceptedIntervalStaysUnderThreeMegabytes() throws {
        let size = try threeMonths(everyMinutes: QuotaEngine.minimumRefreshMinutes)
        XCTAssertLessThan(size, 3 * 1_024 * 1_024)
        XCTAssertLessThan(size, UInt64(FileHistoryStore.maximumFileBytes) / 10)
    }

    /// Three months of eight quota windows sampled every `everyMinutes`, nothing
    /// suppressed, returning the size of the file it produced. Eight windows is
    /// what the three CLIs report between them, and the deadband can only ever
    /// make a real file smaller than this one.
    private func threeMonths(everyMinutes minutes: Int) throws -> UInt64 {
        let store = makeStore()
        let series = (0..<8).map { HistorySeriesID(provider: .gemini, windowKey: "series-\($0)") }
        let perDay = 24 * 60 / minutes
        let days = 92

        // Appended in day-sized batches so the test exercises the real append path
        // rather than one enormous write.
        for day in 0..<days {
            var batch: [UsageSample] = []
            for slot in 0..<perDay {
                let at = start.addingTimeInterval(Double(day) * 86_400
                    + Double(slot) * Double(minutes) * 60)
                for one in series {
                    batch.append(sample(one, at: at, percent: Double(slot % 101)))
                }
            }
            store.append(batch)
        }

        let handle = try FileHandle(forReadingFrom: historyURL())
        let size = try handle.seekToEnd()
        try handle.close()

        let expected = HistoryFormat.headerLength + series.count * perDay * days * HistoryFormat.recordStride
        XCTAssertEqual(Int(size), expected)
        return size
    }

    // MARK: - Fixtures

    private func historyURL() -> URL { directory.appendingPathComponent("history.bin") }

    private func makeStore() -> FileHistoryStore {
        FileHistoryStore(url: historyURL(), catalog: HistorySeriesCatalog(store: backing))
    }

    private func sample(_ series: HistorySeriesID, at: Date, percent: Double,
                        resetAt: Date? = nil) -> UsageSample {
        UsageSample(series: series, at: at, usedPercent: percent, resetAt: resetAt)
    }
}

// MARK: - Stubs

/// In-memory `StateStore` so the catalogue persists without a file. Locked
/// because the concurrency test shares one across writers.
private final class MemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var numbers: [String: Int] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { blobs[key] } }
    func setData(_ value: Data?, forKey key: String) { lock.withLock { blobs[key] = value } }
    func integer(forKey key: String) -> Int? { lock.withLock { numbers[key] } }
    func setInteger(_ value: Int?, forKey key: String) { lock.withLock { numbers[key] = value } }
}
