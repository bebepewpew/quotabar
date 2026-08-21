import XCTest
import Foundation
@testable import QuotaCore

/// The README tells the reader which advice needs recorded history and which
/// does not, and quotes the gate that withholds the rest. Those are claims
/// about `Advisor`, so they are checked against `Advisor` rather than trusted:
/// the rules reachable with no cycles at all must be exactly the ones the README
/// names as needing none, and the numbers must be the constants in force.
final class AdvisorDocumentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The two rows the README names as needing no cycles, spelled as the README
    /// spells them. Each is also asserted to be a real headline below, so the
    /// prose cannot drift from the wording the advisor emits.
    private let cycleFreePhrases = ["on course to run out before it resets", "has headroom"]

    // MARK: - What the advisor does with nothing recorded

    /// A fresh install has readings but no completed cycles. Two rules still
    /// fire; every cycle-derived one is replaced by "not enough history yet".
    func testOnlyTheProjectionAndTheRebalanceSurviveWithNoCycles() {
        let kinds = Set(adviceWithoutCycles().map(\.kind))
        XCTAssertEqual(kinds.subtracting([.insufficientData]), [.projectedExhaustion, .rebalance])
        XCTAssertTrue(kinds.contains(.insufficientData), "the cycle-derived rules must still say so")
    }

    // MARK: - What the README says about it

    /// The gate paragraphs must name both rules that ignore it. A blanket
    /// "advice is withheld below four cycles" would tell a user no projection
    /// can arrive on day one, which is precisely what `--notify` delivers.
    func testTheReadmeNamesBothRulesThatNeedNoCycles() throws {
        let prose = try advisorProse()
        let advice = adviceWithoutCycles()
        for phrase in cycleFreePhrases {
            XCTAssertTrue(advice.contains { $0.headline.contains(phrase) },
                          "no headline reachable without cycles says \"\(phrase)\"")
            XCTAssertTrue(prose.contains(phrase),
                          "the README's advisor prose does not name \"\(phrase)\" as needing no cycles")
        }
    }

    /// A provider that stopped reporting is dropped before any rule runs, so a
    /// reader who sees nothing at all for it has somewhere to look it up.
    func testTheReadmeDocumentsTheStalenessCutOff() throws {
        XCTAssertTrue(try advisorProse().contains("\(Int(Advisor.staleAfterDays)) days"),
                      "the README does not mention the \(Int(Advisor.staleAfterDays))-day cut-off")
    }

    /// The quoted gate is the gate in force, and reads the same way as the
    /// evidence `insufficientData` prints.
    func testTheReadmeQuotesTheGateInForce() throws {
        XCTAssertEqual(Advisor.minimumCycles, 4, "the README spells this number out as \"four\"")
        let prose = try advisorProse()
        XCTAssertTrue(prose.contains("four complete cycles"), prose)
        XCTAssertTrue(prose.contains("\(Int(Advisor.minimumCoverage * 100))% of its length"), prose)
    }

    // MARK: - Fixtures

    /// One window about to run out and one with room, neither with a single
    /// completed cycle behind it.
    private func adviceWithoutCycles() -> [Recommendation] {
        let strained = HistorySeriesID(provider: .codex, windowKey: "session")
        let spare = HistorySeriesID(provider: .gemini, windowKey: "pro")
        let inputs = [
            AdvisorInput(series: strained, windowLabel: "Session", cycles: [],
                         latest: UsageSample(series: strained, at: now, usedPercent: 96,
                                             resetAt: now.addingTimeInterval(10 * 3_600)),
                         burnRatePerHour: 20),
            AdvisorInput(series: spare, windowLabel: "Pro", cycles: [],
                         latest: UsageSample(series: spare, at: now, usedPercent: 12, resetAt: nil),
                         burnRatePerHour: nil)
        ]
        return Advisor.recommendations(for: inputs, now: now)
    }

    /// The README's advisor section with the rules table removed and every run
    /// of whitespace collapsed, so a reflow cannot break a phrase in two.
    private func advisorProse() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuotaCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the checkout
        let readme = root.appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)

        let heading = "### Consumption history and the advisor"
        let start = try XCTUnwrap(text.range(of: heading), "\(readme.path) has no advisor section")
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        let lines = rest[..<end].split(separator: "\n", omittingEmptySubsequences: false)

        // The qualifying prose is what follows the table; the table itself is
        // matched separately by the headline assertions above.
        let lastRow = try XCTUnwrap(lines.lastIndex { $0.hasPrefix("|") },
                                    "the advisor section has no rules table")
        return lines[lines.index(after: lastRow)...]
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
