import XCTest
import Foundation
@testable import QuotaCore

/// Threshold evaluation, identifier composition, dedup persistence and sink
/// dispatch for `AlertEvaluator`. Everything runs against in-memory doubles, so
/// no notification is ever shown and no state file is touched.
final class AlertEvaluatorTests: XCTestCase {

    // MARK: - AlertLevel thresholds

    /// The exact boundaries the menu bar and the CLI both alert on. 80 and 95 are
    /// inclusive; anything under 80 must stay silent.
    func testAlertLevelBoundaries() {
        XCTAssertNil(AlertLevel(usedPercent: -1))
        XCTAssertNil(AlertLevel(usedPercent: 0))
        XCTAssertNil(AlertLevel(usedPercent: 79.99))
        XCTAssertEqual(AlertLevel(usedPercent: 80), .warning)
        XCTAssertEqual(AlertLevel(usedPercent: 80.01), .warning)
        XCTAssertEqual(AlertLevel(usedPercent: 94.99), .warning)
        XCTAssertEqual(AlertLevel(usedPercent: 95), .critical)
        XCTAssertEqual(AlertLevel(usedPercent: 100), .critical)
        XCTAssertEqual(AlertLevel(usedPercent: 150), .critical)
    }

    func testAlertLevelTitlesAndRawValues() {
        XCTAssertEqual(AlertLevel.allCases, [.warning, .critical])
        XCTAssertEqual(AlertLevel.warning.rawValue, "warning")
        XCTAssertEqual(AlertLevel.critical.rawValue, "critical")
        XCTAssertEqual(AlertLevel.warning.title, "running low")
        XCTAssertEqual(AlertLevel.critical.title, "almost exhausted")
    }

    // MARK: - alerts(for:now:)

    func testAlertsRaiseOneAlertPerCrossedWindowAndSkipTheRest() {
        let snapshots = [
            snapshot(.claude, [window("Session", 82), window("Weekly", 96), window("Spare", 79.99)]),
            snapshot(.codex, [window("Session", 12)])
        ]
        let alerts = AlertEvaluator.alerts(for: snapshots, now: alertsNow)
        XCTAssertEqual(alerts.map(\.level), [.warning, .critical])
        XCTAssertEqual(alerts.map(\.provider), [.claude, .claude])
        XCTAssertEqual(alerts.map(\.title), [
            "Claude Code quota is running low",
            "Claude Code quota is almost exhausted"
        ])
    }

    /// A stale cached reading carries the previous refresh's percentages; it must
    /// not raise a fresh alarm.
    func testAlertsIgnoreSnapshotsCarryingAnError() {
        let snapshots = [snapshot(.gemini, [window("Pro", 99)], error: "Refresh failed: stale")]
        XCTAssertTrue(AlertEvaluator.alerts(for: snapshots).isEmpty)
    }

    func testAlertsAreEmptyWithoutWindows() {
        XCTAssertTrue(AlertEvaluator.alerts(for: [snapshot(.codex, [])]).isEmpty)
        XCTAssertTrue(AlertEvaluator.alerts(for: []).isEmpty)
    }

    func testAlertBodyNamesTheResetWhenThereIsOneAndOmitsItOtherwise() {
        let alerts = AlertEvaluator.alerts(
            for: [snapshot(.claude, [window("Session", 82), window("Weekly", 96, resetAt: nil)])],
            now: alertsNow)
        XCTAssertEqual(alerts.map(\.body), [
            "Session limit is 82% used and resets in 1h.",
            "Weekly limit is 96% used."
        ])
    }

    // MARK: - identifier(provider:window:level:)

    func testIdentifierComposesProviderWindowKeyResetPeriodAndLevel() {
        XCTAssertEqual(
            AlertEvaluator.identifier(provider: .claude, window: window("Session", 82), level: .warning),
            "quota.Claude Code.session.2000000000.warning")
        XCTAssertEqual(
            AlertEvaluator.identifier(provider: .codex, window: window("Weekly", 96), level: .critical),
            "quota.Codex.weekly.2000000000.critical")
    }

    /// Gemini reports usage without a reset timestamp. The identifier still has to
    /// be well formed rather than collapsing to an empty period component.
    func testIdentifierUsesNoResetPlaceholderWhenTheWindowHasNoResetDate() {
        XCTAssertEqual(
            AlertEvaluator.identifier(provider: .gemini,
                                      window: window("Pro", 96, resetAt: nil),
                                      level: .critical),
            "quota.Gemini CLI.pro.no-reset.critical")
    }

    func testANewResetPeriodIsANewAlertAtTheSameLevel() async {
        let evaluator = AlertEvaluator(store: RecordingStateStore())
        let period = [snapshot(.claude, [window("Session", 82)])]
        let first = await evaluator.pending(for: period)
        XCTAssertEqual(first.count, 1)
        for alert in first { await evaluator.markDelivered(alert) }
        let repeated = await evaluator.pending(for: period)
        XCTAssertTrue(repeated.isEmpty)

        let nextPeriod = [snapshot(.claude, [window("Session", 82, resetAt: reset.addingTimeInterval(3_600))])]
        let third = await evaluator.pending(for: nextPeriod)
        XCTAssertEqual(third.count, 1)
    }

    /// The regression #30 was filed for. Gemini genuinely ships `key != label`, so
    /// a vendor rewording a label must not make a window the user was already
    /// alerted about look brand new. The key is what identity is keyed on.
    func testARewordedLabelWithTheSameKeyDoesNotReAlert() async {
        let evaluator = AlertEvaluator(store: RecordingStateStore())
        let original = QuotaWindow(key: "gemini-2.5-pro", label: "Pro",
                                   usedPercent: 96, resetAt: reset)
        let first = await evaluator.pending(for: [snapshot(.gemini, [original])])
        XCTAssertEqual(first.count, 1)
        for alert in first { await evaluator.markDelivered(alert) }

        let reworded = QuotaWindow(key: "gemini-2.5-pro", label: "Gemini 2.5 Pro (daily)",
                                   usedPercent: 96, resetAt: reset)
        let afterRewording = await evaluator.pending(for: [snapshot(.gemini, [reworded])])
        XCTAssertTrue(afterRewording.isEmpty,
                      "a label is display data; rewording it must not re-alert a window already delivered")
    }

    /// The other half of keying on identity: two windows that happen to share a
    /// label but not a key each get their own dedup entry, so neither goes silent.
    func testWindowsSharingALabelButNotAKeyAlertIndependently() async {
        let evaluator = AlertEvaluator(store: RecordingStateStore())
        let windows = [
            QuotaWindow(key: "gemini-2.5-pro", label: "Pro", usedPercent: 96, resetAt: reset),
            QuotaWindow(key: "gemini-2.5-flash", label: "Pro", usedPercent: 96, resetAt: reset)
        ]
        let pending = await evaluator.pending(for: [snapshot(.gemini, windows)])
        XCTAssertEqual(pending.map(\.identifier), [
            "quota.Gemini CLI.gemini-2.5-pro.2000000000.critical",
            "quota.Gemini CLI.gemini-2.5-flash.2000000000.critical"
        ])
    }

    // MARK: - Dedup persistence

    func testMarkDeliveredPersistsAndIsReadBackByAFreshEvaluator() async throws {
        let store = RecordingStateStore()
        let snapshots = [snapshot(.codex, [window("Session", 99)])]
        let evaluator = AlertEvaluator(store: store)
        let pending = await evaluator.pending(for: snapshots)
        let alert = try XCTUnwrap(pending.first)

        await evaluator.markDelivered(alert)
        XCTAssertEqual(store.writes, 1, "markDelivered has to persist through the store, not only in memory")

        let payload = try XCTUnwrap(store.data(forKey: AlertEvaluator.deliveredKey))
        let decoded = try JSONDecoder().decode([String: Date].self, from: payload)
        XCTAssertEqual(Array(decoded.keys), [alert.identifier])

        let reloaded = AlertEvaluator(store: store)
        let afterReload = await reloaded.pending(for: snapshots)
        XCTAssertTrue(afterReload.isEmpty)
        let known = await reloaded.hasDelivered(alert.identifier)
        XCTAssertTrue(known)
        let unknown = await reloaded.hasDelivered("quota.Codex.Session.1.warning")
        XCTAssertFalse(unknown)
    }

    /// A truncated or hand-edited dedup blob must not wedge alerting shut.
    func testUnreadableDeliveredPayloadStartsFromAnEmptyMap() async {
        let store = RecordingStateStore(seeded: [AlertEvaluator.deliveredKey: Data("{not json".utf8)])
        let evaluator = AlertEvaluator(store: store)
        let pending = await evaluator.pending(for: [snapshot(.gemini, [window("Pro", 88)])])
        XCTAssertEqual(pending.count, 1)
    }

    /// Past 500 remembered deliveries the map is cut back to the 300 most recent,
    /// so a long-lived watcher does not grow an unbounded state file.
    func testDeliveredMapIsTrimmedToTheThreeHundredMostRecentOncePastFiveHundred() async throws {
        var seed: [String: Date] = [:]
        for index in 0..<500 {
            seed["quota.seed.\(index)"] = Date(timeIntervalSince1970: 1_000_000 + Double(index))
        }
        let store = RecordingStateStore(
            seeded: [AlertEvaluator.deliveredKey: try JSONEncoder().encode(seed)])
        let evaluator = AlertEvaluator(store: store)

        // Re-marking a known identifier keeps the map at 500, which is not over
        // the cap, so nothing is dropped yet.
        await evaluator.markDelivered(alert(identifier: "quota.seed.0"),
                                      at: Date(timeIntervalSince1970: 1_000_000))
        let untrimmed = try persistedIdentifiers(in: store)
        XCTAssertEqual(untrimmed.count, 500)

        // The 501st entry crosses it.
        await evaluator.markDelivered(alert(identifier: "quota.fresh"),
                                      at: Date(timeIntervalSince1970: 3_000_000))
        let kept = try persistedIdentifiers(in: store)
        XCTAssertEqual(kept.count, 300)
        XCTAssertTrue(kept.contains("quota.fresh"), "the delivery that triggered the trim survives it")
        XCTAssertTrue(kept.contains("quota.seed.499"))
        XCTAssertTrue(kept.contains("quota.seed.201"), "299 seeded entries join the fresh one")
        XCTAssertFalse(kept.contains("quota.seed.200"), "the oldest entries are the ones dropped")
        XCTAssertFalse(kept.contains("quota.seed.0"))

        // The in-memory map agrees with what was written.
        let remembersFresh = await evaluator.hasDelivered("quota.fresh")
        XCTAssertTrue(remembersFresh)
        let remembersOldest = await evaluator.hasDelivered("quota.seed.0")
        XCTAssertFalse(remembersOldest)
    }

    // MARK: - dispatch(_:through:now:)

    func testDispatchDeliversEveryPendingAlertOnceAndRecordsIt() async {
        let evaluator = AlertEvaluator(store: RecordingStateStore())
        let sink = StubSink()
        let snapshots = [snapshot(.claude, [window("Session", 82), window("Weekly", 96), window("Spare", 12)])]

        await evaluator.dispatch(snapshots, through: sink)

        let attempted = await sink.attemptedIdentifiers
        XCTAssertEqual(attempted, [
            "quota.Claude Code.session.2000000000.warning",
            "quota.Claude Code.weekly.2000000000.critical"
        ])
        for identifier in attempted {
            let recorded = await evaluator.hasDelivered(identifier)
            XCTAssertTrue(recorded, "\(identifier) reached the user and must be recorded")
        }

        await evaluator.dispatch(snapshots, through: sink, now: alertsNow)
        let afterSecondPass = await sink.attemptedIdentifiers
        XCTAssertEqual(afterSecondPass, attempted, "a recorded alert is never offered to the sink again")
    }

    /// The sink reports whether the user actually saw the alert. A failure has to
    /// leave the alert pending so the next refresh retries it.
    func testDispatchLeavesAnAlertTheSinkFailedPendingForTheNextRefresh() async {
        let evaluator = AlertEvaluator(store: RecordingStateStore())
        let warningWindow = window("Session", 82)
        let criticalWindow = window("Weekly", 96)
        let warningID = AlertEvaluator.identifier(provider: .claude, window: warningWindow, level: .warning)
        let criticalID = AlertEvaluator.identifier(provider: .claude, window: criticalWindow, level: .critical)
        let snapshots = [snapshot(.claude, [warningWindow, criticalWindow])]
        let sink = StubSink(failing: [criticalID])

        await evaluator.dispatch(snapshots, through: sink)
        let deliveredWarning = await evaluator.hasDelivered(warningID)
        XCTAssertTrue(deliveredWarning)
        let deliveredCritical = await evaluator.hasDelivered(criticalID)
        XCTAssertFalse(deliveredCritical, "an alert the sink could not show must not count as delivered")
        let stillPending = await evaluator.pending(for: snapshots)
        XCTAssertEqual(stillPending.map(\.identifier), [criticalID])

        await sink.recover()
        await evaluator.dispatch(snapshots, through: sink)
        let deliveredOnRetry = await evaluator.hasDelivered(criticalID)
        XCTAssertTrue(deliveredOnRetry)
        let attempted = await sink.attemptedIdentifiers
        XCTAssertEqual(attempted, [warningID, criticalID, criticalID], "only the failed alert is retried")
        let settled = await evaluator.pending(for: snapshots)
        XCTAssertTrue(settled.isEmpty)
    }

    func testDispatchWithNothingOverThresholdNeverTouchesTheSink() async {
        let evaluator = AlertEvaluator(store: RecordingStateStore())
        let sink = StubSink()
        await evaluator.dispatch([snapshot(.gemini, [window("Pro", 40)])], through: sink)
        let attempted = await sink.attemptedIdentifiers
        XCTAssertTrue(attempted.isEmpty)
    }

    // MARK: - Fixtures

    private let reset = Date(timeIntervalSince1970: 2_000_000_000)
    /// One hour before `reset`, so the reset text is a stable "in 1h".
    private var alertsNow: Date { reset.addingTimeInterval(-3_600) }

    private func window(_ label: String, _ usedPercent: Double, resetAt: Date?) -> QuotaWindow {
        QuotaWindow(label: label, usedPercent: usedPercent, resetAt: resetAt)
    }

    private func window(_ label: String, _ usedPercent: Double) -> QuotaWindow {
        window(label, usedPercent, resetAt: reset)
    }

    private func snapshot(_ provider: Provider, _ windows: [QuotaWindow], error: String? = nil) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, windows: windows, error: error, probeSucceeded: error == nil)
    }

    private func alert(identifier: String) -> QuotaAlert {
        QuotaAlert(identifier: identifier, provider: .codex, level: .warning,
                   title: "Codex quota is running low", body: "Session limit is 82% used.")
    }

    private func persistedIdentifiers(in store: RecordingStateStore) throws -> Set<String> {
        let payload = try XCTUnwrap(store.data(forKey: AlertEvaluator.deliveredKey))
        return Set(try JSONDecoder().decode([String: Date].self, from: payload).keys)
    }
}

/// In-memory `StateStore` that also counts writes, so persistence is asserted on
/// rather than inferred.
private final class RecordingStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data]
    private var numbers: [String: Int] = [:]
    private var writeCount = 0

    init(seeded: [String: Data] = [:]) { blobs = seeded }

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

/// Notification sink double. Identifiers in `failing` report that the alert never
/// reached the user, which is what makes the retry path observable.
private actor StubSink: QuotaNotificationSink {
    private var attempts: [QuotaAlert] = []
    private var failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    var attemptedIdentifiers: [String] { attempts.map(\.identifier) }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        attempts.append(alert)
        return !failing.contains(alert.identifier)
    }

    /// Whatever kept the sink from showing alerts has gone away.
    func recover() { failing = [] }
}
