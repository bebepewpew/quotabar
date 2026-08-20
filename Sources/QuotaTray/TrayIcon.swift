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

public enum TrayIcon {
    /// StatusNotifierItem icons are conventionally 22px.
    public static let defaultSize = 22

    /// Draws up to three selected quotas: provider tint below 80% used, amber at
    /// 80, red at 95 — the thresholds `MenuBarIconRenderer` uses on macOS.
    public static func rasterise(_ quotas: [MenuBarQuota], size: Int = defaultSize) -> TrayBitmap {
        // TODO(task 1: icon renderer)
        TrayBitmap(width: size, height: size)
    }

    /// PNG bytes for `bitmap`. Must not link zlib: use stored (uncompressed)
    /// deflate blocks with adler32, and a CRC32 per chunk.
    public static func png(_ bitmap: TrayBitmap) -> Data {
        // TODO(task 1: icon renderer)
        Data()
    }
}
