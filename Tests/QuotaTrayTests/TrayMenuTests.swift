import XCTest
import Foundation
@testable import QuotaTray
import QuotaCore

final class TrayMenuTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func items(_ snapshots: [QuotaSnapshot]) -> [TrayMenuItem] {
        TrayMenu.items(for: snapshots, now: now)
    }

    /// The trailing rows every menu ends with, whatever the providers did.
    private func assertEndsWithActions(_ items: [TrayMenuItem],
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(items.suffix(2).map(\.kind), [.action, .action], file: file, line: line)
        XCTAssertEqual(items.suffix(2).map(\.title), ["Refresh", "Quit"], file: file, line: line)
        XCTAssertEqual(items.suffix(2).map(\.actionID), ["refresh", "quit"], file: file, line: line)
        XCTAssertTrue(items.suffix(2).allSatisfy(\.enabled), file: file, line: line)
    }

    func testHealthyProviderListsEveryWindowThenTheActions() {
        let menu = items([
            .init(provider: .codex, windows: [
                .init(label: "Session", usedPercent: 42, resetAt: now.addingTimeInterval(3 * 3_600 + 12 * 60)),
                .init(label: "Weekly", usedPercent: 7.5, resetAt: now.addingTimeInterval(2 * 86_400 + 4 * 3_600))
            ])
        ])

        XCTAssertEqual(menu.map(\.kind), [.quota, .quota, .separator, .action, .action])
        XCTAssertEqual(menu[0].title, "Codex Session")
        XCTAssertEqual(menu[0].detail, "42% — resets in 3h 12m")
        XCTAssertEqual(menu[0].urgency, .normal)
        XCTAssertNil(menu[0].actionID)
        XCTAssertEqual(menu[1].title, "Codex Weekly")
        XCTAssertEqual(menu[1].detail, "7.5% — resets in 2d 4h")
        assertEndsWithActions(menu)
    }

    /// A window without a reset timestamp still shows its percentage; the reset
    /// half of the detail is display data that may simply be absent.
    func testWindowWithoutResetShowsOnlyThePercentage() {
        let menu = items([.init(provider: .gemini, windows: [
            .init(label: "2.5 Pro", usedPercent: 12, resetAt: nil)
        ])])

        XCTAssertEqual(menu[0].kind, .quota)
        XCTAssertEqual(menu[0].title, "Gemini CLI 2.5 Pro")
        XCTAssertEqual(menu[0].detail, "12%")
    }

    func testFailedProviderWithoutWindowsStaysVisibleWithItsReason() {
        let menu = items([.init(provider: .claude, windows: [], error: "claude is not installed",
                                probeSucceeded: false)])

        XCTAssertEqual(menu.map(\.kind), [.error, .separator, .action, .action])
        XCTAssertEqual(menu[0].title, "Claude Code")
        XCTAssertEqual(menu[0].detail, "claude is not installed")
        XCTAssertEqual(menu[0].urgency, .critical)
        XCTAssertNil(menu[0].actionID)
        assertEndsWithActions(menu)
    }

    /// No windows and no message is still a visible provider rather than a gap.
    func testProviderWithoutWindowsOrErrorFallsBackToTheSharedCopy() {
        let menu = items([.init(provider: .gemini)])

        XCTAssertEqual(menu.map(\.kind), [.error, .separator, .action, .action])
        XCTAssertEqual(menu[0].title, "Gemini CLI")
        XCTAssertEqual(menu[0].detail, "No quota data")
    }

    /// A refresh that failed must not blank out the numbers already on screen:
    /// the cached windows stay, and the failure adds exactly one row — not one
    /// per window.
    func testCachedWindowsSurviveAFailedRefreshAndAddOneErrorRow() {
        let menu = items([
            .init(provider: .codex,
                  windows: [.init(label: "Session", usedPercent: 88, resetAt: now.addingTimeInterval(45 * 60)),
                            .init(label: "Weekly", usedPercent: 30, resetAt: nil)],
                  error: "The CLI did not respond in time",
                  probeSucceeded: false,
                  updatedAt: now.addingTimeInterval(-3_600))
        ])

        XCTAssertEqual(menu.map(\.kind), [.quota, .quota, .error, .separator, .action, .action])
        XCTAssertEqual(menu[0].detail, "88% — resets in 45m")
        XCTAssertEqual(menu[0].urgency, .warning)
        XCTAssertEqual(menu[1].detail, "30%")
        XCTAssertEqual(menu[2].title, "Codex")
        XCTAssertEqual(menu[2].detail, "The CLI did not respond in time")
        XCTAssertEqual(menu[2].urgency, .critical)
    }

    /// Exact threshold boundaries: 80 is warning, 95 is critical, and the values
    /// just below each stay in the lower band.
    func testUrgencyUsesExactThresholds() {
        let samples: [(used: Double, urgency: QuotaUrgency)] = [
            (0, .normal), (79.9, .normal), (80, .warning), (94.9, .warning), (95, .critical), (100, .critical)
        ]
        let windows: [QuotaWindow] = samples.enumerated().map { index, sample in
            QuotaWindow(label: "W\(index)", usedPercent: sample.used, resetAt: nil)
        }
        let menu = items([.init(provider: .claude, windows: windows)])

        XCTAssertEqual(menu.prefix(samples.count).map(\.urgency), samples.map { $0.urgency })
        XCTAssertEqual(menu.prefix(samples.count).map(\.detail),
                       ["0%", "79.9%", "80%", "94.9%", "95%", "100%"])
    }

    /// Provider errors carry CLI output, which is untrusted: control sequences
    /// are stripped and the remaining lines collapse into one menu row.
    func testErrorTextIsNormalisedToASingleLine() {
        let raw = "\u{1B}[2K\u{1B}[?2004hgemini failed\n\n  run /auth to sign in\r\n"
        let menu = items([.init(provider: .gemini, error: raw, probeSucceeded: false)])

        XCTAssertEqual(menu[0].detail, "gemini failed · run /auth to sign in")
    }

    func testOverlongErrorTextIsTruncated() {
        let menu = items([.init(provider: .codex, error: String(repeating: "x", count: 500),
                                probeSucceeded: false)])

        XCTAssertEqual(menu[0].detail.count, TrayMenu.reasonLimit)
        XCTAssertTrue(menu[0].detail.hasSuffix("…"))
    }

    /// Control characters alone must not turn a failure into a blank row.
    func testErrorTextThatSanitisesToNothingStillReadsAsAFailure() {
        let menu = items([.init(provider: .claude, error: "\u{1B}[2K\u{7}", probeSucceeded: false)])

        XCTAssertEqual(menu[0].kind, .error)
        XCTAssertEqual(menu[0].detail, "Unavailable")
    }

    func testProvidersKeepTheirOrderAndGrouping() {
        let menu = items([
            .init(provider: .gemini, windows: [.init(label: "2.5 Pro", usedPercent: 5, resetAt: nil)]),
            .init(provider: .claude, windows: [], error: "not installed", probeSucceeded: false),
            .init(provider: .codex, windows: [.init(label: "Session", usedPercent: 60, resetAt: nil)])
        ])

        XCTAssertEqual(menu.map(\.kind), [.quota, .error, .quota, .separator, .action, .action])
        XCTAssertEqual(menu.prefix(3).map(\.title), ["Gemini CLI 2.5 Pro", "Claude Code", "Codex Session"])
    }

    /// Nothing installed: the actions are still there, and no separator dangles
    /// above them.
    func testEmptyInputStillOffersRefreshAndQuit() {
        let menu = items([])

        XCTAssertEqual(menu.map(\.kind), [.action, .action])
        assertEndsWithActions(menu)
    }
}
