import XCTest
import Foundation
@testable import QuotaCore

/// `QuotaEngine`'s discovery, probing and refresh entry points used to be
/// unreachable from a test because they went straight to the provider CLIs. They
/// now take a loader/locator closure that defaults to the real implementation, so
/// everything here runs with stubs and never launches a subprocess.
final class QuotaEngineTests: XCTestCase {

    // MARK: - discoverProviders

    func testDiscoverProvidersKeepsOnlyInstalledCLIsInAllCasesOrder() async {
        let installed: Set<String> = ["codex", "gemini"]
        let providers = await QuotaEngine.discoverProviders { name in
            installed.contains(name) ? "/usr/local/bin/\(name)" : nil
        }
        // `Provider.allCases` is gemini, claude, codex — discovery must not reorder.
        XCTAssertEqual(providers, [.gemini, .codex])
    }

    func testDiscoverProvidersReturnsEveryProviderWhenAllAreInstalled() async {
        let providers = await QuotaEngine.discoverProviders { "/opt/homebrew/bin/\($0)" }
        XCTAssertEqual(providers, Provider.allCases)
    }

    func testDiscoverProvidersReturnsNothingWhenNoCLIIsInstalled() async {
        let providers = await QuotaEngine.discoverProviders { _ in nil }
        XCTAssertTrue(providers.isEmpty)
    }

    /// The locator is asked for the executable name, not the display name — a
    /// regression here would make every provider look uninstalled.
    func testDiscoverProvidersLooksUpExecutableNames() async {
        let seen = Recorder<String>()
        _ = await QuotaEngine.discoverProviders { name in
            seen.append(name)
            return nil
        }
        XCTAssertEqual(seen.values.sorted(), ["claude", "codex", "gemini"])
    }

    // MARK: - load / loadAsync

    func testLoadReturnsWhateverTheLoaderProduced() {
        let snapshot = QuotaEngine.load(.claude) { provider in
            .init(provider: provider, windows: [.init(label: "Session", usedPercent: 41, resetAt: nil)], plan: "max")
        }
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [41])
        XCTAssertTrue(snapshot.probeSucceeded)
        XCTAssertNil(snapshot.error)
    }

    /// A timeout carries whatever the child had already printed so the probe can
    /// classify it. That payload is untrusted CLI output and must never reach the
    /// snapshot the menu and the CLI display.
    func testLoadTurnsAThrownProbeErrorIntoAFailedSnapshot() {
        let timeout = ProbeError.timeout(partialOutput: "QUOTABAR_TRUST\nsecret-transcript-42")
        let snapshot = QuotaEngine.load(.gemini) { _ in throw timeout }
        XCTAssertEqual(snapshot.provider, .gemini)
        XCTAssertFalse(snapshot.probeSucceeded)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.error, "The CLI did not respond in time")
        XCTAssertFalse(snapshot.error?.contains("secret-transcript-42") ?? true,
                       "the partial transcript is diagnostic input, not display text")
    }

    /// Anything a probe throws has to survive as readable text, not just
    /// `ProbeError` — the snapshot's error is what the menu and the CLI print.
    func testLoadDescribesNonProbeErrors() {
        let snapshot = QuotaEngine.load(.codex) { _ in throw StubError() }
        XCTAssertFalse(snapshot.probeSucceeded)
        XCTAssertEqual(snapshot.error, StubError().localizedDescription)
        XCTAssertFalse(snapshot.error?.isEmpty ?? true)
    }

    func testLoadAsyncMatchesLoad() async {
        let value = await QuotaEngine.loadAsync(.codex) { provider in
            .init(provider: provider, windows: [.init(label: "Weekly", usedPercent: 3, resetAt: nil)])
        }
        XCTAssertEqual(value.windows.map(\.label), ["Weekly"])

        let failure = await QuotaEngine.loadAsync(.codex) { _ in throw ProbeError.missing("codex") }
        XCTAssertFalse(failure.probeSucceeded)
        XCTAssertEqual(failure.error, ProbeError.missing("codex").localizedDescription)
    }

    // MARK: - refresh

    func testRefreshReturnsSnapshotsInAllCasesOrderRegardlessOfInputOrder() async {
        let snapshots = await QuotaEngine.refresh([.codex, .gemini, .claude]) { provider in
            .init(provider: provider, windows: [.init(label: "Session", usedPercent: 5, resetAt: nil)])
        }
        XCTAssertEqual(snapshots.map(\.provider), Provider.allCases)
    }

    func testRefreshOrdersAPartialProviderSetToo() async {
        let snapshots = await QuotaEngine.refresh([.codex, .gemini]) { .init(provider: $0) }
        XCTAssertEqual(snapshots.map(\.provider), [.gemini, .codex])
    }

    func testRefreshOfNoProvidersProbesNothing() async {
        let calls = Recorder<Provider>()
        let snapshots = await QuotaEngine.refresh([]) { provider in
            calls.append(provider)
            return .init(provider: provider)
        }
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testRefreshKeepsFailuresAlongsideSuccesses() async {
        let snapshots = await QuotaEngine.refresh(Provider.allCases) { provider in
            guard provider != .claude else { throw ProbeError.message("Claude did not respond") }
            return .init(provider: provider, windows: [.init(label: "Session", usedPercent: 12, resetAt: nil)])
        }
        XCTAssertEqual(snapshots.map(\.provider), [.gemini, .claude, .codex])
        XCTAssertEqual(snapshots.map(\.probeSucceeded), [true, false, true])
        XCTAssertEqual(snapshots[1].error, "Claude did not respond")
    }

    /// Every provider must be in flight at once; probing them one after another
    /// would make a refresh take the sum of three CLI timeouts. The stub loader
    /// blocks until all three have arrived, so a serial implementation cannot
    /// release the barrier and the assertion fails instead of the test hanging.
    func testRefreshProbesEveryProviderConcurrently() async {
        let barrier = Barrier(expected: Provider.allCases.count)
        let snapshots = await QuotaEngine.refresh(Provider.allCases) { provider in
            barrier.arriveAndWait(timeout: 5)
            return .init(provider: provider, windows: [.init(label: "Session", usedPercent: 1, resetAt: nil)])
        }
        XCTAssertTrue(barrier.everyoneArrived, "providers were probed serially")
        XCTAssertEqual(snapshots.count, Provider.allCases.count)
    }

    // MARK: - retainingLastGood

    func testRetainingLastGoodLeavesSuccessfulSnapshotsUntouched() {
        let previous: [QuotaSnapshot] = [
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 90, resetAt: nil)])
        ]
        let fresh: [QuotaSnapshot] = [
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 12, resetAt: nil)])
        ]
        let merged = QuotaEngine.retainingLastGood(fresh: fresh, previous: previous)
        XCTAssertEqual(merged.map(\.windows.first?.usedPercent), [12])
        XCTAssertTrue(merged[0].probeSucceeded)
        XCTAssertNil(merged[0].error)
    }

    func testRetainingLastGoodRestoresWindowsAndPrefixesTheError() {
        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        let previous: [QuotaSnapshot] = [
            .init(provider: .claude, windows: [.init(label: "Weekly", usedPercent: 64, resetAt: reset)], plan: "max")
        ]
        let fresh: [QuotaSnapshot] = [
            .init(provider: .claude, error: "Claude did not respond in time", probeSucceeded: false)
        ]
        let merged = QuotaEngine.retainingLastGood(fresh: fresh, previous: previous)
        XCTAssertEqual(merged[0].windows.map(\.usedPercent), [64])
        XCTAssertEqual(merged[0].windows.first?.resetAt, reset)
        XCTAssertEqual(merged[0].plan, "max")
        XCTAssertEqual(merged[0].error, "Refresh failed: Claude did not respond in time")
        XCTAssertFalse(merged[0].probeSucceeded)
    }

    /// A second consecutive failure must not stack prefixes into
    /// "Refresh failed: Refresh failed: …".
    func testRetainingLastGoodDoesNotStackPrefixesAcrossRepeatedFailures() {
        var carried: [QuotaSnapshot] = [
            .init(provider: .gemini, windows: [.init(label: "2.5 Pro", usedPercent: 30, resetAt: nil)])
        ]
        for attempt in 1...3 {
            let fresh: [QuotaSnapshot] = [
                .init(provider: .gemini, error: "attempt \(attempt) failed", probeSucceeded: false)
            ]
            carried = QuotaEngine.retainingLastGood(fresh: fresh, previous: carried)
        }
        XCTAssertEqual(carried[0].error, "Refresh failed: attempt 3 failed")
        XCTAssertEqual(carried[0].windows.map(\.usedPercent), [30])
    }

    func testRetainingLastGoodKeepsAnErrorlessFailureErrorless() {
        let previous: [QuotaSnapshot] = [
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 7, resetAt: nil)])
        ]
        let merged = QuotaEngine.retainingLastGood(
            fresh: [.init(provider: .codex, probeSucceeded: false)], previous: previous)
        XCTAssertNil(merged[0].error)
        XCTAssertEqual(merged[0].windows.map(\.usedPercent), [7])
    }

    func testRetainingLastGoodHasNothingToRestoreWithoutAPreviousValue() {
        let fresh: [QuotaSnapshot] = [.init(provider: .gemini, error: "boom", probeSucceeded: false)]
        XCTAssertEqual(QuotaEngine.retainingLastGood(fresh: fresh, previous: [])[0].error, "boom")

        // A previous snapshot that itself carried no windows is not worth keeping.
        let empty: [QuotaSnapshot] = [.init(provider: .gemini)]
        let merged = QuotaEngine.retainingLastGood(fresh: fresh, previous: empty)
        XCTAssertEqual(merged[0].error, "boom")
        XCTAssertTrue(merged[0].windows.isEmpty)
    }

    func testRetainingLastGoodOnlyRestoresTheMatchingProvider() {
        let previous: [QuotaSnapshot] = [
            .init(provider: .gemini, windows: [.init(label: "2.5 Pro", usedPercent: 55, resetAt: nil)])
        ]
        let fresh: [QuotaSnapshot] = [
            .init(provider: .gemini, error: "gemini down", probeSucceeded: false),
            .init(provider: .codex, error: "codex down", probeSucceeded: false)
        ]
        let merged = QuotaEngine.retainingLastGood(fresh: fresh, previous: previous)
        XCTAssertEqual(merged.map(\.windows.count), [1, 0])
        XCTAssertEqual(merged[1].error, "codex down", "no cached codex value means no prefix")
    }

    /// `previous` is built from a dictionary keyed by provider, so a duplicated
    /// provider collapses to the *last* entry — the freshest one a caller appended.
    func testRetainingLastGoodPrefersTheLastEntryForADuplicatedProvider() {
        let previous: [QuotaSnapshot] = [
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 10, resetAt: nil)]),
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 55, resetAt: nil)])
        ]
        let merged = QuotaEngine.retainingLastGood(
            fresh: [.init(provider: .codex, error: "codex down", probeSucceeded: false)], previous: previous)
        XCTAssertEqual(merged[0].windows.map(\.usedPercent), [55])
    }

    /// The same last-wins rule the other way round: when the newest duplicate has
    /// no windows there is nothing to restore, even though an older duplicate did.
    func testRetainingLastGoodDoesNotFallBackToAnOlderDuplicate() {
        let previous: [QuotaSnapshot] = [
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 55, resetAt: nil)]),
            .init(provider: .codex)
        ]
        let merged = QuotaEngine.retainingLastGood(
            fresh: [.init(provider: .codex, error: "codex down", probeSucceeded: false)], previous: previous)
        XCTAssertTrue(merged[0].windows.isEmpty)
        XCTAssertEqual(merged[0].error, "codex down")
    }

    /// The whole point of the seam: a failed refresh over the real entry points
    /// keeps showing yesterday's numbers instead of blanking the provider.
    func testRefreshAndRetentionSurviveATotalProbeOutage() async {
        let good = await QuotaEngine.refresh(Provider.allCases) { provider in
            .init(provider: provider, windows: [.init(label: "Session", usedPercent: 20, resetAt: nil)])
        }
        let outage = await QuotaEngine.refresh(Provider.allCases) { _ in throw ProbeError.timeout(partialOutput: "") }
        let merged = QuotaEngine.retainingLastGood(fresh: outage, previous: good)

        XCTAssertEqual(merged.map(\.provider), Provider.allCases)
        XCTAssertEqual(merged.map(\.windows.first?.usedPercent), [20, 20, 20])
        XCTAssertTrue(merged.allSatisfy { $0.probeSucceeded == false })
        XCTAssertTrue(merged.allSatisfy { $0.error?.hasPrefix("Refresh failed: ") == true })
    }

    /// A malformed Codex payload used to reach retention as a *successful* 0%
    /// snapshot, so the seam waved it through and the cache stored it over the
    /// real reading — or, when the payload held no windows at all, deleted the
    /// provider outright. Driven through the real parser, both shapes have to end
    /// as a failed refresh with yesterday's 42% still on screen and still cached.
    func testAMalformedCodexPayloadKeepsTheLastGoodQuota() {
        let previous: [QuotaSnapshot] = [
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 42, resetAt: nil)], plan: "plus")
        ]
        let malformed = [
            #"{"rateLimits":{"primary":{"resetsAt":2000000000,"windowDurationMins":300}}}"#: "unreadable",
            #"{"rateLimits":{"primary":{"usedPercent":"NaN"}}}"#: "unreadable",
            #"{"rateLimits":{"planType":"plus"}}"#: "no windows"
        ]
        for (json, shape) in malformed {
            let cache = SnapshotCache(store: MemoryStateStore())
            cache.update(with: previous)

            let fresh = QuotaEngine.load(.codex) { _ in
                guard let result = CodexProbe.jsonObject(json) else { throw ProbeError.message("bad fixture") }
                return try CodexProbe.parse(result)
            }
            XCTAssertFalse(fresh.probeSucceeded, "\(shape) is not a successful refresh")
            if shape == "unreadable" {
                XCTAssertEqual(fresh.error,
                               "Codex returned an unreadable quota response. Refresh after updating Codex.")
            }

            let merged = QuotaEngine.retainingLastGood(fresh: [fresh], previous: previous)
            XCTAssertEqual(merged[0].windows.map(\.usedPercent), [42], "\(shape) must keep the last good quota")
            XCTAssertFalse(merged[0].probeSucceeded)
            XCTAssertEqual(merged[0].error?.hasPrefix("Refresh failed: "), true)

            cache.update(with: merged)
            XCTAssertEqual(cache.snapshot(for: .codex)?.windows.first?.usedPercent, 42,
                           "\(shape) must not replace or delete the cached quota")
        }
    }

    // MARK: - SnapshotCache

    func testSnapshotCacheRoundTripsThroughAStateStore() throws {
        let store = MemoryStateStore()
        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        SnapshotCache(store: store).update(with: [
            .init(provider: .claude, windows: [.init(label: "Weekly", usedPercent: 64, resetAt: reset)], plan: "max"),
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 8, resetAt: nil)])
        ])

        let reloaded = SnapshotCache(store: store)
        let claude = try XCTUnwrap(reloaded.snapshot(for: .claude))
        XCTAssertEqual(claude.plan, "max")
        XCTAssertEqual(claude.windows.map(\.key), ["weekly"])
        XCTAssertEqual(claude.windows.first?.usedPercent, 64)
        XCTAssertEqual(claude.windows.first?.resetAt, reset)
        XCTAssertTrue(claude.probeSucceeded)
        XCTAssertNil(reloaded.snapshot(for: .gemini))
        // `all()` sorts by `Provider.allCases`, not by dictionary iteration order.
        XCTAssertEqual(reloaded.all().map(\.provider), [.claude, .codex])
    }

    func testSnapshotCacheRoundTripsThroughTheOnDiskStore() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-engine-test-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        SnapshotCache(store: JSONFileStateStore(url: url)).update(with: [
            .init(provider: .gemini, windows: [
                .init(key: "gemini-2.5-pro", label: "2.5 Pro", usedPercent: 31.5, resetAt: nil)
            ])
        ])
        let reloaded = SnapshotCache(store: JSONFileStateStore(url: url))
        XCTAssertEqual(reloaded.snapshot(for: .gemini)?.windows.map(\.key), ["gemini-2.5-pro"])
        XCTAssertEqual(reloaded.snapshot(for: .gemini)?.windows.first?.usedPercent, 31.5)
    }

    /// A provider that probes fine but reports no windows has genuinely lost its
    /// quota data, so the stale cached value must go rather than linger forever.
    func testSnapshotCacheDropsAProviderThatSucceedsWithNoWindows() {
        let store = MemoryStateStore()
        let cache = SnapshotCache(store: store)
        cache.update(with: [.init(provider: .codex, windows: [.init(label: "Session", usedPercent: 44, resetAt: nil)])])
        XCTAssertNotNil(cache.snapshot(for: .codex))

        cache.update(with: [.init(provider: .codex, windows: [])])
        XCTAssertNil(cache.snapshot(for: .codex))
        XCTAssertTrue(cache.all().isEmpty)
        XCTAssertNil(SnapshotCache(store: store).snapshot(for: .codex), "the drop has to be persisted too")
    }

    /// A failed probe is not evidence that the quota is gone, so the last good
    /// value stays cached — that is what makes a cold start show numbers.
    func testSnapshotCacheIgnoresFailedSnapshots() {
        let store = MemoryStateStore()
        let cache = SnapshotCache(store: store)
        cache.update(with: [.init(provider: .claude, windows: [.init(label: "Session", usedPercent: 70, resetAt: nil)])])
        cache.update(with: [.init(provider: .claude, error: "Refresh failed: timeout", probeSucceeded: false)])
        XCTAssertEqual(cache.snapshot(for: .claude)?.windows.first?.usedPercent, 70)
        XCTAssertNil(cache.snapshot(for: .claude)?.error)

        // Even a failure that still carries windows (a retained last-good value)
        // must not overwrite the cache entry.
        cache.update(with: [.init(provider: .claude,
                                  windows: [.init(label: "Session", usedPercent: 5, resetAt: nil)],
                                  error: "Refresh failed: timeout", probeSucceeded: false)])
        XCTAssertEqual(cache.snapshot(for: .claude)?.windows.first?.usedPercent, 70)
    }

    func testSnapshotCacheStripsErrorsFromSuccessfulSnapshots() {
        let cache = SnapshotCache(store: MemoryStateStore())
        cache.update(with: [.init(provider: .gemini,
                                  windows: [.init(label: "2.5 Flash", usedPercent: 12, resetAt: nil)],
                                  error: "a warning that must not outlive the refresh")])
        XCTAssertNil(cache.snapshot(for: .gemini)?.error)
        XCTAssertEqual(cache.snapshot(for: .gemini)?.windows.first?.usedPercent, 12)
    }

    func testSnapshotCacheStartsEmptyOnUnreadablePersistedData() {
        let store = MemoryStateStore()
        store.setData(Data("not json".utf8), forKey: SnapshotCache.key)
        XCTAssertTrue(SnapshotCache(store: store).all().isEmpty)
    }

    func testSnapshotCacheFeedsRefreshResultsStraightBack() async {
        let store = MemoryStateStore()
        let cache = SnapshotCache(store: store)
        let fresh = await QuotaEngine.refresh([.gemini, .codex]) { provider in
            .init(provider: provider, windows: [.init(label: "Session", usedPercent: 60, resetAt: nil)])
        }
        cache.update(with: fresh)
        XCTAssertEqual(SnapshotCache(store: store).all().map(\.provider), [.gemini, .codex])
    }

    // MARK: - QuotaBadge

    func testBadgeUsesSessionAndWeeklyInitialsForCodexAndClaude() {
        for provider in [Provider.codex, .claude] {
            XCTAssertEqual(QuotaBadge.preferred(for: provider, window: "Session"), "S")
            XCTAssertEqual(QuotaBadge.preferred(for: provider, window: "Weekly"), "W")
            XCTAssertEqual(QuotaBadge.preferred(for: provider, window: "Weekly Opus"), "W")
            XCTAssertEqual(QuotaBadge.preferred(for: provider, window: "WEEKLY"), "W", "matching is case-insensitive")
            XCTAssertEqual(QuotaBadge.preferred(for: provider, window: "Window 2"), "S",
                           "anything that is not a week reads as the session badge")
            XCTAssertEqual(QuotaBadge.preferred(for: provider, window: ""), "S")
        }
    }

    func testBadgeNamesGeminiModelFamilies() {
        XCTAssertEqual(QuotaBadge.preferred(for: .gemini, window: "2.5 Pro"), "P")
        XCTAssertEqual(QuotaBadge.preferred(for: .gemini, window: "2.5 Flash"), "F")
        XCTAssertEqual(QuotaBadge.preferred(for: .gemini, window: "2.5 Flash Lite"), "L")
        XCTAssertEqual(QuotaBadge.preferred(for: .gemini, window: "gemini-2.5-flash-lite"), "L",
                       "the hyphenated model id spells flash-lite without a space")
        XCTAssertEqual(QuotaBadge.preferred(for: .gemini, window: "Weekly"), "G",
                       "gemini never falls through to the week/session badges")
        XCTAssertEqual(QuotaBadge.preferred(for: .gemini, window: ""), "G")
    }

    /// Flash Lite is a distinct pool from Flash, so the more specific match has to
    /// win — otherwise both quotas would badge as "F" and become indistinguishable.
    func testBadgePrefersFlashLiteOverFlash() {
        for window in ["2.5 Flash Lite", "gemini-2.5-flash-lite", "FLASH-LITE", "flash lite preview"] {
            XCTAssertEqual(QuotaBadge.preferred(for: .gemini, window: window), "L", window)
        }
    }

    /// The selection overload matches on key *and* label together, so a saved
    /// selection still badges correctly when only one of the two is descriptive.
    func testBadgeFromSelectionCombinesKeyAndLabel() {
        let cases: [(QuotaSelection, String)] = [
            (.init(provider: .codex, windowLabel: "Session"), "S"),
            (.init(provider: .codex, windowLabel: "Weekly"), "W"),
            (.init(provider: .claude, windowLabel: "Weekly (all models)"), "W"),
            (.init(provider: .claude, windowKey: "session", windowLabel: "Session"), "S"),
            (.init(provider: .gemini, windowKey: "gemini-2.5-pro", windowLabel: "2.5 Pro"), "P"),
            (.init(provider: .gemini, windowKey: "gemini-2.5-flash", windowLabel: "2.5 Flash"), "F"),
            (.init(provider: .gemini, windowKey: "gemini-2.5-flash-lite", windowLabel: "2.5 Flash Lite"), "L"),
            (.init(provider: .gemini, windowKey: "gemini-3-pro-preview", windowLabel: "3 Pro Preview"), "P"),
            (.init(provider: .gemini, windowLabel: "Daily"), "G")
        ]
        for (selection, expected) in cases {
            XCTAssertEqual(QuotaBadge.preferred(for: selection), expected, selection.id)
        }
    }

    /// Badges are what the waybar/polybar text and the menu bar render, so every
    /// window a probe can produce must resolve to exactly one uppercase letter.
    func testBadgeIsAlwaysASingleUppercaseLetter() {
        let windows = ["Session", "Weekly", "Weekly Opus", "Window 2", "2.5 Pro", "2.5 Flash",
                       "2.5 Flash Lite", "gemini-2.5-pro", "", "  ", "unknown"]
        for provider in Provider.allCases {
            for window in windows {
                let badge = QuotaBadge.preferred(for: provider, window: window)
                XCTAssertEqual(badge.count, 1, "\(provider) / \(window) -> \(badge)")
                XCTAssertTrue(badge.allSatisfy { $0.isUppercase }, "\(provider) / \(window) -> \(badge)")
            }
        }
    }
}

// MARK: - Stubs

private struct StubError: Error {}

/// Thread-safe collector for values a stub closure was called with.
private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}

/// Releases only once `expected` callers are inside it at the same time, which is
/// exactly what "these ran concurrently" means. The deadline keeps a serial
/// implementation from hanging the suite: it fails the assertion instead.
private final class Barrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let expected: Int
    private var arrived = 0
    private var released = false
    private var timedOut = false

    init(expected: Int) { self.expected = expected }

    /// True only if every waiter was inside the barrier at the same time.
    ///
    /// Counting arrivals alone is not enough: three strictly sequential calls
    /// also reach `expected`, so a serial implementation would satisfy the
    /// barrier and this test would guard nothing. A waiter that leaves on its
    /// deadline never overlapped with the others, and that is recorded.
    var everyoneArrived: Bool {
        condition.lock()
        defer { condition.unlock() }
        return released && !timedOut
    }

    func arriveAndWait(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        arrived += 1
        if arrived >= expected {
            released = true
            condition.broadcast()
            return
        }
        while !released && Date() < deadline { _ = condition.wait(until: deadline) }
        if !released { timedOut = true }
    }
}

/// In-memory `StateStore` so cache tests assert on persistence without a file.
private final class MemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var numbers: [String: Int] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { blobs[key] } }
    func setData(_ value: Data?, forKey key: String) { lock.withLock { blobs[key] = value } }
    func integer(forKey key: String) -> Int? { lock.withLock { numbers[key] } }
    func setInteger(_ value: Int?, forKey key: String) { lock.withLock { numbers[key] = value } }
}
