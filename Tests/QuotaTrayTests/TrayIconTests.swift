import XCTest
@testable import QuotaTray
import QuotaCore

/// The icon is the only quota reading a tray user sees at a glance, so the
/// thresholds and the bar length are pinned to exact pixels, and the PNG is
/// checked byte by byte against an independent CRC/adler implementation rather
/// than against the encoder's own helpers.
final class TrayIconTests: XCTestCase {
    // MARK: - Fixtures

    private static let size = TrayIcon.defaultSize // 22

    /// Layout for `size` 22: bar height 3, gap 2, the stack centred vertically.
    private static let singleRow = 9..<12
    private static let tripleRows = [4..<7, 9..<12, 14..<17]

    private let geminiTint: [UInt8] = [0x4F, 0x7D, 0xF3, 255]
    private let claudeTint: [UInt8] = [0xD9, 0x77, 0x57, 255]
    private let codexTint: [UInt8] = [0x10, 0xA3, 0x7F, 255]
    private let amber: [UInt8] = [0xFF, 0x9F, 0x0A, 255]
    private let red: [UInt8] = [0xFF, 0x45, 0x3A, 255]
    private let track: [UInt8] = [0x8E, 0x8E, 0x93, 56]
    private let clear: [UInt8] = [0, 0, 0, 0]

    /// `Int(_:)` traps on NaN and on an infinity, so the badge falls back to the
    /// no-reading dash for a percentage the renderer is going to reject anyway.
    private func quota(_ provider: Provider, _ used: Double?, label: String = "5-hour") -> MenuBarQuota {
        MenuBarQuota(selection: QuotaSelection(provider: provider, windowLabel: label),
                     usedPercent: used,
                     badge: used.flatMap { $0.isFinite ? "\(Int($0))" : nil } ?? "—")
    }

    private func pixel(_ bitmap: TrayBitmap, _ x: Int, _ y: Int) -> [UInt8] {
        guard let offset = bitmap.offset(x: x, y: y), offset + 3 < bitmap.pixels.count else { return [] }
        return Array(bitmap.pixels[offset..<(offset + 4)])
    }

    /// The bar row of a one-quota icon, as RGBA quadruples left to right.
    private func onlyRow(_ bitmap: TrayBitmap) -> [[UInt8]] {
        (0..<bitmap.width).map { pixel(bitmap, $0, Self.singleRow.lowerBound + 1) }
    }

    // MARK: - Thresholds

    func testProviderTintBelowEightyPercent() {
        for (provider, tint) in [(Provider.gemini, geminiTint), (.claude, claudeTint), (.codex, codexTint)] {
            let bitmap = TrayIcon.rasterise([quota(provider, 79.9)])
            XCTAssertEqual(pixel(bitmap, 0, 10), tint, "\(provider.rawValue) at 79.9%")
            XCTAssertEqual(pixel(bitmap, 17, 10), tint, "\(provider.rawValue) at 79.9%")
        }
    }

    func testAmberStartsExactlyAtEighty() {
        XCTAssertEqual(pixel(TrayIcon.rasterise([quota(.codex, 79.9)]), 0, 10), codexTint)
        XCTAssertEqual(pixel(TrayIcon.rasterise([quota(.codex, 80)]), 0, 10), amber)
        XCTAssertEqual(pixel(TrayIcon.rasterise([quota(.codex, 80)]), 17, 10), amber)
    }

    func testRedStartsExactlyAtNinetyFive() {
        XCTAssertEqual(pixel(TrayIcon.rasterise([quota(.gemini, 94.9)]), 0, 10), amber)
        XCTAssertEqual(pixel(TrayIcon.rasterise([quota(.gemini, 95)]), 0, 10), red)
        XCTAssertEqual(pixel(TrayIcon.rasterise([quota(.gemini, 100)]), 21, 10), red)
    }

    /// Every row of a bar carries the same colour, so a threshold cannot be read
    /// off one lucky scanline.
    func testThresholdColourFillsTheWholeBarHeight() {
        let bitmap = TrayIcon.rasterise([quota(.claude, 95)])
        for y in Self.singleRow {
            XCTAssertEqual(pixel(bitmap, 0, y), red, "row \(y)")
        }
        XCTAssertEqual(pixel(bitmap, 0, Self.singleRow.lowerBound - 1), clear)
        XCTAssertEqual(pixel(bitmap, 0, Self.singleRow.upperBound), clear)
    }

    // MARK: - Bar length

    func testBarLengthIsProportionalToUsedPercent() {
        // 22px track: 50% rounds to 11, 25% (5.5) rounds away from zero to 6.
        let half = TrayIcon.rasterise([quota(.codex, 50)])
        XCTAssertEqual(pixel(half, 10, 10), codexTint)
        XCTAssertEqual(pixel(half, 11, 10), track)

        let quarter = TrayIcon.rasterise([quota(.codex, 25)])
        XCTAssertEqual(pixel(quarter, 5, 10), codexTint)
        XCTAssertEqual(pixel(quarter, 6, 10), track)

        let full = TrayIcon.rasterise([quota(.codex, 100)])
        XCTAssertEqual(pixel(full, 21, 10), red)
        XCTAssertEqual(onlyRow(full).filter { $0 == track }.count, 0)
    }

    func testBarLengthScalesWithIconSize() {
        let bitmap = TrayIcon.rasterise([quota(.codex, 50)], size: 40)
        // size 40: bar height 6, one row centred at y 17..<23.
        XCTAssertEqual(pixel(bitmap, 19, 20), codexTint)
        XCTAssertEqual(pixel(bitmap, 20, 20), track)
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: 50, trackWidth: 40), 20)
    }

    /// Every reading keeps a pixel, including a reading of exactly zero: the
    /// bare track has to mean "no reading" and nothing else.
    func testEveryReadingFromZeroUpwardsKeepsOnePixel() {
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: 0, trackWidth: 22), 1)
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: 0.4, trackWidth: 22), 1)
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: 0, trackWidth: 1), 1)

        let barely = TrayIcon.rasterise([quota(.gemini, 0.1)])
        XCTAssertEqual(pixel(barely, 0, 10), geminiTint)
        XCTAssertEqual(pixel(barely, 1, 10), track)

        let unused = TrayIcon.rasterise([quota(.gemini, 0)])
        XCTAssertEqual(pixel(unused, 0, 10), geminiTint)
        XCTAssertEqual(pixel(unused, 1, 10), track)
        for y in Self.singleRow {
            XCTAssertEqual(pixel(unused, 0, y), geminiTint, "row \(y)")
        }
    }

    /// The bug this pins: a window at 0% used and a window with no reading at
    /// all drew the same bytes, so a failed probe read as "fine, nothing used".
    func testZeroPercentIsDistinguishableFromNoReading() {
        let zero = TrayIcon.rasterise([quota(.gemini, 0)])
        let missing = TrayIcon.rasterise([quota(.gemini, nil)])
        XCTAssertNotEqual(zero, missing)
        XCTAssertNotEqual(TrayIcon.png(zero), TrayIcon.png(missing))
        XCTAssertEqual(onlyRow(missing), Array(repeating: track, count: Self.size))
    }

    /// Percentages come from CLI output, so out-of-range values must clamp
    /// instead of drawing outside the track — and a value that is no reading at
    /// all must not borrow the stub a real zero now gets.
    func testOutOfRangePercentagesClamp() {
        let over = TrayIcon.rasterise([quota(.claude, 150)])
        XCTAssertEqual(onlyRow(over), Array(repeating: red, count: Self.size))

        let under = TrayIcon.rasterise([quota(.claude, -5)])
        XCTAssertEqual(onlyRow(under), Array(repeating: track, count: Self.size))

        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: -5, trackWidth: 22), 0)
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: -0.0001, trackWidth: 22), 0)
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: .nan, trackWidth: 22), 0)
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: .infinity, trackWidth: 22), 0)
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: -.infinity, trackWidth: 22), 0)
        XCTAssertEqual(TrayIcon.filledWidth(usedPercent: 0, trackWidth: 0), 0)

        // Whatever the rejected value was, the track is still drawn in full, so
        // the tray item stays visible and reads as "no reading".
        for rejected in [Double.nan, .infinity, -.infinity, -5] {
            XCTAssertEqual(onlyRow(TrayIcon.rasterise([quota(.claude, rejected)])),
                           Array(repeating: track, count: Self.size), "\(rejected)")
        }
    }

    func testQuotaWithoutAReadingDrawsTrackOnly() {
        let bitmap = TrayIcon.rasterise([quota(.codex, nil)])
        XCTAssertEqual(onlyRow(bitmap), Array(repeating: track, count: Self.size))
    }

    // MARK: - Layout

    func testThreeQuotasStackWithTheirOwnColours() {
        let bitmap = TrayIcon.rasterise([quota(.gemini, 10), quota(.claude, 85), quota(.codex, 99)])
        let expected = [geminiTint, amber, red]
        for (index, rows) in Self.tripleRows.enumerated() {
            for y in rows {
                XCTAssertEqual(pixel(bitmap, 0, y), expected[index], "row \(index) line \(y)")
            }
            XCTAssertEqual(pixel(bitmap, 0, rows.lowerBound - 1), clear, "gap above row \(index)")
        }
        XCTAssertEqual(pixel(bitmap, 0, Self.tripleRows[2].upperBound), clear)
    }

    func testAtMostThreeQuotasAreDrawn() {
        let three = [quota(.gemini, 10), quota(.claude, 85), quota(.codex, 99)]
        let fourth = quota(.gemini, 42, label: "weekly")
        XCTAssertEqual(TrayIcon.rasterise(three + [fourth]), TrayIcon.rasterise(three))
    }

    /// An empty selection still has to be a visible tray item.
    func testEmptySelectionDrawsAnEmptyTrack() {
        let bitmap = TrayIcon.rasterise([])
        XCTAssertEqual(onlyRow(bitmap), Array(repeating: track, count: Self.size))
        XCTAssertEqual(pixel(bitmap, 0, Self.singleRow.lowerBound - 1), clear)
    }

    func testBitmapIsSquareAndFullySized() {
        let bitmap = TrayIcon.rasterise([quota(.codex, 50)], size: 33)
        XCTAssertEqual(bitmap.width, 33)
        XCTAssertEqual(bitmap.height, 33)
        XCTAssertEqual(bitmap.pixels.count, 33 * 33 * 4)
        // A degenerate size must not trap or produce a negative buffer.
        XCTAssertEqual(TrayIcon.rasterise([quota(.codex, 50)], size: 0).width, 1)
    }

    // MARK: - PNG

    func testPNGSignatureAndChunkOrder() {
        let bytes = [UInt8](TrayIcon.png(TrayIcon.rasterise([quota(.codex, 50)])))
        XCTAssertEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let chunks = Self.chunks(of: bytes)
        XCTAssertEqual(chunks.map(\.type), ["IHDR", "IDAT", "IEND"])
        XCTAssertEqual(chunks.last?.payload.count, 0)
    }

    func testPNGChunkCRCsAreCorrect() {
        let bytes = [UInt8](TrayIcon.png(TrayIcon.rasterise([quota(.claude, 81)])))
        let chunks = Self.chunks(of: bytes)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertEqual(chunk.crc, Self.crc32(Array(chunk.type.utf8) + chunk.payload),
                           "\(chunk.type) CRC")
            XCTAssertEqual(chunk.length, chunk.payload.count, "\(chunk.type) length")
        }
        // Nothing beyond IEND.
        let consumed = 8 + chunks.reduce(0) { $0 + $1.payload.count + 12 }
        XCTAssertEqual(consumed, bytes.count)
    }

    func testPNGHeaderCarriesTheBitmapDimensions() {
        let bitmap = TrayIcon.rasterise([quota(.gemini, 20)], size: 40)
        let header = Self.chunks(of: [UInt8](TrayIcon.png(bitmap))).first
        XCTAssertEqual(header?.type, "IHDR")
        XCTAssertEqual(header?.payload.count, 13)
        XCTAssertEqual(Self.beUInt32(header?.payload ?? [], at: 0), 40)
        XCTAssertEqual(Self.beUInt32(header?.payload ?? [], at: 4), 40)
        XCTAssertEqual(Array((header?.payload ?? []).suffix(5)), [8, 6, 0, 0, 0])
    }

    /// The whole point of the encoder: no zlib. Every deflate block must be a
    /// stored one, and the adler32 must cover the raw scanlines.
    func testPNGDataIsStoredDeflateWithAdler32() throws {
        let bitmap = TrayIcon.rasterise([quota(.codex, 50), quota(.claude, 96)])
        let idat = try XCTUnwrap(Self.chunks(of: [UInt8](TrayIcon.png(bitmap))).first { $0.type == "IDAT" })
        XCTAssertEqual(Array(idat.payload.prefix(2)), [0x78, 0x01])

        let stream = try Self.inflateStored(idat.payload)
        XCTAssertEqual(stream.blocks, 1)
        XCTAssertEqual(stream.adler, Self.adler32(stream.raw))
        XCTAssertEqual(stream.adler, Self.adler32(Self.expectedScanlines(bitmap)))
        XCTAssertEqual(stream.raw, Self.expectedScanlines(bitmap))
    }

    /// 128 × 128 raw bytes exceed the 65535-byte stored-block limit, so the
    /// encoder has to split and mark only the last block final.
    func testPNGSplitsRawDataAcrossStoredBlocks() throws {
        let bitmap = TrayIcon.rasterise([quota(.gemini, 50)], size: 128)
        let idat = try XCTUnwrap(Self.chunks(of: [UInt8](TrayIcon.png(bitmap))).first { $0.type == "IDAT" })

        let stream = try Self.inflateStored(idat.payload)
        XCTAssertEqual(stream.raw.count, 128 * (128 * 4 + 1))
        XCTAssertEqual(stream.blocks, 2)
        XCTAssertEqual(stream.raw, Self.expectedScanlines(bitmap))
        XCTAssertEqual(stream.adler, Self.adler32(stream.raw))
    }

    // MARK: - Independent PNG reader

    private struct Chunk {
        let length: Int
        let type: String
        let payload: [UInt8]
        let crc: UInt32
    }

    private static func chunks(of bytes: [UInt8]) -> [Chunk] {
        var chunks = [Chunk]()
        var index = 8
        while index + 12 <= bytes.count {
            let length = Int(beUInt32(bytes, at: index))
            guard index + 12 + length <= bytes.count else { break }
            let type = String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self)
            let payload = Array(bytes[(index + 8)..<(index + 8 + length)])
            let crc = beUInt32(bytes, at: index + 8 + length)
            chunks.append(Chunk(length: length, type: type, payload: payload, crc: crc))
            index += 12 + length
            if type == "IEND" { break }
        }
        return chunks
    }

    /// Walks a zlib stream made only of stored deflate blocks, failing on any
    /// block that is not stored or whose NLEN is not the complement of LEN.
    private static func inflateStored(_ payload: [UInt8]) throws -> (raw: [UInt8], adler: UInt32, blocks: Int) {
        var index = 2 // past the zlib header
        var raw = [UInt8]()
        var blocks = 0
        while index < payload.count {
            guard index + 5 <= payload.count else {
                throw NSError(domain: "png", code: 4, userInfo: [NSLocalizedDescriptionKey: "truncated block header"])
            }
            let header = payload[index]
            guard header & 0x06 == 0 else {
                throw NSError(domain: "png", code: 1, userInfo: [NSLocalizedDescriptionKey: "block \(blocks) is not stored"])
            }
            let isFinal = header & 0x01 == 1
            let length = Int(payload[index + 1]) | Int(payload[index + 2]) << 8
            let nlen = Int(payload[index + 3]) | Int(payload[index + 4]) << 8
            guard nlen == (~length) & 0xFFFF else {
                throw NSError(domain: "png", code: 2, userInfo: [NSLocalizedDescriptionKey: "NLEN mismatch"])
            }
            guard index + 5 + length <= payload.count else {
                throw NSError(domain: "png", code: 5, userInfo: [NSLocalizedDescriptionKey: "block \(blocks) runs past the chunk"])
            }
            raw.append(contentsOf: payload[(index + 5)..<(index + 5 + length)])
            index += 5 + length
            blocks += 1
            if isFinal { break }
        }
        guard index + 4 == payload.count else {
            throw NSError(domain: "png", code: 3, userInfo: [NSLocalizedDescriptionKey: "trailing bytes after final block"])
        }
        return (raw, beUInt32(payload, at: index), blocks)
    }

    private static func expectedScanlines(_ bitmap: TrayBitmap) -> [UInt8] {
        var raw = [UInt8]()
        for y in 0..<bitmap.height {
            raw.append(0) // filter type None
            let start = y * bitmap.width * 4
            raw.append(contentsOf: bitmap.pixels[start..<(start + bitmap.width * 4)])
        }
        return raw
    }

    private static func beUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        guard index + 3 < bytes.count else { return 0 }
        return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
        }
        return value ^ 0xFFFF_FFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in bytes {
            low = (low + UInt32(byte)) % 65_521
            high = (high + low) % 65_521
        }
        return (high << 16) | low
    }
}
