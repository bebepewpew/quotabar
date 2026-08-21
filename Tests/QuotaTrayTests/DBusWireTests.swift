import XCTest
import Foundation
@testable import QuotaTray

final class DBusSignatureTests: XCTestCase {
    /// Fixed by the specification, not derived from contents: a struct is
    /// 8-aligned even when it holds only bytes, and a variant is 1-aligned even
    /// when its payload is 8.
    func testAlignmentsAreTheOnesTheSpecificationFixes() {
        XCTAssertEqual(DBusSignature.alignment(of: "y"), 1)
        XCTAssertEqual(DBusSignature.alignment(of: "g"), 1)
        XCTAssertEqual(DBusSignature.alignment(of: "v"), 1)
        XCTAssertEqual(DBusSignature.alignment(of: "n"), 2)
        XCTAssertEqual(DBusSignature.alignment(of: "q"), 2)
        XCTAssertEqual(DBusSignature.alignment(of: "b"), 4)
        XCTAssertEqual(DBusSignature.alignment(of: "i"), 4)
        XCTAssertEqual(DBusSignature.alignment(of: "s"), 4)
        XCTAssertEqual(DBusSignature.alignment(of: "o"), 4)
        XCTAssertEqual(DBusSignature.alignment(of: "a{sv}"), 4)
        XCTAssertEqual(DBusSignature.alignment(of: "x"), 8)
        XCTAssertEqual(DBusSignature.alignment(of: "t"), 8)
        XCTAssertEqual(DBusSignature.alignment(of: "d"), 8)
        XCTAssertEqual(DBusSignature.alignment(of: "(yy)"), 8)
        XCTAssertEqual(DBusSignature.alignment(of: "{sv}"), 8)
        XCTAssertEqual(DBusSignature.alignment(of: ""), 1)
    }

    /// Containers nest without separators, so splitting means matching brackets.
    func testSplitFindsTopLevelTypes() {
        XCTAssertEqual(DBusSignature.split("a{sv}s"), ["a{sv}", "s"])
        XCTAssertEqual(DBusSignature.split("(iiay)"), ["(iiay)"])
        XCTAssertEqual(DBusSignature.split("a(iiay)"), ["a(iiay)"])
        XCTAssertEqual(DBusSignature.split("sa(iiay)ss"), ["s", "a(iiay)", "s", "s"])
        XCTAssertEqual(DBusSignature.split("ia{sv}av"), ["i", "a{sv}", "av"])
        XCTAssertEqual(DBusSignature.split(""), [])
    }

    func testSplitHandlesNestingOfTheSameBracket() {
        XCTAssertEqual(DBusSignature.split("((ii)(ss))"), ["((ii)(ss))"])
        XCTAssertEqual(DBusSignature.split("aai"), ["aai"])
    }

    /// Unbalanced signatures fail here rather than halfway through a message the
    /// bus would disconnect us over.
    func testSplitRejectsUnbalancedSignatures() {
        XCTAssertNil(DBusSignature.split("(ii"))
        XCTAssertNil(DBusSignature.split("a"))
        XCTAssertNil(DBusSignature.split("{sv"))
        XCTAssertNil(DBusSignature.split("!"))
    }

    func testElementTypeStripsTheArrayMarker() {
        XCTAssertEqual(DBusSignature.elementType(of: "a{sv}"), "{sv}")
        XCTAssertEqual(DBusSignature.elementType(of: "ay"), "y")
        XCTAssertNil(DBusSignature.elementType(of: "s"))
        XCTAssertNil(DBusSignature.elementType(of: "a"))
    }
}

final class DBusWireTests: XCTestCase {
    private func encoded(_ value: DBusValue, littleEndian: Bool = true) throws -> [UInt8] {
        var bytes = [UInt8]()
        try DBusWire.encode(value, into: &bytes, littleEndian: littleEndian)
        return bytes
    }

    private func roundTrip(_ value: DBusValue, littleEndian: Bool = true) throws -> DBusValue {
        let bytes = try encoded(value, littleEndian: littleEndian)
        var offset = 0
        return try DBusWire.decode(signature: value.signature, from: bytes, offset: &offset,
                                   littleEndian: littleEndian)
    }

    // MARK: Exact bytes

    /// A string is a u32 length excluding the terminator, the bytes, then NUL.
    func testStringEncodesLengthPayloadAndTerminator() throws {
        XCTAssertEqual(try encoded(.string("foo")), [3, 0, 0, 0, 0x66, 0x6F, 0x6F, 0])
        XCTAssertEqual(try encoded(.string("")), [0, 0, 0, 0, 0])
    }

    /// A signature's length is ONE byte, not four. Using u32 here is the classic
    /// way to corrupt a message, so it is asserted exactly.
    func testSignatureLengthIsASingleByte() throws {
        XCTAssertEqual(try encoded(.signature("a{sv}")),
                       [5, 0x61, 0x7B, 0x73, 0x76, 0x7D, 0])
    }

    func testBooleanIsMarshalledAsAFourByteWord() throws {
        XCTAssertEqual(try encoded(.boolean(true)), [1, 0, 0, 0])
        XCTAssertEqual(try encoded(.boolean(false)), [0, 0, 0, 0])
    }

    /// Padding is measured from the start of the message, which is why encoding
    /// appends to a shared buffer rather than building each value in isolation.
    func testAValueIsPaddedToItsAlignment() throws {
        var bytes: [UInt8] = [0xFF]
        try DBusWire.encode(.int32(1), into: &bytes)
        XCTAssertEqual(bytes, [0xFF, 0, 0, 0, 1, 0, 0, 0])
    }

    func testAnEightAlignedValueIsPaddedToEight() throws {
        var bytes: [UInt8] = [0xFF]
        try DBusWire.encode(.uint64(1), into: &bytes)
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(Array(bytes[1..<8]), [UInt8](repeating: 0, count: 7))
    }

    /// The prefix is a BYTE count, not an element count — the single most
    /// common way to get an array wrong.
    func testArrayLengthCountsBytesNotElements() throws {
        let bytes = try encoded(.array(element: "u", values: [.uint32(1), .uint32(2)]))
        XCTAssertEqual(Array(bytes[0..<4]), [8, 0, 0, 0])
        XCTAssertEqual(bytes.count, 12)
    }

    /// Padding between the length and the first element is NOT part of the
    /// count. An 8-aligned element after a 4-byte length is the case that
    /// exposes it.
    func testArrayLengthExcludesThePaddingBeforeItsFirstElement() throws {
        let bytes = try encoded(.array(element: "t", values: [.uint64(1)]))
        // 4 length + 4 pad + 8 payload, but the length reads 8.
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(Array(bytes[0..<4]), [8, 0, 0, 0])
    }

    func testAnEmptyArrayIsJustAZeroLength() throws {
        XCTAssertEqual(try encoded(.strings([])), [0, 0, 0, 0])
    }

    /// A variant carries its own signature ahead of its value.
    func testVariantIsSignatureThenValue() throws {
        XCTAssertEqual(try encoded(.variant(.byte(7))), [1, 0x79, 0, 7])
    }

    func testStructMembersFollowTheEightAlignedStart() throws {
        var bytes: [UInt8] = [0xFF]
        try DBusWire.encode(.struct([.byte(1), .byte(2)]), into: &bytes)
        XCTAssertEqual(bytes, [0xFF] + [UInt8](repeating: 0, count: 7) + [1, 2])
    }

    func testBigEndianFlipsMultiByteScalars() throws {
        XCTAssertEqual(try encoded(.uint32(1), littleEndian: false), [0, 0, 0, 1])
        XCTAssertEqual(try encoded(.uint32(1), littleEndian: true), [1, 0, 0, 0])
    }

    // MARK: Round trips

    func testEveryBasicTypeRoundTrips() throws {
        let values: [DBusValue] = [
            .byte(0xAB), .boolean(true), .boolean(false),
            .int16(.min), .int16(.max), .uint16(.max),
            .int32(.min), .int32(.max), .uint32(.max),
            .int64(.min), .int64(.max), .uint64(.max),
            .double(3.5), .double(-0.0),
            .string("héllo · wörld"), .objectPath("/StatusNotifierItem"), .signature("a(iiay)"),
        ]
        for value in values {
            XCTAssertEqual(try roundTrip(value), value, "\(value)")
            XCTAssertEqual(try roundTrip(value, littleEndian: false), value, "\(value) big-endian")
        }
    }

    func testContainersRoundTrip() throws {
        let values: [DBusValue] = [
            .strings(["a", "bb", ""]),
            .bytes([0, 1, 2, 255]),
            .array(element: "t", values: [.uint64(1), .uint64(2)]),
            .dictionary(["Status": .string("Active"), "ItemIsMenu": .boolean(false)]),
            .struct([.int32(1), .int32(2), .bytes([9, 9])]),
            .array(element: "(iiay)", values: [.struct([.int32(1), .int32(1), .bytes([1, 2, 3, 4])])]),
            .array(element: "v", values: [.variant(.string("x")), .variant(.int32(2))]),
        ]
        for value in values {
            XCTAssertEqual(try roundTrip(value), value, "\(value)")
        }
    }

    /// The real payloads this exists to carry.
    func testTheStatusNotifierItemPayloadsRoundTrip() throws {
        let tip = StatusNotifierItemProperties.toolTip(title: "QuotaBar", lines: ["codex 40%"])
        XCTAssertEqual(try roundTrip(tip), tip)

        let icon = StatusNotifierItemProperties.iconPixmap([TrayBitmap(width: 2, height: 2)])
        XCTAssertEqual(try roundTrip(icon), icon)

        let all = StatusNotifierItemProperties.all(quotas: [], bitmaps: [], toolTipLines: ["a"])
        XCTAssertEqual(try roundTrip(all), all)

        let layout = DBusMenuLayout.build(from: [
            TrayMenuItem(kind: .quota, title: "codex weekly", detail: "40%"),
            TrayMenuItem(kind: .separator, title: ""),
            TrayMenuItem(kind: .action, title: "Quit", actionID: TrayMenu.quitActionID),
        ])
        XCTAssertEqual(try roundTrip(layout.node), layout.node)
    }

    // MARK: Rejections

    func testEncodingRejectsAnElementThatIsNotTheDeclaredType() {
        let mixed = DBusValue.array(element: "s", values: [.int32(1)])
        XCTAssertThrowsError(try encoded(mixed)) { error in
            XCTAssertEqual(error as? DBusWireError, .typeMismatch(expected: "s", actual: "i"))
        }
    }

    func testEncodingRejectsAnUnparsableElementSignature() {
        XCTAssertThrowsError(try encoded(.array(element: "(ii", values: []))) { error in
            XCTAssertEqual(error as? DBusWireError, .malformedSignature("(ii"))
        }
    }

    func testDecodingATruncatedBufferThrows() {
        var offset = 0
        XCTAssertThrowsError(try DBusWire.decode(signature: "u", from: [1, 2], offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .truncated)
        }
    }

    func testDecodingAStringWithoutItsTerminatorThrows() {
        // Length 3, three bytes, and then the buffer ends where NUL should be.
        var offset = 0
        let bytes: [UInt8] = [3, 0, 0, 0, 0x66, 0x6F, 0x6F]
        XCTAssertThrowsError(try DBusWire.decode(signature: "s", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .truncated)
        }
    }

    func testDecodingRejectsAStringThatIsNotUTF8() {
        var offset = 0
        let bytes: [UInt8] = [1, 0, 0, 0, 0xFF, 0]
        XCTAssertThrowsError(try DBusWire.decode(signature: "s", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .invalidPayload("not UTF-8"))
        }
    }

    /// Only 0 and 1 are legal, and a peer sending 2 is broken or probing.
    func testDecodingRejectsABooleanThatIsNotZeroOrOne() {
        var offset = 0
        XCTAssertThrowsError(try DBusWire.decode(signature: "b", from: [2, 0, 0, 0],
                                                 offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .invalidPayload("boolean is 2"))
        }
    }

    /// The specification requires padding to be zero. A peer writing something
    /// else is either broken or hiding data there.
    func testDecodingRejectsNonZeroPadding() {
        var offset = 1
        let bytes: [UInt8] = [0xFF, 0xAA, 0xAA, 0xAA, 1, 0, 0, 0]
        XCTAssertThrowsError(try DBusWire.decode(signature: "u", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .invalidPayload("non-zero padding"))
        }
    }

    /// Pinned to the specification's literal rather than to our own constant. A
    /// test that builds its input out of the value it is policing passes however
    /// that value drifts.
    func testTheLimitsAreTheOnesTheSpecificationSets() {
        XCTAssertEqual(DBusWire.maximumArrayBytes, 67_108_864)   // 64 MiB
        XCTAssertEqual(DBusWire.maximumDepth, 64)
    }

    /// The length prefix is attacker-controlled on any bus and decides how long
    /// the decode loop runs, so it is bounded before it is trusted.
    func testDecodingRejectsAnArrayLengthBeyondTheSpecLimit() {
        var offset = 0
        var bytes = [UInt8]()
        withUnsafeBytes(of: UInt32(67_108_865).littleEndian) { bytes.append(contentsOf: $0) }
        XCTAssertThrowsError(try DBusWire.decode(signature: "ay", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .invalidPayload("array claims 67108865 bytes"))
        }
    }

    /// The other side of the boundary, which pins the comparison as `<=` rather
    /// than `<`: a length of exactly the limit is allowed past the bound and then
    /// fails on the buffer instead.
    func testALengthOfExactlyTheLimitIsNotItselfRejected() {
        var offset = 0
        var bytes = [UInt8]()
        withUnsafeBytes(of: UInt32(67_108_864).littleEndian) { bytes.append(contentsOf: $0) }
        XCTAssertThrowsError(try DBusWire.decode(signature: "ay", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .truncated)
        }
    }

    /// Without a depth bound, a body of nested variants recurses once per three
    /// payload bytes, so a few kilobytes from any peer overflows the stack — and
    /// that is a crash, not a thrown error.
    func testDecodingRefusesContainersNestedTooDeeply() {
        // Each level is a variant whose payload is another variant: `1 'v' 0`.
        var bytes = [UInt8]()
        for _ in 0...(DBusWire.maximumDepth + 2) {
            bytes.append(contentsOf: [1, UInt8(ascii: "v"), 0])
        }
        bytes.append(contentsOf: [1, UInt8(ascii: "y"), 0, 0])
        var offset = 0
        XCTAssertThrowsError(try DBusWire.decode(signature: "v", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError,
                           .invalidPayload("nested deeper than \(DBusWire.maximumDepth)"))
        }
    }

    /// And nesting within the bound still decodes, so the guard is not simply
    /// refusing everything nested.
    func testNestingWithinTheBoundStillDecodes() throws {
        let nested = DBusValue.variant(.variant(.variant(.string("deep"))))
        XCTAssertEqual(try roundTrip(nested), nested)
    }

    func testDecodingRejectsAnArrayLongerThanItsBuffer() {
        var offset = 0
        let bytes: [UInt8] = [16, 0, 0, 0, 1, 2]
        XCTAssertThrowsError(try DBusWire.decode(signature: "ay", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .truncated)
        }
    }

    /// A final element reading past the declared end means payload and length
    /// disagree; trusting the length would desynchronise the rest of the message.
    func testDecodingRejectsAnArrayWhoseElementsOverrunItsLength() {
        // Claims 3 bytes of `u`, which cannot hold one 4-byte element.
        var offset = 0
        let bytes: [UInt8] = [3, 0, 0, 0, 1, 0, 0, 0]
        XCTAssertThrowsError(try DBusWire.decode(signature: "au", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .invalidPayload("array overran its length"))
        }
    }

    func testDecodingRejectsAVariantCarryingMoreThanOneType() {
        var offset = 0
        // Signature "ii" inside a variant: two complete types, which is illegal.
        let bytes: [UInt8] = [2, 0x69, 0x69, 0, 1, 0, 0, 0, 2, 0, 0, 0]
        XCTAssertThrowsError(try DBusWire.decode(signature: "v", from: bytes, offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .malformedSignature("ii"))
        }
    }

    func testDecodingRejectsAnEmptyStructSignature() {
        var offset = 0
        XCTAssertThrowsError(try DBusWire.decode(signature: "()", from: [0, 0, 0, 0, 0, 0, 0, 0],
                                                 offset: &offset)) {
            XCTAssertEqual($0 as? DBusWireError, .malformedSignature("()"))
        }
    }

    func testPadIsIdempotentOnAnAlignedBuffer() {
        var bytes: [UInt8] = [1, 2, 3, 4]
        DBusWire.pad(&bytes, to: 4)
        XCTAssertEqual(bytes, [1, 2, 3, 4])
        DBusWire.pad(&bytes, to: 1)
        XCTAssertEqual(bytes, [1, 2, 3, 4])
    }
}
