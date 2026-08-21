import XCTest
import Foundation
@testable import QuotaTray

final class DBusValueTests: XCTestCase {
    func testSignatureOfEveryBasicType() {
        XCTAssertEqual(DBusValue.byte(1).signature, "y")
        XCTAssertEqual(DBusValue.boolean(true).signature, "b")
        XCTAssertEqual(DBusValue.int16(-1).signature, "n")
        XCTAssertEqual(DBusValue.uint16(1).signature, "q")
        XCTAssertEqual(DBusValue.int32(-1).signature, "i")
        XCTAssertEqual(DBusValue.uint32(1).signature, "u")
        XCTAssertEqual(DBusValue.int64(-1).signature, "x")
        XCTAssertEqual(DBusValue.uint64(1).signature, "t")
        XCTAssertEqual(DBusValue.double(1).signature, "d")
        XCTAssertEqual(DBusValue.string("a").signature, "s")
        XCTAssertEqual(DBusValue.objectPath("/a").signature, "o")
        XCTAssertEqual(DBusValue.signature("s").signature, "g")
    }

    /// The element type is carried on the case rather than derived from the
    /// contents, so an empty array still declares what it would have held.
    func testAnEmptyArrayKeepsItsElementSignature() {
        XCTAssertEqual(DBusValue.array(element: "{sv}", values: []).signature, "a{sv}")
        XCTAssertEqual(DBusValue.strings([]).signature, "as")
        XCTAssertEqual(DBusValue.bytes([]).signature, "ay")
        XCTAssertEqual(DBusValue.array(element: "(iiay)", values: []).signature, "a(iiay)")
    }

    func testStructAndDictEntrySignaturesNest() {
        let pixmap = DBusValue.struct([.int32(2), .int32(2), .bytes([0, 1, 2, 3])])
        XCTAssertEqual(pixmap.signature, "(iiay)")
        XCTAssertEqual(DBusValue.dictEntry(key: .string("k"), value: .variant(.boolean(true))).signature,
                       "{sv}")
    }

    /// A variant's signature is `v` however deep its payload: the inner
    /// signature travels inside the variant on the wire, not in the outer one.
    func testVariantSignatureHidesItsPayload() {
        XCTAssertEqual(DBusValue.variant(.string("x")).signature, "v")
        XCTAssertEqual(DBusValue.variant(.array(element: "(iiay)", values: [])).signature, "v")
    }

    func testWellFormedAcceptsAMatchingArray() {
        XCTAssertTrue(DBusValue.strings(["a", "b"]).isWellFormed)
        XCTAssertTrue(DBusValue.dictionary(["a": .string("b")]).isWellFormed)
    }

    /// The check that matters: D-Bus answers a malformed message by dropping the
    /// connection, so a mismatch would show up as the tray icon vanishing.
    func testWellFormedRejectsAnElementThatIsNotTheDeclaredType() {
        let mixed = DBusValue.array(element: "s", values: [.string("a"), .int32(1)])
        XCTAssertFalse(mixed.isWellFormed)
    }

    func testWellFormedRejectsAMismatchNestedInsideAStruct() {
        let inner = DBusValue.array(element: "y", values: [.string("not a byte")])
        XCTAssertFalse(DBusValue.struct([.int32(1), inner]).isWellFormed)
    }

    /// An empty struct has no signature D-Bus can express, so `()` must not pass.
    func testWellFormedRejectsAnEmptyStruct() {
        XCTAssertFalse(DBusValue.struct([]).isWellFormed)
    }

    func testWellFormedRejectsANonBasicDictionaryKey() {
        let entry = DBusValue.dictEntry(key: .strings(["k"]), value: .variant(.boolean(true)))
        XCTAssertFalse(entry.isWellFormed)
    }

    func testWellFormedLooksInsideAVariant() {
        let bad = DBusValue.variant(.array(element: "s", values: [.int32(1)]))
        XCTAssertFalse(bad.isWellFormed)
    }

    func testIsBasicSeparatesKeysFromContainers() {
        XCTAssertTrue(DBusValue.string("a").isBasic)
        XCTAssertTrue(DBusValue.byte(0).isBasic)
        XCTAssertFalse(DBusValue.strings([]).isBasic)
        XCTAssertFalse(DBusValue.struct([.int32(1)]).isBasic)
        XCTAssertFalse(DBusValue.variant(.int32(1)).isBasic)
        XCTAssertFalse(DBusValue.dictEntry(key: .string("k"), value: .int32(1)).isBasic)
    }

    /// Sorted so an unchanged state produces an identical message, which is what
    /// lets a test assert on a value instead of on a set.
    func testDictionaryOrdersItsKeys() {
        let dictionary = DBusValue.dictionary([
            "Zulu": .string("z"), "Alpha": .string("a"), "Mike": .string("m"),
        ])
        guard case .array(let element, let entries) = dictionary else {
            return XCTFail("expected an array of dict entries")
        }
        XCTAssertEqual(element, "{sv}")
        let keys: [String] = entries.compactMap { entry in
            guard case .dictEntry(let key, _) = entry, case .string(let name) = key else { return nil }
            return name
        }
        XCTAssertEqual(keys, ["Alpha", "Mike", "Zulu"])
    }

    func testDictionaryWrapsEveryValueInAVariant() {
        let dictionary = DBusValue.dictionary(["n": .int32(7)])
        guard case .array(_, let entries) = dictionary,
              case .dictEntry(_, let value) = entries.first else {
            return XCTFail("expected one dict entry")
        }
        XCTAssertEqual(value, .variant(.int32(7)))
        XCTAssertEqual(dictionary.signature, "a{sv}")
    }

    func testBytesRoundTripInOrder() {
        XCTAssertEqual(DBusValue.bytes([9, 8, 7]),
                       .array(element: "y", values: [.byte(9), .byte(8), .byte(7)]))
    }
}
