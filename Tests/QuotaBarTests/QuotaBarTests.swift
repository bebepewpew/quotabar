import XCTest
import AppKit
import SwiftUI
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

    // MARK: - Tint parsing

    /// Both helpers used to be `UInt64(hex, radix: 16) ?? 0`, which drew an
    /// unreadable tint in pure black — invisible against a dark menu bar. They
    /// now read `TintRGB`, so nonsense is the same neutral grey the Linux tray
    /// falls back to.
    @MainActor func testAnUnparsableTintIsNeutralGreyRatherThanBlack() {
        for hex in ["", "GGGGGG", "+12345", "-12345", "4F7DF", "4F7DF33", "0x4F7D", "４F7DF3"] {
            assertColour(NSColor(hex: hex), is: .fallback, "NSColor(hex: \"\(hex)\")")
            assertColour(NSColor(Color(hex: hex)), is: .fallback, "Color(hex: \"\(hex)\")")
        }
        XCTAssertNotEqual(TintRGB.fallback, TintRGB(red: 0, green: 0, blue: 0))
    }

    /// The tints the app actually passes are unaffected, and so is an explicit
    /// black: only a failed parse is grey.
    @MainActor func testAParsableTintKeepsItsColour() {
        for provider in Provider.allCases {
            let expected = TintRGB(hex: provider.tint)
            assertColour(NSColor(hex: provider.tint), is: expected, "NSColor(hex: \(provider.tint))")
            assertColour(NSColor(Color(hex: provider.tint)), is: expected, "Color(hex: \(provider.tint))")
        }
        assertColour(NSColor(hex: "4F7DF3"), is: TintRGB(red: 0x4F, green: 0x7D, blue: 0xF3), "4F7DF3")
        assertColour(NSColor(hex: "000000"), is: TintRGB(red: 0, green: 0, blue: 0), "000000")
        // The leading hash stays optional here for the same reason it is in
        // `TrayColor(hex:)`: one parse, one answer, on both platforms.
        assertColour(NSColor(hex: "#4f7df3"), is: TintRGB(red: 0x4F, green: 0x7D, blue: 0xF3), "#4f7df3")
    }

    @MainActor private func assertColour(_ colour: NSColor, is expected: TintRGB, _ label: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        guard let srgb = colour.usingColorSpace(.sRGB) else {
            return XCTFail("\(label) has no sRGB representation", file: file, line: line)
        }
        XCTAssertEqual(srgb.redComponent, CGFloat(expected.red) / 255, accuracy: 0.002, "\(label) red", file: file, line: line)
        XCTAssertEqual(srgb.greenComponent, CGFloat(expected.green) / 255, accuracy: 0.002, "\(label) green", file: file, line: line)
        XCTAssertEqual(srgb.blueComponent, CGFloat(expected.blue) / 255, accuracy: 0.002, "\(label) blue", file: file, line: line)
        // A transparent icon fails the same way a black one does.
        XCTAssertEqual(srgb.alphaComponent, 1, accuracy: 0.002, "\(label) alpha", file: file, line: line)
    }
}
