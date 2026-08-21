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
    func testAHashIsStableWithinAndAcrossInstances() {
        let store = MemoryStateStore()
        let first = HistorySeriesCatalog(store: store)
        let assigned = first.hash(for: session)
        XCTAssertEqual(first.hash(for: session), assigned)

        let second = HistorySeriesCatalog(store: store)
        XCTAssertEqual(second.hash(for: session), assigned)
        XCTAssertEqual(second.series(for: assigned), session)
    }

    /// Registration has to reach the store, not just memory: a hash a later
    /// process cannot look up turns its records into damaged ones.
    func testRegistrationIsPersisted() throws {
        let store = MemoryStateStore()
        let assigned = HistorySeriesCatalog(store: store).hash(for: session)
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
        let assigned = catalog.hash(for: session)

        XCTAssertNotEqual(assigned, contested)
        XCTAssertEqual(catalog.series(for: contested), weekly)
        XCTAssertEqual(catalog.series(for: assigned), session)
        // And the resolution is stable, not re-rolled on every lookup.
        XCTAssertEqual(HistorySeriesCatalog(store: store).hash(for: session), assigned)
    }

    /// A truncated or hand-edited payload must not wedge history shut: the map
    /// reads as empty and registration starts again.
    func testACorruptPayloadReadsAsEmpty() {
        let store = MemoryStateStore()
        store.setData(Data("not json".utf8), forKey: HistorySeriesCatalog.storageKey)

        let catalog = HistorySeriesCatalog(store: store)
        XCTAssertTrue(catalog.all().isEmpty)
        XCTAssertEqual(catalog.series(for: 1), nil)
        XCTAssertEqual(catalog.series(for: catalog.hash(for: session)), session)
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
    func testWritingMergesRatherThanReplacingAnotherProcessesRegistration() {
        let store = MemoryStateStore()
        let ours = HistorySeriesCatalog(store: store)
        let theirs = HistorySeriesCatalog(store: store)

        let theirHash = theirs.hash(for: weekly)
        let ourHash = ours.hash(for: session)

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
            results.record(HistorySeriesCatalog(store: store).hash(for: series))
        }

        XCTAssertEqual(Set(results.values()).count, 1)
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

    func data(forKey key: String) -> Data? { lock.withLock { blobs[key] } }
    func setData(_ value: Data?, forKey key: String) { lock.withLock { blobs[key] = value } }
    func integer(forKey key: String) -> Int? { lock.withLock { numbers[key] } }
    func setInteger(_ value: Int?, forKey key: String) { lock.withLock { numbers[key] = value } }
}
