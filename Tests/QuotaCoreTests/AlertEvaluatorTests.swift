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
        // `.projected` is raised by the advisor, never by a threshold on the
        // current reading, so no percentage may produce it.
        XCTAssertFalse((0...200).contains { AlertLevel(usedPercent: Double($0)) == .projected })
    }

    func testAlertLevelTitlesAndRawValues() {
        XCTAssertEqual(AlertLevel.allCases, [.warning, .critical, .projected])
        XCTAssertEqual(AlertLevel.warning.rawValue, "warning")
        XCTAssertEqual(AlertLevel.critical.rawValue, "critical")
        XCTAssertEqual(AlertLevel.projected.rawValue, "projected")
        XCTAssertEqual(AlertLevel.warning.title, "running low")
        XCTAssertEqual(AlertLevel.critical.title, "almost exhausted")
        XCTAssertEqual(AlertLevel.projected.title, "on course to run out early")
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

    /// The period component is the reset floored to a whole hour, not the second
    /// it names: `reset` is 2 000 s into the period beginning at 1 999 998 000.
    func testIdentifierComposesProviderWindowKeyResetPeriodAndLevel() {
        XCTAssertEqual(
            AlertEvaluator.identifier(provider: .claude, window: window("Session", 82), level: .warning),
            "quota.Claude Code.session.1999998000.warning")
        XCTAssertEqual(
            AlertEvaluator.identifier(provider: .codex, window: window("Weekly", 96), level: .critical),
            "quota.Codex.weekly.1999998000.critical")
    }

    /// The identifier half of #61. `GeminiTerminalProbe.parseReset` returns
    /// `now +` an interval it reparses out of relative text on every probe, so one
    /// cycle is never reported at the same second twice. The period identifies the
    /// cycle; anything more than an hour away is a different one.
    func testIdentifierNamesTheResetPeriodRatherThanTheExactSecond() {
        let base = AlertEvaluator.identifier(provider: .gemini,
                                             window: window("Pro", 82), level: .warning)
        for drift in [-2_000, -1_999, 1, 60, 900, 1_599] as [TimeInterval] {
            XCTAssertEqual(
                AlertEvaluator.identifier(provider: .gemini,
                                          window: window("Pro", 82, resetAt: reset.addingTimeInterval(drift)),
                                          level: .warning),
                base, "a reset \(drift)s away is the same cycle and must keep one identifier")
        }
        for move in [-7_200, 3_601, 18_000, 86_400] as [TimeInterval] {
            XCTAssertNotEqual(
                AlertEvaluator.identifier(provider: .gemini,
                                          window: window("Pro", 82, resetAt: reset.addingTimeInterval(move)),
                                          level: .warning),
                base, "a reset \(move)s away is past the one-hour floor and is a new cycle")
        }
    }

    /// The reset comes from untrusted output: `GeminiTerminalProbe.parseReset`
    /// turns "resets in 99999999999999999999d" into a date no `Int` can hold.
    /// Flooring it into a period must clamp rather than trap.
    func testAnAbsurdResetStillComposesAWellFormedIdentifier() {
        for seconds in [1e30, -1e30, .greatestFiniteMagnitude, .infinity, -.infinity, Double.nan] {
            let absurd = window("Pro", 96, resetAt: Date(timeIntervalSince1970: seconds))
            let identifier = AlertEvaluator.identifier(provider: .gemini, window: absurd, level: .critical)
            XCTAssertTrue(identifier.hasPrefix("quota.Gemini CLI.pro."), identifier)
            XCTAssertTrue(identifier.hasSuffix(".critical"), identifier)
        }
    }

    /// Not every provider reports a reset. The identifier still has to be well
    /// formed rather than collapsing to an empty period component.
    func testIdentifierUsesNoResetPlaceholderWhenTheWindowHasNoResetDate() {
        XCTAssertEqual(
            AlertEvaluator.identifier(provider: .gemini,
                                      window: window("Pro", 96, resetAt: nil),
                                      level: .critical),
            "quota.Gemini CLI.pro.no-reset.critical")
    }

    /// A genuine reset alerts again at the same level. Five hours is the shortest
    /// window any supported provider publishes, so that — not an hour of drift on
    /// one reset — is what a new period means.
    func testANewResetPeriodIsANewAlertAtTheSameLevel() async {
        let evaluator = AlertEvaluator(store: RecordingStateStore())
        let period = [snapshot(.claude, [window("Session", 82)])]
        let first = await evaluator.pending(for: period)
        XCTAssertEqual(first.count, 1)
        for alert in first { await evaluator.markDelivered(alert) }
        let repeated = await evaluator.pending(for: period)
        XCTAssertTrue(repeated.isEmpty)

        let nextPeriod = [snapshot(.claude, [window("Session", 82, resetAt: reset.addingTimeInterval(5 * 3_600))])]
        let third = await evaluator.pending(for: nextPeriod)
        XCTAssertEqual(third.count, 1)
    }

    /// The regression #61 was filed for. Gemini's probe rebuilds `resetAt` as
    /// `now +` the relative interval printed in `Resets: 10:01 AM (16h)`, so the
    /// reset each refresh reports slides forward by the refresh interval. Four
    /// refreshes of one cycle at 82% are one notification, not four.
    func testADriftingResetIsOneAlertForTheCycleRatherThanOnePerRefresh() async {
        let store = RecordingStateStore()
        let evaluator = AlertEvaluator(store: store)
        let sink = StubSink()
        // Chosen so the drift crosses a period boundary — flooring the reset alone
        // would still raise a second alert partway through.
        let firstProbe = Date(timeIntervalSince1970: 2_000_000_600)
        for refresh in 0..<4 {
            let probedAt = firstProbe.addingTimeInterval(Double(refresh) * 900)
            let drifting = QuotaWindow(key: "gemini-2.5-pro", label: "Pro", usedPercent: 82,
                                       resetAt: probedAt.addingTimeInterval(16 * 3_600))
            await evaluator.dispatch([snapshot(.gemini, [drifting])], through: sink, now: probedAt)
        }
        let attempted = await sink.attemptedIdentifiers
        XCTAssertEqual(attempted.count, 1, "one cycle over the threshold is one notification")
        XCTAssertEqual(store.writes, 1, "a drifting reset must not churn a dedup entry per refresh")

        // The cycle after this one resets sixteen hours later, which is a new alert.
        let afterReset = firstProbe.addingTimeInterval(16 * 3_600)
        let nextCycle = QuotaWindow(key: "gemini-2.5-pro", label: "Pro", usedPercent: 82,
                                    resetAt: afterReset.addingTimeInterval(16 * 3_600))
        await evaluator.dispatch([snapshot(.gemini, [nextCycle])], through: sink, now: afterReset)
        let afterNextCycle = await sink.attemptedIdentifiers
        XCTAssertEqual(afterNextCycle.count, 2, "the next cycle alerts once of its own")
        XCTAssertNotEqual(afterNextCycle.first, afterNextCycle.last)
    }

    /// A window reported without a reset uses the placeholder period, and that path
    /// keeps alerting exactly once per level however often it is refreshed.
    func testAWindowWithoutAResetAlertsOncePerLevel() async {
        let evaluator = AlertEvaluator(store: RecordingStateStore())
        let sink = StubSink()
        let windows = [window("Session", 82, resetAt: nil), window("Weekly", 96, resetAt: nil)]
        for refresh in 0..<4 {
            await evaluator.dispatch([snapshot(.claude, windows)], through: sink,
                                     now: alertsNow.addingTimeInterval(Double(refresh) * 900))
        }
        let attempted = await sink.attemptedIdentifiers
        XCTAssertEqual(attempted, [
            "quota.Claude Code.session.no-reset.warning",
            "quota.Claude Code.weekly.no-reset.critical"
        ])
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
            "quota.Gemini CLI.gemini-2.5-pro.1999998000.critical",
            "quota.Gemini CLI.gemini-2.5-flash.1999998000.critical"
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
            "quota.Claude Code.session.1999998000.warning",
            "quota.Claude Code.weekly.1999998000.critical"
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
