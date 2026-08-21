import XCTest
@testable import QuotaTray
import QuotaCore

/// The degenerate inputs `TrayIconTests` does not reach: a tint string that is
/// not a colour, an icon too small for the bars it is asked to stack, and a
/// bitmap whose pixel buffer is shorter than its declared size claims.
///
/// None of these come up while the app is behaving; all of them end in either a
/// trap or an invisible tray item if they are handled wrong, which is why they
/// are pinned rather than left to the happy path.
final class TrayIconEdgeTests: XCTestCase {
    /// The fallback tint: `secondaryLabelColor`, fully opaque.
    private let grey = TrayColor(red: 0x8E, green: 0x8E, blue: 0x93)

    private func quota(_ provider: Provider, _ used: Double?) -> MenuBarQuota {
        MenuBarQuota(selection: QuotaSelection(provider: provider, windowLabel: "5-hour"),
                     usedPercent: used, badge: used.map { "\(Int($0))" } ?? "—")
    }

    // MARK: - TrayColor

    func testTheHashPrefixIsOptionalAndParsingIsCaseInsensitive() {
        XCTAssertEqual(TrayColor(hex: "#4F7DF3"), TrayColor(hex: "4F7DF3"))
        XCTAssertEqual(TrayColor(hex: "#FF9F0A"), TrayIcon.warningTint)
        XCTAssertEqual(TrayColor(hex: "#ff453a"), TrayIcon.criticalTint)
        XCTAssertEqual(TrayColor(hex: "#000000"), TrayColor(red: 0, green: 0, blue: 0))
    }

    /// A tint that cannot be read must still be a visible icon, so every
    /// malformed form resolves to the neutral grey — including the ones that a
    /// plain integer parse would otherwise accept, such as a signed literal.
    func testMalformedHexFallsBackToAnOpaqueNeutralGrey() {
        let malformed = ["", "#", "1234", "12345", "1234567", "#12345", "#1234567",
                         "GGGGGG", "#GGGGGG", "0x1234", "12 345", "  1234", "12-345",
                         "+12345", "-12345", "ＦＦＦＦＦＦ", "F F 9 F 0 A"]
        for hex in malformed {
            XCTAssertEqual(TrayColor(hex: hex), grey, "\"\(hex)\" is not a colour")
        }
        XCTAssertEqual(grey.alpha, 255, "the fallback must never be transparent")
    }

    func testBytesAreRedGreenBlueAlphaInThatOrder() {
        XCTAssertEqual(TrayColor(red: 1, green: 2, blue: 3, alpha: 4).bytes, [1, 2, 3, 4])
        XCTAssertEqual(TrayIcon.trackTint.bytes, [0x8E, 0x8E, 0x93, 56])
        XCTAssertEqual(TrayColor(hex: "4F7DF3").bytes, [0x4F, 0x7D, 0xF3, 255])
    }

    // MARK: - Degenerate sizes

    /// One pixel cannot hold three stacked bars. The rows that fall outside the
    /// icon are dropped rather than drawn past the buffer, and the topmost quota
    /// is the one that survives.
    func testAnIconTooSmallForItsBarsKeepsOnlyTheRowsThatFit() {
        for size in [0, 1] {
            let bitmap = TrayIcon.rasterise([quota(.gemini, 100), quota(.claude, 50), quota(.codex, 10)], size: size)
            XCTAssertEqual(bitmap.width, 1, "size \(size)")
            XCTAssertEqual(bitmap.height, 1, "size \(size)")
            XCTAssertEqual(bitmap.pixels, TrayIcon.criticalTint.bytes, "size \(size)")
        }
    }

    /// Even at one pixel the tray item stays visible: no reading, and no
    /// selection at all, both draw the track.
    func testASinglePixelIconWithNoReadingIsStillTheTrack() {
        XCTAssertEqual(TrayIcon.rasterise([], size: 1).pixels, TrayIcon.trackTint.bytes)
        XCTAssertEqual(TrayIcon.rasterise([quota(.codex, nil)], size: 1).pixels, TrayIcon.trackTint.bytes)
        // 0.4% of one pixel still rounds down to nothing but keeps the minimum.
        XCTAssertEqual(TrayIcon.rasterise([quota(.codex, 0.4)], size: 1).pixels,
                       TrayColor(hex: Provider.codex.tint).bytes)
        // Even where the icon is one pixel wide, that pixel is the whole
        // difference between "0% used" and "no reading".
        XCTAssertEqual(TrayIcon.rasterise([quota(.codex, 0)], size: 1).pixels,
                       TrayColor(hex: Provider.codex.tint).bytes)
        XCTAssertNotEqual(TrayIcon.rasterise([quota(.codex, 0)], size: 1),
                          TrayIcon.rasterise([quota(.codex, nil)], size: 1))
    }

    // MARK: - PNG edges

    func testPNGOfAZeroSizedBitmapIsAWellFormedEmptyImage() {
        let chunks = Self.chunks(of: [UInt8](TrayIcon.png(TrayBitmap(width: 0, height: 0, pixels: []))))
        XCTAssertEqual(chunks.map(\.type), ["IHDR", "IDAT", "IEND"])
        XCTAssertEqual(Array(chunks[0].payload.prefix(8)), [0, 0, 0, 0, 0, 0, 0, 0])
        // zlib header, one final empty stored block, then adler32 of nothing.
        XCTAssertEqual(chunks[1].payload, [0x78, 0x01, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0, 0, 0, 1])
        XCTAssertEqual(Self.storedBytes(chunks[1].payload), [])
    }

    /// A buffer shorter than `width * height * 4` has to encode as transparent
    /// pixels rather than trap on the bytes that are not there.
    func testPNGZeroFillsThePixelsAShortBufferDoesNotCover() {
        let bitmap = TrayBitmap(width: 2, height: 2, pixels: [1, 2, 3, 4])
        let chunks = Self.chunks(of: [UInt8](TrayIcon.png(bitmap)))
        XCTAssertEqual(chunks.map(\.type), ["IHDR", "IDAT", "IEND"])
        XCTAssertEqual(Array(chunks[0].payload.prefix(8)), [0, 0, 0, 2, 0, 0, 0, 2])
        XCTAssertEqual(Self.storedBytes(chunks[1].payload),
                       [0, 1, 2, 3, 4, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0],
                       "only the one pixel the buffer holds survives")
    }

    // MARK: - Minimal PNG reader

    private struct Chunk {
        let type: String
        let payload: [UInt8]
    }

    private static func chunks(of bytes: [UInt8]) -> [Chunk] {
        var chunks = [Chunk]()
        var index = 8
        while index + 12 <= bytes.count {
            let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard index + 12 + length <= bytes.count else { break }
            chunks.append(Chunk(type: String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self),
                                payload: Array(bytes[(index + 8)..<(index + 8 + length)])))
            index += 12 + length
        }
        return chunks
    }

    /// The bytes carried by a zlib stream made only of stored deflate blocks.
    private static func storedBytes(_ payload: [UInt8]) -> [UInt8] {
        var index = 2 // past the zlib header
        var raw = [UInt8]()
        while index + 5 <= payload.count {
            let isFinal = payload[index] & 1 == 1
            let length = Int(payload[index + 1]) | Int(payload[index + 2]) << 8
            guard index + 5 + length <= payload.count else { break }
            raw.append(contentsOf: payload[(index + 5)..<(index + 5 + length)])
            index += 5 + length
            if isFinal { break }
        }
        return raw
    }
}
