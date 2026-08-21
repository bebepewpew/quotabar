import XCTest
import Foundation
import Dispatch
@testable import QuotaCore

/// The hash-to-series map. It is the authority on identity for every record in
/// the history file, so it has to be stable across launches, survive a corrupt
/// payload, and resolve a collision rather than silently merging two providers.
final class HistorySeriesCatalogTests: XCTestCase {
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")
    private let weekly = HistorySeriesID(provider: .codex, windowKey: "weekly")

    /// The same series must hash the same way in a later process, or every record
    /// already written stops resolving.
    func testAHashIsStableWithinAndAcrossInstances() throws {
        let store = MemoryStateStore()
        let first = HistorySeriesCatalog(store: store)
        let assigned = try XCTUnwrap(first.hash(for: session))
        XCTAssertEqual(first.hash(for: session), assigned)

        let second = HistorySeriesCatalog(store: store)
        XCTAssertEqual(second.hash(for: session), assigned)
        XCTAssertEqual(second.series(for: assigned), session)
    }

    /// Registration has to reach the store, not just memory: a hash a later
    /// process cannot look up turns its records into damaged ones.
    func testRegistrationIsPersisted() throws {
        let store = MemoryStateStore()
        let assigned = try XCTUnwrap(HistorySeriesCatalog(store: store).hash(for: session))
        XCTAssertNotNil(store.data(forKey: HistorySeriesCatalog.storageKey))
        XCTAssertEqual(HistorySeriesCatalog(store: store).series(for: assigned), session)
    }

    func testDistinctSeriesGetDistinctHashes() {
        let catalog = HistorySeriesCatalog(store: MemoryStateStore())
        XCTAssertNotEqual(catalog.hash(for: session), catalog.hash(for: weekly))
        XCTAssertEqual(catalog.all().count, 2)
    }

    /// A natural hash already claimed by a *different* series is vanishingly
    /// unlikely and completely silent when it happens — two providers' usage
    /// would merge into one line. Assignment re-salts instead.
    func testACollisionIsResolvedRatherThanShared() throws {
        let store = MemoryStateStore()
        // Seed the map so `weekly` already occupies the hash `session` would take.
        let contested = HistorySeriesCatalog.fnv1a(session.hashInput)
        let seeded = try JSONEncoder().encode([SeededEntry(hash: contested, series: weekly)])
        store.setData(seeded, forKey: HistorySeriesCatalog.storageKey)

        let catalog = HistorySeriesCatalog(store: store)
        let assigned = try XCTUnwrap(catalog.hash(for: session))

        XCTAssertNotEqual(assigned, contested)
        XCTAssertEqual(catalog.series(for: contested), weekly)
        XCTAssertEqual(catalog.series(for: assigned), session)
        // And the resolution is stable, not re-rolled on every lookup.
        XCTAssertEqual(HistorySeriesCatalog(store: store).hash(for: session), assigned)
    }

    /// A truncated or hand-edited payload must not wedge history shut: the map
    /// reads as empty and registration starts again.
    func testACorruptPayloadReadsAsEmpty() throws {
        let store = MemoryStateStore()
        store.setData(Data("not json".utf8), forKey: HistorySeriesCatalog.storageKey)

        let catalog = HistorySeriesCatalog(store: store)
        XCTAssertTrue(catalog.all().isEmpty)
        XCTAssertEqual(catalog.series(for: 1), nil)
        XCTAssertEqual(catalog.series(for: try XCTUnwrap(catalog.hash(for: session))), session)
    }

    func testAnUnknownHashResolvesToNothing() {
        let catalog = HistorySeriesCatalog(store: MemoryStateStore())
        _ = catalog.hash(for: session)
        XCTAssertNil(catalog.series(for: 0xDEAD_BEEF))
    }

    func testRemoveAllForgetsEveryMappingAndClearsTheStore() {
        let store = MemoryStateStore()
        let catalog = HistorySeriesCatalog(store: store)
        _ = catalog.hash(for: session)

        catalog.removeAll()
        XCTAssertTrue(catalog.all().isEmpty)
        XCTAssertNil(store.data(forKey: HistorySeriesCatalog.storageKey))
    }

    /// A second process registering a different series must not have its entry
    /// replaced by our start-of-process view — the same clobber
    /// `JSONFileStateStore` merges to avoid for its keys.
    func testWritingMergesRatherThanReplacingAnotherProcessesRegistration() throws {
        let store = MemoryStateStore()
        let ours = HistorySeriesCatalog(store: store)
        let theirs = HistorySeriesCatalog(store: store)

        let theirHash = try XCTUnwrap(theirs.hash(for: weekly))
        let ourHash = try XCTUnwrap(ours.hash(for: session))

        let reopened = HistorySeriesCatalog(store: store)
        XCTAssertEqual(reopened.series(for: theirHash), weekly)
        XCTAssertEqual(reopened.series(for: ourHash), session)
    }

    /// Two catalogues registering the same series at once must agree on one hash,
    /// because the records they are both about to write have to resolve.
    func testConcurrentRegistrationOfOneSeriesAgreesOnOneHash() {
        let store = MemoryStateStore()
        let results = Recorder<UInt32>()
        let series = session

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let hash = HistorySeriesCatalog(store: store).hash(for: series) { results.record(hash) }
        }

        XCTAssertEqual(results.values().count, 8)
        XCTAssertEqual(Set(results.values()).count, 1)
    }

    // MARK: - Bounds

    /// Window keys come out of CLI output and a registration is permanent, so the
    /// map needs a stated ceiling. Past it, registration is refused rather than
    /// persisted — and refusing is all it does: the caller keeps working.
    func testRegistrationStopsAtTheCeiling() throws {
        let store = MemoryStateStore()
        let catalog = HistorySeriesCatalog(store: store)
        let filling = (0..<HistorySeriesCatalog.maximumSeries).map {
            HistorySeriesID(provider: .gemini, windowKey: "gemini-model-\($0)")
        }
        XCTAssertEqual(catalog.hashes(for: filling).count, HistorySeriesCatalog.maximumSeries)
        XCTAssertEqual(catalog.all().count, HistorySeriesCatalog.maximumSeries)

        let refused = HistorySeriesID(provider: .gemini, windowKey: "gemini-one-too-many")
        XCTAssertNil(catalog.hash(for: refused))
        XCTAssertEqual(catalog.all().count, HistorySeriesCatalog.maximumSeries)
        // Nothing about the refusal reached the store, and a series already
        // registered still resolves.
        let reopened = HistorySeriesCatalog(store: store)
        XCTAssertEqual(reopened.all().count, HistorySeriesCatalog.maximumSeries)
        XCTAssertNil(reopened.series(for: HistorySeriesCatalog.fnv1a(refused.hashInput)))
        let stillKnown = try XCTUnwrap(catalog.hash(for: filling[0]))
        XCTAssertEqual(catalog.series(for: stillKnown), filling[0])
    }

    /// The last free slot goes to the first unregistered series in the batch, and
    /// the ones that do not fit are simply absent from the result.
    func testABatchIsTruncatedAtTheCeilingRatherThanRejected() {
        let store = MemoryStateStore()
        let catalog = HistorySeriesCatalog(store: store)
        let filling = (0..<(HistorySeriesCatalog.maximumSeries - 1)).map {
            HistorySeriesID(provider: .gemini, windowKey: "gemini-model-\($0)")
        }
        _ = catalog.hashes(for: filling)

        let resolved = catalog.hashes(for: [session, weekly])
        XCTAssertNotNil(resolved[session])
        XCTAssertNil(resolved[weekly])
        XCTAssertEqual(catalog.all().count, HistorySeriesCatalog.maximumSeries)
    }

    /// `StateStore` rewrites its whole file on every write, so a batch that
    /// introduces several series has to cost one write, not one per series — and
    /// a batch that introduces none has to cost no write at all.
    func testABatchRegistersEverySeriesInOneWrite() throws {
        let store = MemoryStateStore()
        let catalog = HistorySeriesCatalog(store: store)
        let batch = [session, weekly, session]

        let resolved = catalog.hashes(for: batch)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(Set(resolved.values).count, 2)
        XCTAssertEqual(store.setDataCalls, 1)
        XCTAssertEqual(resolved[session], try XCTUnwrap(catalog.hash(for: session)))

        XCTAssertEqual(catalog.hashes(for: batch), resolved)
        XCTAssertEqual(store.setDataCalls, 1)
    }

    // MARK: - Fixtures

    /// Mirrors the catalogue's own private `Entry` so a test can seed the store
    /// with a mapping the catalogue did not choose.
    private struct SeededEntry: Codable {
        let hash: UInt32
        let series: HistorySeriesID
    }

    // MARK: - Stubs

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Value] = []

        func record(_ value: Value) { lock.withLock { stored.append(value) } }
        func values() -> [Value] { lock.withLock { stored } }
    }
}

private final class MemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var numbers: [String: Int] = [:]
    private var writes = 0

    /// How many times anything has been written. A real `StateStore` rewrites its
    /// whole file per write, which is the cost batch registration exists to avoid.
    var setDataCalls: Int { lock.withLock { writes } }

    func data(forKey key: String) -> Data? { lock.withLock { blobs[key] } }
    func setData(_ value: Data?, forKey key: String) { lock.withLock { blobs[key] = value; writes += 1 } }
    func integer(forKey key: String) -> Int? { lock.withLock { numbers[key] } }
    func setInteger(_ value: Int?, forKey key: String) { lock.withLock { numbers[key] = value } }
}
