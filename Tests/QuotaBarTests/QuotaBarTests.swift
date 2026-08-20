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
}
