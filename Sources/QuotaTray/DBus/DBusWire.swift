import Foundation

/// Errors from reading or writing the D-Bus wire format.
public enum DBusWireError: Error, Equatable {
    /// A signature that does not parse, or one the value does not match.
    case malformedSignature(String)
    /// The value handed to the encoder is not the type the signature names.
    case typeMismatch(expected: String, actual: String)
    /// The buffer ended before the value did.
    case truncated
    /// A string field that is not valid UTF-8, or an array longer than the
    /// specification's 64 MiB limit.
    case invalidPayload(String)
}

/// Marshalling to and from the D-Bus wire format.
///
/// Written out rather than bound to libdbus. QuotaBar's Linux binaries are
/// linked with `--static-swift-stdlib` and its packages declare no hard
/// dependencies, and `./quotabar` builds inside the stock `swift:6.3-noble`
/// image with no root — so a system library would have cost a published
/// toolchain image, a CI change, a package dependency and the self-contained
/// binary, to wrap a format that is a few hundred lines of arithmetic.
///
/// The arithmetic is the whole risk, so it is pure and tested byte for byte:
/// every type has a fixed alignment, and a value must be padded to it before it
/// is written. Getting a pad wrong produces a message that parses as garbage,
/// and the bus answers a malformed message by dropping the connection rather
/// than replying with an error.
public enum DBusWire {
    /// The specification's hard ceiling on one array's payload, 64 MiB. Also the
    /// bound that stops a hostile length prefix from being used to allocate.
    public static let maximumArrayBytes = 67_108_864

    // MARK: Encoding

    /// Appends `value` to `bytes`, padding to its alignment first.
    ///
    /// `bytes.count` is the offset within the *message*, which is what alignment
    /// is measured from — so a caller must not encode a body into a fresh buffer
    /// and then concatenate it after a header of unknown length.
    public static func encode(_ value: DBusValue, into bytes: inout [UInt8],
                              littleEndian: Bool = true) throws {
        pad(&bytes, to: DBusSignature.alignment(of: value.signature))
        switch value {
        case .byte(let v):
            bytes.append(v)
        case .boolean(let v):
            // Marshalled as a u32; only 0 and 1 are legal on the wire.
            append(UInt32(v ? 1 : 0), to: &bytes, littleEndian: littleEndian)
        case .int16(let v):
            append(UInt16(bitPattern: v), to: &bytes, littleEndian: littleEndian)
        case .uint16(let v):
            append(v, to: &bytes, littleEndian: littleEndian)
        case .int32(let v):
            append(UInt32(bitPattern: v), to: &bytes, littleEndian: littleEndian)
        case .uint32(let v):
            append(v, to: &bytes, littleEndian: littleEndian)
        case .int64(let v):
            append(UInt64(bitPattern: v), to: &bytes, littleEndian: littleEndian)
        case .uint64(let v):
            append(v, to: &bytes, littleEndian: littleEndian)
        case .double(let v):
            append(v.bitPattern, to: &bytes, littleEndian: littleEndian)
        case .string(let v), .objectPath(let v):
            // u32 length excluding the terminator, then the bytes, then NUL.
            let utf8 = Array(v.utf8)
            append(UInt32(utf8.count), to: &bytes, littleEndian: littleEndian)
            bytes.append(contentsOf: utf8)
            bytes.append(0)
        case .signature(let v):
            // A signature's length is one byte, not four — it can never exceed
            // 255, and using u32 here is the classic way to corrupt a message.
            let utf8 = Array(v.utf8)
            guard utf8.count <= 255 else { throw DBusWireError.invalidPayload("signature too long") }
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
            bytes.append(0)
        case .array(let element, let values):
            try encodeArray(element: element, values: values, into: &bytes, littleEndian: littleEndian)
        case .struct(let members):
            // Already padded to 8 above; members follow with their own alignment.
            for member in members {
                try encode(member, into: &bytes, littleEndian: littleEndian)
            }
        case .variant(let inner):
            try encode(.signature(inner.signature), into: &bytes, littleEndian: littleEndian)
            try encode(inner, into: &bytes, littleEndian: littleEndian)
        case .dictEntry(let key, let value):
            // Already padded to 8 above.
            try encode(key, into: &bytes, littleEndian: littleEndian)
            try encode(value, into: &bytes, littleEndian: littleEndian)
        }
    }

    /// An array is a u32 *byte* count — not an element count — followed by the
    /// elements. The count excludes the padding between the length and the first
    /// element, which is why the length has to be written after the body is
    /// measured rather than before.
    private static func encodeArray(element: String, values: [DBusValue],
                                    into bytes: inout [UInt8], littleEndian: Bool) throws {
        for value in values where value.signature != element {
            throw DBusWireError.typeMismatch(expected: element, actual: value.signature)
        }
        guard DBusSignature.split(element)?.count == 1 else {
            throw DBusWireError.malformedSignature(element)
        }

        // Reserve the length, remember where it went, then pad to the element
        // alignment — that padding is not counted.
        let lengthOffset = bytes.count
        append(UInt32(0), to: &bytes, littleEndian: littleEndian)
        pad(&bytes, to: DBusSignature.alignment(of: element))
        let payloadStart = bytes.count

        for value in values {
            try encode(value, into: &bytes, littleEndian: littleEndian)
        }

        let payloadLength = bytes.count - payloadStart
        guard payloadLength <= maximumArrayBytes else {
            throw DBusWireError.invalidPayload("array exceeds 64 MiB")
        }
        let encoded = UInt32(payloadLength)
        let raw = littleEndian ? encoded.littleEndian : encoded.bigEndian
        withUnsafeBytes(of: raw) { buffer in
            for (index, byte) in buffer.enumerated() { bytes[lengthOffset + index] = byte }
        }
    }

    // MARK: Decoding

    /// Reads one value of `signature` starting at `offset`, advancing it.
    ///
    /// `offset` is an offset into the whole message for the same reason encoding
    /// appends to the whole message: padding is measured from the message start.
    public static func decode(signature: String, from bytes: [UInt8], offset: inout Int,
                              littleEndian: Bool = true) throws -> DBusValue {
        try skipPadding(&offset, to: DBusSignature.alignment(of: signature), in: bytes)
        guard let kind = signature.first else { throw DBusWireError.malformedSignature(signature) }
        switch kind {
        case "y":
            return .byte(try take(1, from: bytes, offset: &offset)[0])
        case "b":
            let raw: UInt32 = try scalar(from: bytes, offset: &offset, littleEndian: littleEndian)
            guard raw <= 1 else { throw DBusWireError.invalidPayload("boolean is \(raw)") }
            return .boolean(raw == 1)
        case "n":
            let raw: UInt16 = try scalar(from: bytes, offset: &offset, littleEndian: littleEndian)
            return .int16(Int16(bitPattern: raw))
        case "q":
            return .uint16(try scalar(from: bytes, offset: &offset, littleEndian: littleEndian))
        case "i":
            let raw: UInt32 = try scalar(from: bytes, offset: &offset, littleEndian: littleEndian)
            return .int32(Int32(bitPattern: raw))
        case "u":
            return .uint32(try scalar(from: bytes, offset: &offset, littleEndian: littleEndian))
        case "x":
            let raw: UInt64 = try scalar(from: bytes, offset: &offset, littleEndian: littleEndian)
            return .int64(Int64(bitPattern: raw))
        case "t":
            return .uint64(try scalar(from: bytes, offset: &offset, littleEndian: littleEndian))
        case "d":
            let raw: UInt64 = try scalar(from: bytes, offset: &offset, littleEndian: littleEndian)
            return .double(Double(bitPattern: raw))
        case "s", "o":
            let length: UInt32 = try scalar(from: bytes, offset: &offset, littleEndian: littleEndian)
            let text = try string(length: Int(length), from: bytes, offset: &offset)
            return kind == "s" ? .string(text) : .objectPath(text)
        case "g":
            let length = try take(1, from: bytes, offset: &offset)[0]
            let text = try string(length: Int(length), from: bytes, offset: &offset)
            return .signature(text)
        case "a":
            return try decodeArray(signature: signature, from: bytes, offset: &offset,
                                   littleEndian: littleEndian)
        case "(":
            let inner = String(signature.dropFirst().dropLast())
            guard let members = DBusSignature.split(inner), !members.isEmpty else {
                throw DBusWireError.malformedSignature(signature)
            }
            return .struct(try members.map {
                try decode(signature: $0, from: bytes, offset: &offset, littleEndian: littleEndian)
            })
        case "{":
            let inner = String(signature.dropFirst().dropLast())
            guard let members = DBusSignature.split(inner), members.count == 2 else {
                throw DBusWireError.malformedSignature(signature)
            }
            let key = try decode(signature: members[0], from: bytes, offset: &offset,
                                 littleEndian: littleEndian)
            let value = try decode(signature: members[1], from: bytes, offset: &offset,
                                   littleEndian: littleEndian)
            return .dictEntry(key: key, value: value)
        case "v":
            guard case .signature(let inner) = try decode(signature: "g", from: bytes,
                                                          offset: &offset,
                                                          littleEndian: littleEndian) else {
                throw DBusWireError.malformedSignature("v")
            }
            guard DBusSignature.split(inner)?.count == 1 else {
                throw DBusWireError.malformedSignature(inner)
            }
            return .variant(try decode(signature: inner, from: bytes, offset: &offset,
                                       littleEndian: littleEndian))
        default:
            throw DBusWireError.malformedSignature(signature)
        }
    }

    private static func decodeArray(signature: String, from bytes: [UInt8], offset: inout Int,
                                    littleEndian: Bool) throws -> DBusValue {
        guard let element = DBusSignature.elementType(of: signature),
              DBusSignature.split(element)?.count == 1 else {
            throw DBusWireError.malformedSignature(signature)
        }
        let length: UInt32 = try scalar(from: bytes, offset: &offset, littleEndian: littleEndian)
        // Bound before trusting it: the length prefix is attacker-controlled on
        // any bus, and it decides how long the loop below runs.
        guard Int(length) <= maximumArrayBytes else {
            throw DBusWireError.invalidPayload("array claims \(length) bytes")
        }
        try skipPadding(&offset, to: DBusSignature.alignment(of: element), in: bytes)
        let end = offset + Int(length)
        guard end <= bytes.count else { throw DBusWireError.truncated }

        var values = [DBusValue]()
        while offset < end {
            values.append(try decode(signature: element, from: bytes, offset: &offset,
                                     littleEndian: littleEndian))
        }
        // A final element that read past the declared end means the payload and
        // its length disagree; trusting the length would desynchronise the rest
        // of the message.
        guard offset == end else { throw DBusWireError.invalidPayload("array overran its length") }
        return .array(element: element, values: values)
    }

    // MARK: Primitives

    /// Pads to `alignment` with zero bytes. D-Bus requires padding to *be* zero,
    /// not merely to be skipped.
    public static func pad(_ bytes: inout [UInt8], to alignment: Int) {
        guard alignment > 1 else { return }
        let remainder = bytes.count % alignment
        guard remainder != 0 else { return }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: alignment - remainder))
    }

    /// Advances past padding, rejecting a message whose padding is not zero.
    ///
    /// The specification requires the padding to be zero, and a peer that writes
    /// something else is either broken or hiding data in it.
    static func skipPadding(_ offset: inout Int, to alignment: Int, in bytes: [UInt8]) throws {
        guard alignment > 1 else { return }
        let remainder = offset % alignment
        guard remainder != 0 else { return }
        let count = alignment - remainder
        let padding = try take(count, from: bytes, offset: &offset)
        guard padding.allSatisfy({ $0 == 0 }) else {
            throw DBusWireError.invalidPayload("non-zero padding")
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8],
                                                     littleEndian: Bool) {
        let raw = littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: raw) { bytes.append(contentsOf: $0) }
    }

    private static func scalar<T: FixedWidthInteger>(from bytes: [UInt8], offset: inout Int,
                                                     littleEndian: Bool) throws -> T {
        let width = MemoryLayout<T>.size
        let slice = try take(width, from: bytes, offset: &offset)
        var raw = T.zero
        withUnsafeMutableBytes(of: &raw) { buffer in
            for (index, byte) in slice.enumerated() { buffer[index] = byte }
        }
        return littleEndian ? T(littleEndian: raw) : T(bigEndian: raw)
    }

    private static func take(_ count: Int, from bytes: [UInt8], offset: inout Int) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset + count <= bytes.count else {
            throw DBusWireError.truncated
        }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    /// Reads `length` bytes plus the NUL the format always appends.
    private static func string(length: Int, from bytes: [UInt8], offset: inout Int) throws -> String {
        let raw = try take(length, from: bytes, offset: &offset)
        let terminator = try take(1, from: bytes, offset: &offset)
        guard terminator[0] == 0 else { throw DBusWireError.invalidPayload("missing terminator") }
        guard let text = String(bytes: raw, encoding: .utf8) else {
            throw DBusWireError.invalidPayload("not UTF-8")
        }
        return text
    }
}
