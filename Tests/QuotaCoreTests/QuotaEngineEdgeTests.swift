import XCTest
import Foundation
@testable import QuotaCore

/// The parts of `QuotaEngine` a stub cannot reach.
///
/// `QuotaEngineTests` drives everything through the injected loader/locator, which
/// deliberately never touches the default arguments — so the real discovery and
/// probe path, the one shipped builds actually run, was never executed at all.
/// It is exercised here for providers whose CLI this machine does not have:
/// every `fetch()` gives up at executable discovery, so the switch in
/// `QuotaEngine.probe` is covered without a provider CLI being launched.
///
/// The `SnapshotCache` tests below cover the persistence edges the round-trip
/// tests skip: duplicated providers in the stored blob, and a snapshot that
/// cannot be encoded at all.
final class QuotaEngineEdgeTests: XCTestCase {

    /// Providers with no CLI installed here. Resolved once: `CommandRunner.find`
    /// falls back to login shells, which is not worth repeating per test.
    private static let uninstalled: [Provider] =
        Provider.allCases.filter { CommandRunner.find($0.executableName) == nil }

    // MARK: - The default locator

    /// Discovery with no locator injected has to agree with `CommandRunner.find`
    /// and keep `Provider.allCases` order, whatever this machine has installed.
    func testDiscoverProvidersWithTheDefaultLocatorMatchesTheInstalledCLIs() async {
        let discovered = await QuotaEngine.discoverProviders()
        let installed = Provider.allCases.filter { !Self.uninstalled.contains($0) }
        XCTAssertEqual(discovered, installed)
        XCTAssertEqual(discovered, Provider.allCases.filter(discovered.contains),
                       "discovery must not reorder providers")
    }

    // MARK: - The default loader

    /// The default loader is the real probe. A provider whose CLI is absent must
    /// come back as a failed snapshot naming it, not as a trap or a blank error.
    func testTheDefaultLoaderReportsEveryUninstalledProviderAsMissing() throws {
        try XCTSkipIf(Self.uninstalled.isEmpty, "every provider CLI is installed on this machine")
        for provider in Self.uninstalled {
            let snapshot = QuotaEngine.load(provider)
            XCTAssertEqual(snapshot.provider, provider)
            XCTAssertFalse(snapshot.probeSucceeded, provider.rawValue)
            XCTAssertTrue(snapshot.windows.isEmpty, provider.rawValue)
            // `ProbeError.missing` is spelled with the provider's display name.
            XCTAssertEqual(snapshot.error, "\(provider.rawValue) is not installed")
        }
    }

    /// `loadAsync` and `refresh` each carry their own default loader, so a
    /// regression in either would leave the shipped path probing nothing.
    func testLoadAsyncAndRefreshUseTheSameDefaultProbe() async throws {
        try XCTSkipIf(Self.uninstalled.isEmpty, "every provider CLI is installed on this machine")
        let provider = try XCTUnwrap(Self.uninstalled.first)
        let expected = "\(provider.rawValue) is not installed"

        let single = await QuotaEngine.loadAsync(provider)
        XCTAssertEqual(single.error, expected)
        XCTAssertFalse(single.probeSucceeded)

        let refreshed = await QuotaEngine.refresh([provider])
        XCTAssertEqual(refreshed.map(\.provider), [provider])
        XCTAssertEqual(refreshed.map(\.error), [expected])
    }

    // MARK: - SnapshotCache

    /// Two entries for one provider can only come from a blob written by another
    /// build. The newest wins, the same last-in rule `retainingLastGood` uses,
    /// and decoding stays backward compatible rather than throwing the lot away.
    func testSnapshotCacheKeepsTheLastEntryForADuplicatedProvider() throws {
        let store = EdgeStateStore()
        let stale = QuotaSnapshot(provider: .codex, windows: [.init(label: "Session", usedPercent: 10, resetAt: nil)])
        let fresh = QuotaSnapshot(provider: .codex, windows: [.init(label: "Session", usedPercent: 90, resetAt: nil)])
        store.setData(try JSONEncoder().encode([stale, fresh]), forKey: SnapshotCache.key)

        let cache = SnapshotCache(store: store)
        XCTAssertEqual(cache.snapshot(for: .codex)?.windows.map(\.usedPercent), [90])
        XCTAssertEqual(cache.all().map(\.provider), [.codex], "the duplicate must collapse, not double up")
    }

    /// `all()` sorts by `Provider.allCases`, so the order cannot depend on how a
    /// dictionary happens to iterate — checked with every provider present.
    func testSnapshotCacheAllOrdersEveryProviderByAllCases() {
        let cache = SnapshotCache(store: EdgeStateStore())
        cache.update(with: Provider.allCases.reversed().map {
            QuotaSnapshot(provider: $0, windows: [.init(label: "Session", usedPercent: 1, resetAt: nil)])
        })
        XCTAssertEqual(cache.all().map(\.provider), Provider.allCases)
    }

    /// A percentage that is not a finite number cannot be written as JSON. The
    /// update still applies in memory, but the stored blob has to survive intact:
    /// overwriting it with nothing would lose every provider's last good value.
    func testSnapshotCacheKeepsStoredDataWhenASnapshotCannotBeEncoded() throws {
        let store = EdgeStateStore()
        let cache = SnapshotCache(store: store)
        cache.update(with: [.init(provider: .codex, windows: [.init(label: "Session", usedPercent: 42, resetAt: nil)])])
        let persisted = try XCTUnwrap(store.data(forKey: SnapshotCache.key))

        cache.update(with: [.init(provider: .gemini,
                                  windows: [.init(label: "2.5 Pro", usedPercent: .infinity, resetAt: nil)])])
        XCTAssertEqual(store.data(forKey: SnapshotCache.key), persisted,
                       "an unencodable snapshot must not replace what was already stored")
        XCTAssertEqual(SnapshotCache(store: store).all().map(\.provider), [.codex])
        XCTAssertEqual(store.writes, 1, "the failed encode must not reach the store at all")
    }
}

// MARK: - Stubs

/// In-memory `StateStore` that also counts writes, so a test can tell "wrote the
/// same bytes again" apart from "did not write".
private final class EdgeStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var numbers: [String: Int] = [:]
    private var writeCount = 0

    var writes: Int { lock.withLock { writeCount } }

    func data(forKey key: String) -> Data? { lock.withLock { blobs[key] } }

    func setData(_ value: Data?, forKey key: String) {
        lock.withLock {
            blobs[key] = value
            writeCount += 1
        }
    }

    func integer(forKey key: String) -> Int? { lock.withLock { numbers[key] } }
    func setInteger(_ value: Int?, forKey key: String) { lock.withLock { numbers[key] = value } }
}
