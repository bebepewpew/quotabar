import XCTest
@testable import QuotaCore

/// The one tint parse both front-ends use. It is pinned here, in the core,
/// because it was previously written twice: the Linux tray required six ASCII
/// hex digits and fell back to a neutral grey, while the macOS menu bar used
/// `UInt64(hex, radix: 16) ?? 0` and fell back to pure black — an icon that is
/// invisible against a dark menu bar, and a wrong colour for a signed literal.
///
/// `Tests/QuotaTrayTests/TrayIconEdgeTests.swift` keeps asserting the same rule
/// through `TrayColor(hex:)`, and `Tests/QuotaBarTests` through `NSColor(hex:)`
/// and `Color(hex:)`, so a divergence fails on whichever platform introduces it.
final class TintRGBTests: XCTestCase {
    /// `secondaryLabelColor`, the documented fallback.
    private let grey = TintRGB(red: 0x8E, green: 0x8E, blue: 0x93)

    func testTheProviderTintsParseToTheirBytes() {
        XCTAssertEqual(TintRGB(hex: Provider.gemini.tint), TintRGB(red: 0x4F, green: 0x7D, blue: 0xF3))
        XCTAssertEqual(TintRGB(hex: Provider.claude.tint), TintRGB(red: 0xD9, green: 0x77, blue: 0x57))
        XCTAssertEqual(TintRGB(hex: Provider.codex.tint), TintRGB(red: 0x10, green: 0xA3, blue: 0x7F))
    }

    func testTheHashPrefixIsOptionalAndParsingIsCaseInsensitive() {
        XCTAssertEqual(TintRGB(hex: "#4F7DF3"), TintRGB(hex: "4F7DF3"))
        XCTAssertEqual(TintRGB(hex: "#ff453a"), TintRGB(red: 0xFF, green: 0x45, blue: 0x3A))
        XCTAssertEqual(TintRGB(hex: "Ff9F0a"), TintRGB(red: 0xFF, green: 0x9F, blue: 0x0A))
    }

    /// Black is a colour someone can ask for; only a failed parse is grey.
    func testAnExplicitBlackIsStillBlack() {
        XCTAssertEqual(TintRGB(hex: "000000"), TintRGB(red: 0, green: 0, blue: 0))
        XCTAssertEqual(TintRGB(hex: "#000000"), TintRGB(red: 0, green: 0, blue: 0))
        XCTAssertEqual(TintRGB(hex: "FFFFFF"), TintRGB(red: 0xFF, green: 0xFF, blue: 0xFF))
    }

    /// A tint that cannot be read must still draw a visible icon, so every
    /// malformed form resolves to the neutral grey — the empty string and the
    /// wrong lengths included.
    func testMalformedHexFallsBackToNeutralGrey() {
        let malformed = ["", "#", "4F7DF", "4F7DF33", "#4F7DF", "#4F7DF33", "1234", "1234567",
                         "GGGGGG", "#GGGGGG", "0x1234", "12 345", "  1234", "12-345",
                         "4F7DF3 ", " 4F7DF3", "ＦＦＦＦＦＦ", "F F 9 F 0 A", "4F7DF3\n"]
        for hex in malformed {
            XCTAssertEqual(TintRGB(hex: hex), grey, "\"\(hex)\" is not a colour")
        }
    }

    /// `UInt32(_:radix:)` accepts a leading sign, so a plain integer parse reads
    /// "+12345" as 0x012345 and "-12345" as a failure. Both are grey here.
    func testASignedLiteralIsNotAColour() {
        XCTAssertEqual(TintRGB(hex: "+12345"), grey)
        XCTAssertEqual(TintRGB(hex: "-12345"), grey)
        XCTAssertNotEqual(TintRGB(hex: "+12345"), TintRGB(red: 0x01, green: 0x23, blue: 0x45))
    }

    /// The fallback is what the menu bar and the tray both draw for nonsense, so
    /// its exact value is part of the contract: neutral grey, never black.
    func testTheFallbackIsNeutralGreyAndNeverBlack() {
        XCTAssertEqual(TintRGB.fallback, grey)
        XCTAssertEqual(TintRGB.fallback.red, 0x8E)
        XCTAssertEqual(TintRGB.fallback.green, 0x8E)
        XCTAssertEqual(TintRGB.fallback.blue, 0x93)
        XCTAssertNotEqual(TintRGB.fallback, TintRGB(red: 0, green: 0, blue: 0))
    }
}
