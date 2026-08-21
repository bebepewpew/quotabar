import Foundation
import QuotaCore

/// A plain RGBA8 pixel buffer, first row at the top.
///
/// Rasterising and encoding are separate so tests can assert exact pixels — bar
/// length, threshold colours — without decoding an image, and so a fault in the
/// encoder cannot be mistaken for a fault in the drawing.
public struct TrayBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes in RGBA order.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
    }

    /// Byte offset of the pixel at `(x, y)`, or nil when out of bounds.
    public func offset(x: Int, y: Int) -> Int? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return (y * width + x) * 4
    }
}

/// One RGBA8 colour. There is no colour framework on Linux, so the tray carries
/// its own four bytes rather than depending on a toolkit.
public struct TrayColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `RRGGBB` the way `Provider.tint` stores it, with an optional `#`.
    /// Anything else is a neutral grey: an unparsable tint must still be a
    /// visible icon, never a transparent or black one.
    public init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        // `UInt32(_:radix:)` accepts a leading sign, so "+12345" would otherwise
        // parse as 0x012345 — a wrong colour rather than the documented grey.
        // Six ASCII hex digits is the only form this reads.
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt32(digits, radix: 16) else {
            self.init(red: 0x8E, green: 0x8E, blue: 0x93)
            return
        }
        self.init(red: UInt8((value >> 16) & 0xFF),
                  green: UInt8((value >> 8) & 0xFF),
                  blue: UInt8(value & 0xFF))
    }

    var bytes: [UInt8] { [red, green, blue, alpha] }
}

public enum TrayIcon {
    /// StatusNotifierItem icons are conventionally 22px.
    public static let defaultSize = 22

    /// Mirrors the macOS menu bar, which also shows at most three.
    public static let maximumQuotas = 3

    /// `systemOrange` and `systemRed` as macOS resolves them, so a quota looks
    /// the same in the Linux tray as it does in the menu bar.
    public static let warningTint = TrayColor(hex: "FF9F0A")
    public static let criticalTint = TrayColor(hex: "FF453A")
    /// The unfilled part of a bar: `secondaryLabelColor` at 0.22 alpha, the
    /// track the macOS renderer draws under its fill.
    public static let trackTint = TrayColor(red: 0x8E, green: 0x8E, blue: 0x93, alpha: 56)

    /// Draws up to three selected quotas: provider tint below 80% used, amber at
    /// 80, red at 95 — the thresholds `MenuBarIconRenderer` uses on macOS.
    ///
    /// The icon is square. Each quota is one full-width horizontal bar, the
    /// bars stacked and centred vertically; there is no glyph beside them
    /// because 22px carries no legible text without a toolkit. A quota with no
    /// reading yet, and an empty selection, draw the track alone rather than
    /// nothing at all, so the tray item never becomes invisible; a quota that
    /// reported 0% used draws a one-pixel stub instead, so the bare track means
    /// "no reading" and nothing else.
    public static func rasterise(_ quotas: [MenuBarQuota], size: Int = defaultSize) -> TrayBitmap {
        let side = max(1, size)
        var bitmap = TrayBitmap(width: side, height: side)

        let shown = Array(quotas.prefix(maximumQuotas))
        let rows = max(1, shown.count)
        let barHeight = max(1, side / 6)
        let gap = max(1, side / 11)
        let block = rows * barHeight + (rows - 1) * gap
        let top = max(0, (side - block) / 2)

        for row in 0..<rows {
            let originY = top + row * (barHeight + gap)
            guard originY < side else { break }
            let bar = originY..<min(originY + barHeight, side)
            fill(&bitmap, x: 0..<side, y: bar, color: trackTint)

            guard row < shown.count, let used = shown[row].usedPercent else { continue }
            let filled = filledWidth(usedPercent: used, trackWidth: side)
            guard filled > 0 else { continue }
            fill(&bitmap, x: 0..<filled, y: bar,
                 color: tint(usedPercent: used, provider: shown[row].selection.provider))
        }
        return bitmap
    }

    /// Provider tint below 80% used, amber from 80, red from 95.
    public static func tint(usedPercent: Double, provider: Provider) -> TrayColor {
        if usedPercent >= 95 { return criticalTint }
        if usedPercent >= 80 { return warningTint }
        return TrayColor(hex: provider.tint)
    }

    /// Filled pixels for `usedPercent` of `trackWidth`, rounded to the nearest
    /// pixel. Percentages arrive from CLI output, so they are clamped here too;
    /// every reading from zero upwards keeps at least one pixel, so "nothing
    /// used yet" and "barely used" both read differently from the bare track,
    /// which means "no reading" — a failed probe must not look like a healthy
    /// empty quota.
    ///
    /// A value that is not a reading at all is rejected rather than clamped: a
    /// negative, NaN or infinite percentage draws no fill, because inventing a
    /// stub — or a full red bar — out of garbage input is worse than showing
    /// the same "no reading" the probe failure already means.
    static func filledWidth(usedPercent: Double, trackWidth: Int) -> Int {
        guard trackWidth > 0, usedPercent.isFinite, usedPercent >= 0 else { return 0 }
        let clamped = min(usedPercent, 100)
        let exact = (Double(trackWidth) * clamped / 100).rounded()
        return max(1, min(trackWidth, Int(exact)))
    }

    private static func fill(_ bitmap: inout TrayBitmap, x: Range<Int>, y: Range<Int>, color: TrayColor) {
        for row in y {
            for column in x {
                guard let offset = bitmap.offset(x: column, y: row),
                      offset + 3 < bitmap.pixels.count else { continue }
                bitmap.pixels[offset] = color.red
                bitmap.pixels[offset + 1] = color.green
                bitmap.pixels[offset + 2] = color.blue
                bitmap.pixels[offset + 3] = color.alpha
            }
        }
    }

    // MARK: - PNG

    /// PNG bytes for `bitmap`. Must not link zlib: use stored (uncompressed)
    /// deflate blocks with adler32, and a CRC32 per chunk.
    ///
    /// A tray icon is a couple of kilobytes, so the bytes a real deflate would
    /// save are not worth a C dependency on every Linux distribution.
    public static func png(_ bitmap: TrayBitmap) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var header = Data()
        header.append(bigEndian(UInt32(max(0, bitmap.width))))
        header.append(bigEndian(UInt32(max(0, bitmap.height))))
        // 8 bits per sample, colour type 6 (truecolour with alpha), deflate,
        // adaptive filtering, no interlace — the only combination written here.
        header.append(contentsOf: [8, 6, 0, 0, 0] as [UInt8])
        data.append(chunk("IHDR", header))
        data.append(chunk("IDAT", zlibStored(scanlines(bitmap))))
        data.append(chunk("IEND", Data()))
        return data
    }

    /// Every row prefixed with filter type 0 (None): filtering only pays off
    /// with a real compressor behind it.
    private static func scanlines(_ bitmap: TrayBitmap) -> [UInt8] {
        let width = max(0, bitmap.width)
        let height = max(0, bitmap.height)
        guard width > 0, height > 0 else { return [] }

        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 4 + 1))
        for y in 0..<height {
            raw.append(0)
            for x in 0..<width {
                // A caller-supplied `pixels` array may be short; a truncated
                // buffer should still encode rather than trap.
                guard let offset = bitmap.offset(x: x, y: y), offset + 3 < bitmap.pixels.count else {
                    raw.append(contentsOf: [0, 0, 0, 0] as [UInt8])
                    continue
                }
                raw.append(contentsOf: bitmap.pixels[offset..<(offset + 4)])
            }
        }
        return raw
    }

    /// A zlib stream of stored deflate blocks: 0x78 0x01, then `BFINAL|BTYPE=00`
    /// blocks of at most 65535 bytes, then the adler32 of the raw bytes.
    private static func zlibStored(_ raw: [UInt8]) -> Data {
        var out = Data([0x78, 0x01])
        let maximumBlock = 65_535
        var index = 0
        repeat {
            let length = min(maximumBlock, raw.count - index)
            let isFinal = index + length >= raw.count
            out.append(isFinal ? 1 : 0)
            let stored = UInt16(length)
            out.append(littleEndian(stored))
            out.append(littleEndian(~stored))
            out.append(contentsOf: raw[index..<(index + length)])
            index += length
        } while index < raw.count
        out.append(bigEndian(adler32(raw)))
        return out
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        let typed = Data(type.utf8) + payload
        var out = bigEndian(UInt32(payload.count))
        out.append(typed)
        out.append(bigEndian(crc32(typed)))
        return out
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

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func littleEndian(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}
