import XCTest
import AppKit
@testable import QuotaBar
import QuotaCore

/// Everything platform-independent now lives in `QuotaCoreTests`. What remains
/// here is the AppKit menu-bar rendering that only exists on macOS.
final class QuotaBarTests: XCTestCase {
    @MainActor func testMenuBarProgressColourFollowsUrgencyThresholds() {
        let provider = NSColor.blue
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 79.9, provider: provider), provider)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 80, provider: provider), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 94.9, provider: provider), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 95, provider: provider), .systemRed)
    }

    /// The status item is a coloured symbol, a one-character badge and a bar, so
    /// this string is the whole of what VoiceOver can announce about it.
    @MainActor func testMenuBarAccessibilityLabelDescribesTheQuotaState() {
        XCTAssertEqual(MenuBarCompositeIcon.accessibilityDescription(for: []), "AI Quotas")

        let session = QuotaSelection(provider: .claude, windowLabel: "Session")
        let reading = MenuBarQuota(selection: session, usedPercent: 82, badge: "S")
        XCTAssertEqual(MenuBarCompositeIcon.accessibilityDescription(for: [reading]),
                       "Claude Code Session, 82% used")

        let pending = MenuBarQuota(selection: session, usedPercent: nil, badge: "S")
        XCTAssertTrue(MenuBarCompositeIcon.accessibilityDescription(for: [pending]).hasSuffix("waiting for data"),
                      "a quota with no reading yet must still say so")

        let weekly = MenuBarQuota(selection: QuotaSelection(provider: .codex, windowLabel: "Weekly"),
                                  usedPercent: 5, badge: "W")
        XCTAssertEqual(MenuBarCompositeIcon.accessibilityDescription(for: [reading, weekly]),
                       "Claude Code Session, 82% used; Codex Weekly, 5% used")
    }

    /// The point of the label: the same selection has to sound different at two
    /// different readings, or it is naming the app rather than reporting state.
    @MainActor func testMenuBarAccessibilityLabelChangesWithTheReading() {
        let session = QuotaSelection(provider: .claude, windowLabel: "Session")
        let low = MenuBarQuota(selection: session, usedPercent: 42, badge: "S")
        let high = MenuBarQuota(selection: session, usedPercent: 82, badge: "S")
        XCTAssertNotEqual(MenuBarCompositeIcon.accessibilityDescription(for: [low]),
                          MenuBarCompositeIcon.accessibilityDescription(for: [high]))
        XCTAssertNotEqual(MenuBarCompositeIcon.accessibilityDescription(for: [low]), "AI Quotas")
    }
}
