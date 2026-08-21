import XCTest
import Foundation
@testable import QuotaCore

/// Forecast alerts. A projection is recalculated on every refresh, so the thing
/// that matters most here is that one forecast alerts once.
final class ProjectedAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")

    func testOnlyProjectionsBecomeAlerts() {
        let alerts = AlertEvaluator.projectedAlerts(for: [
            recommendation(kind: .projectedExhaustion, resetAt: now.addingTimeInterval(3_600)),
            recommendation(kind: .underUtilized, resetAt: nil),
            recommendation(kind: .chronicallyExhausted, resetAt: nil)
        ])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.level, .projected)
        XCTAssertEqual(alerts.first?.provider, .codex)
    }

    /// The identifier is keyed on the reset, not on the forecast, so recomputing
    /// the same forecast fifteen minutes later is the same alert.
    func testTheIdentifierIsKeyedOnTheCycleNotTheForecast() {
        let reset = now.addingTimeInterval(3_600)
        let first = AlertEvaluator.projectedAlerts(for: [recommendation(kind: .projectedExhaustion, resetAt: reset)])
        let again = AlertEvaluator.projectedAlerts(for: [recommendation(kind: .projectedExhaustion, resetAt: reset,
                                                                        evidence: ["at 71% and rising 9%/h"])])
        XCTAssertEqual(first.first?.identifier, again.first?.identifier)

        // The next cycle resets at a different instant and is a new alert.
        let next = AlertEvaluator.projectedAlerts(
            for: [recommendation(kind: .projectedExhaustion, resetAt: reset.addingTimeInterval(5 * 3_600))])
        XCTAssertNotEqual(first.first?.identifier, next.first?.identifier)
    }

    /// The cycle a forecast belongs to is a reset instant from a provider CLI,
    /// so it can be a number no `Int` can hold. Clamped to the boundary, the
    /// forecast is still identified rather than trapping on the way to a name.
    func testTheIdentifierClampsACycleResetNoIntCanHold() throws {
        let alert = try XCTUnwrap(AlertEvaluator.projectedAlerts(
            for: [recommendation(kind: .projectedExhaustion,
                                 resetAt: Date(timeIntervalSince1970: 1e19))]).first)
        XCTAssertEqual(alert.identifier, "quota.Codex.session.\(Int.max).projected")
    }

    /// Window keys, not labels: a provider renaming "Session" must not turn one
    /// cycle's forecast into two alerts.
    func testTheIdentifierUsesTheWindowKey() throws {
        let alert = try XCTUnwrap(AlertEvaluator.projectedAlerts(
            for: [recommendation(kind: .projectedExhaustion, resetAt: now)]).first)
        XCTAssertTrue(alert.identifier.contains("session"), alert.identifier)
        XCTAssertTrue(alert.identifier.hasSuffix(".projected"), alert.identifier)
    }

    func testTheBodyCarriesTheEvidence() throws {
        let alert = try XCTUnwrap(AlertEvaluator.projectedAlerts(
            for: [recommendation(kind: .projectedExhaustion, resetAt: now,
                                 evidence: ["at 71% and rising 9%/h", "projected to hit 100% in 3h"])]).first)
        XCTAssertEqual(alert.body, "at 71% and rising 9%/h, projected to hit 100% in 3h.")
        XCTAssertTrue(alert.title.contains("on course to run out early"))
    }

    func testAForecastIsDeliveredOnceAndRememberedAcrossEvaluators() async {
        let store = MemoryStateStore()
        let sink = CountingSink()
        let projections = [recommendation(kind: .projectedExhaustion, resetAt: now.addingTimeInterval(3_600))]

        let evaluator = AlertEvaluator(store: store)
        await evaluator.dispatch(projections: projections, through: sink, now: now)
        await evaluator.dispatch(projections: projections, through: sink, now: now.addingTimeInterval(900))
        await XCTAssertEqualAsync(await sink.count(), 1)

        // A fresh process reads the dedup map back and stays quiet.
        let reopened = AlertEvaluator(store: store)
        await reopened.dispatch(projections: projections, through: sink, now: now.addingTimeInterval(1_800))
        await XCTAssertEqualAsync(await sink.count(), 1)
    }

    /// A sink that could not deliver leaves the alert pending, exactly as the
    /// threshold path does, so a failed notification is retried.
    func testAFailedDeliveryIsRetriedOnTheNextRefresh() async {
        let sink = CountingSink()
        await sink.setFailing(true)
        let evaluator = AlertEvaluator(store: MemoryStateStore())
        let projections = [recommendation(kind: .projectedExhaustion, resetAt: now.addingTimeInterval(3_600))]

        await evaluator.dispatch(projections: projections, through: sink, now: now)
        await sink.setFailing(false)
        await evaluator.dispatch(projections: projections, through: sink, now: now.addingTimeInterval(900))
        await XCTAssertEqualAsync(await sink.count(), 2)
    }

    // MARK: - Fixtures

    private func recommendation(kind: Recommendation.Kind, resetAt: Date?,
                                evidence: [String] = ["at 71% and rising 9%/h"]) -> Recommendation {
        Recommendation(kind: kind, severity: .critical, series: session, windowLabel: "Session",
                       headline: "on course", evidence: evidence, cycleResetAt: resetAt)
    }

    private func XCTAssertEqualAsync(_ value: @autoclosure () async -> Int, _ expected: Int,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await value()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    // MARK: - Stubs

    private actor CountingSink: QuotaNotificationSink {
        private var delivered = 0
        private var failing = false

        func setFailing(_ value: Bool) { failing = value }
        func count() -> Int { delivered }

        func deliver(_ alert: QuotaAlert) async -> Bool {
            delivered += 1
            return !failing
        }
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
