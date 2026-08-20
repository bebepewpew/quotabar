import XCTest
@testable import QuotaTray
import QuotaCore

/// Placeholder so the target has a test from the start. Each parallel task adds
/// its own file beside this one.
final class TraySeamTests: XCTestCase {
    func testBitmapOffsetsAreBounded() {
        let bitmap = TrayBitmap(width: 4, height: 3)
        XCTAssertEqual(bitmap.pixels.count, 4 * 3 * 4)
        XCTAssertEqual(bitmap.offset(x: 0, y: 0), 0)
        XCTAssertEqual(bitmap.offset(x: 3, y: 2), (2 * 4 + 3) * 4)
        XCTAssertNil(bitmap.offset(x: 4, y: 0))
        XCTAssertNil(bitmap.offset(x: -1, y: 0))
    }
}
