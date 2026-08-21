import XCTest
import Foundation
@testable import QuotaTray
import QuotaCore

/// Advice rows in the tray. A menu exists to show numbers, so the bar for
/// putting a sentence in it is high.
final class TrayMenuAdviceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = HistorySeriesID(provider: .codex, windowKey: "session")

    private var snapshot: QuotaSnapshot {
        QuotaSnapshot(provider: .codex,
                      windows: [QuotaWindow(label: "Session", usedPercent: 40, resetAt: nil)])
    }

    /// The existing call site keeps working and keeps its exact layout.
    func testTheMenuIsUnchangedWhenThereIsNoAdvice() {
        XCTAssertEqual(TrayMenu.items(for: [snapshot], now: now),
                       TrayMenu.items(for: [snapshot], recommendations: [], now: now))
    }

    func testARecommendationBecomesItsOwnRowWithEvidenceBeneath() throws {
        let items = TrayMenu.items(for: [snapshot], recommendations: [
            advice(.chronicallyExhausted, .critical, headline: "Codex Session runs out most cycles",
                   evidence: ["6 of 8 cycles reached 95% or more"])
        ], now: now)

        let row = try XCTUnwrap(items.first { $0.kind == .recommendation })
        XCTAssertEqual(row.title, "Codex Session runs out most cycles")
        XCTAssertEqual(row.detail, "6 of 8 cycles reached 95% or more")
        XCTAssertEqual(row.urgency, .critical)
    }

    /// "Not enough history yet" is the right answer for `advise` and noise in a
    /// menu, so informational advice never reaches the tray.
    func testInformationalAdviceIsLeftOut() {
        let items = TrayMenu.items(for: [snapshot], recommendations: [
            advice(.insufficientData, .info, headline: "Not enough history yet", evidence: ["1 of 4"])
        ], now: now)
        XCTAssertFalse(items.contains { $0.kind == .recommendation })
        // And no stray separator is left behind by the filtered row.
        XCTAssertEqual(items, TrayMenu.items(for: [snapshot], now: now))
    }

    /// A tray menu that scrolls has failed at being a tray menu.
    func testOnlyTheMostPressingAdviceIsShown() {
        let many = (0..<5).map { index in
            advice(.chronicallyExhausted, .critical, headline: "finding \(index)", evidence: ["because"])
        }
        let items = TrayMenu.items(for: [snapshot], recommendations: many, now: now)
        XCTAssertEqual(items.filter { $0.kind == .recommendation }.count, TrayMenu.maximumRecommendations)
    }

    func testSeverityMapsOntoTheUrgencyTheTrayAlreadyRenders() throws {
        let items = TrayMenu.items(for: [snapshot], recommendations: [
            advice(.burstyUsage, .warning, headline: "bursty", evidence: ["because"]),
            advice(.underUtilized, .opportunity, headline: "oversized", evidence: ["because"])
        ], now: now)
        let rows = items.filter { $0.kind == .recommendation }
        XCTAssertEqual(rows.map(\.urgency), [.warning, .normal])
    }

    /// Advice is separated from the quota rows, and Refresh and Quit still sit at
    /// the bottom behind their own rule.
    func testAdviceSitsBetweenTheQuotasAndTheActions() {
        let items = TrayMenu.items(for: [snapshot], recommendations: [
            advice(.chronicallyExhausted, .critical, headline: "runs out", evidence: ["because"])
        ], now: now)
        XCTAssertEqual(items.map(\.kind), [.quota, .separator, .recommendation, .separator, .action, .action])
        XCTAssertEqual(items.last?.actionID, TrayMenu.quitActionID)
    }

    /// Advice with no provider installed must not open with a stray rule.
    func testAdviceAloneDoesNotLeadWithASeparator() {
        let items = TrayMenu.items(for: [], recommendations: [
            advice(.idle, .opportunity, headline: "unused", evidence: ["because"])
        ], now: now)
        XCTAssertEqual(items.first?.kind, .recommendation)
    }

    /// A headline is built from provider text, so it is sanitised and clamped
    /// like every other untrusted string that reaches a menu row.
    func testALongOrControlLadenHeadlineIsSanitisedAndClamped() throws {
        let items = TrayMenu.items(for: [snapshot], recommendations: [
            advice(.chronicallyExhausted, .critical,
                   headline: "\u{1B}[31m" + String(repeating: "x", count: 400),
                   evidence: ["fine"])
        ], now: now)
        let row = try XCTUnwrap(items.first { $0.kind == .recommendation })
        XCTAssertFalse(row.title.contains("\u{1B}"))
        XCTAssertLessThanOrEqual(row.title.count, TrayMenu.reasonLimit)
        XCTAssertTrue(row.title.hasSuffix("…"))
    }

    func testAdviceWithNoEvidenceStillRendersARow() throws {
        let items = TrayMenu.items(for: [snapshot], recommendations: [
            advice(.idle, .opportunity, headline: "unused", evidence: [])
        ], now: now)
        let row = try XCTUnwrap(items.first { $0.kind == .recommendation })
        XCTAssertEqual(row.detail, "Unavailable")
    }

    // MARK: - Fixtures

    private func advice(_ kind: Recommendation.Kind, _ severity: Recommendation.Severity,
                        headline: String, evidence: [String]) -> Recommendation {
        Recommendation(kind: kind, severity: severity, series: session, windowLabel: "Session",
                       headline: headline, evidence: evidence)
    }
}
