import XCTest
import Foundation
@testable import QuotaTray

final class DBusMessageTests: XCTestCase {
    private func hello() -> DBusMessage {
        DBusMessage(kind: .methodCall, serial: 1,
                    path: "/org/freedesktop/DBus",
                    interface: "org.freedesktop.DBus",
                    member: "Hello",
                    destination: "org.freedesktop.DBus")
    }

    func testPrologueCarriesByteOrderTypeFlagsAndVersion() throws {
        let bytes = try hello().encoded()
        XCTAssertEqual(bytes[0], 0x6C)                      // 'l'
        XCTAssertEqual(bytes[1], DBusMessage.Kind.methodCall.rawValue)
        XCTAssertEqual(bytes[2], 0)
        XCTAssertEqual(bytes[3], 1)                         // protocol version
        XCTAssertEqual(Array(bytes[4..<8]), [0, 0, 0, 0])   // empty body
        XCTAssertEqual(Array(bytes[8..<12]), [1, 0, 0, 0])  // serial
    }

    func testBigEndianFlagIsWrittenWhenAsked() throws {
        XCTAssertEqual(try hello().encoded(littleEndian: false)[0], 0x42)  // 'B'
    }

    /// The body length is not known until the body is written, so it is
    /// reserved and patched. A message whose length says 0 with a body present
    /// is the classic symptom of getting that wrong.
    func testBodyLengthIsPatchedAfterTheBodyIsMeasured() throws {
        var message = hello()
        message.body = [.string("hello")]
        let bytes = try message.encoded()
        var offset = 4
        let length = try DBusWire.decode(signature: "u", from: bytes, offset: &offset)
        // 4 length + 5 bytes + NUL.
        XCTAssertEqual(length, .uint32(10))
    }

    /// The body always starts on an 8-byte boundary, and that padding counts
    /// toward neither the header array's length nor the body's.
    func testBodyStartsOnAnEightByteBoundary() throws {
        var message = hello()
        message.body = [.byte(0xAB)]
        let bytes = try message.encoded()
        let total = try XCTUnwrap(try DBusMessage.length(of: bytes))
        XCTAssertEqual(total, bytes.count)
        XCTAssertEqual((total - 1) % 8, 0, "body of one byte should start 8-aligned")
    }

    func testHeaderFieldsRoundTrip() throws {
        var message = DBusMessage(kind: .methodReturn, serial: 7, replySerial: 3,
                                  destination: ":1.42", sender: ":1.1")
        message.body = [.string("a"), .uint32(2)]
        let decoded = try DBusMessage.decode(try message.encoded())
        XCTAssertEqual(decoded, message)
    }

    func testEveryMessageKindRoundTrips() throws {
        for kind in [DBusMessage.Kind.methodCall, .methodReturn, .error, .signal] {
            let message = DBusMessage(kind: kind, serial: 5, path: "/x", interface: "i.f",
                                      member: "M", errorName: kind == .error ? "i.f.E" : nil)
            XCTAssertEqual(try DBusMessage.decode(try message.encoded()), message)
        }
    }

    func testBodySignatureIsTheConcatenationOfItsValues() {
        var message = hello()
        message.body = [.string("a"), .array(element: "(iiay)", values: []), .boolean(true)]
        XCTAssertEqual(message.bodySignature, "sa(iiay)b")
    }

    /// The bus reads a present REPLY_SERIAL of 0 as a reply to serial 0, not as
    /// "no reply serial", so an unset field must be omitted entirely.
    func testUnsetFieldsAreOmittedRatherThanSentEmpty() throws {
        let decoded = try DBusMessage.decode(try hello().encoded())
        XCTAssertNil(decoded.replySerial)
        XCTAssertNil(decoded.errorName)
        XCTAssertNil(decoded.sender)
    }

    func testAMessageWithNoBodySendsNoSignatureField() throws {
        let bytes = try hello().encoded()
        // 'g' as a header field code 8 would appear in the header array; the
        // simplest observable proof is that decoding yields an empty body.
        XCTAssertTrue(try DBusMessage.decode(bytes).body.isEmpty)
    }

    // MARK: Framing

    /// A stream carries no framing, so the length has to come out of the header.
    func testLengthMeasuresAWholeMessage() throws {
        var message = hello()
        message.body = [.string("some payload")]
        let bytes = try message.encoded()
        XCTAssertEqual(try DBusMessage.length(of: bytes), bytes.count)
    }

    func testLengthIsNilUntilTheHeaderHasArrived() throws {
        let bytes = try hello().encoded()
        XCTAssertNil(try DBusMessage.length(of: []))
        XCTAssertNil(try DBusMessage.length(of: Array(bytes.prefix(8))))
        XCTAssertNil(try DBusMessage.length(of: Array(bytes.prefix(15))))
        XCTAssertNotNil(try DBusMessage.length(of: Array(bytes.prefix(16))))
    }

    func testLengthRejectsAnImpossibleClaim() {
        var bytes = try! hello().encoded()
        // Body length of 0xFFFFFFFF.
        for index in 4..<8 { bytes[index] = 0xFF }
        XCTAssertThrowsError(try DBusMessage.length(of: bytes)) {
            XCTAssertEqual($0 as? DBusWireError,
                           .invalidPayload("header claims an impossible length"))
        }
    }

    // MARK: Rejections

    func testDecodeRejectsAnUnknownByteOrderFlag() {
        var bytes = try! hello().encoded()
        bytes[0] = UInt8(ascii: "x")
        XCTAssertThrowsError(try DBusMessage.decode(bytes)) {
            XCTAssertEqual($0 as? DBusWireError, .invalidPayload("byte order flag 120"))
        }
    }

    /// Types beyond the four are reserved: a message we cannot classify is one
    /// we cannot safely reply to.
    func testDecodeRejectsAReservedMessageType() {
        var bytes = try! hello().encoded()
        bytes[1] = 9
        XCTAssertThrowsError(try DBusMessage.decode(bytes)) {
            XCTAssertEqual($0 as? DBusWireError, .invalidPayload("unknown message type 9"))
        }
    }

    func testDecodeRejectsAnotherProtocolVersion() {
        var bytes = try! hello().encoded()
        bytes[3] = 2
        XCTAssertThrowsError(try DBusMessage.decode(bytes)) {
            XCTAssertEqual($0 as? DBusWireError, .invalidPayload("protocol version 2"))
        }
    }

    func testDecodeRejectsATruncatedMessage() {
        let bytes = try! hello().encoded()
        XCTAssertThrowsError(try DBusMessage.decode(Array(bytes.prefix(10))))
    }
}
