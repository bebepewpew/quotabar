import Foundation

/// One D-Bus message: a fixed twelve-byte prologue, an array of header fields,
/// then the body.
///
/// Kept separate from the transport so a message can be built and asserted on
/// without a socket, which is what makes the service logic testable.
public struct DBusMessage: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case methodCall = 1, methodReturn = 2, error = 3, signal = 4
    }

    /// Header field codes from the specification. Only the ones this speaks.
    public enum Field: UInt8, Sendable {
        case path = 1, interface = 2, member = 3, errorName = 4
        case replySerial = 5, destination = 6, sender = 7, signature = 8
    }

    /// Set on a method call that wants no reply. The bus still routes it, but a
    /// well-behaved peer will not send a method return.
    public static let noReplyExpected: UInt8 = 0x1

    public var kind: Kind
    public var flags: UInt8
    public var serial: UInt32
    public var path: String?
    public var interface: String?
    public var member: String?
    public var errorName: String?
    public var replySerial: UInt32?
    public var destination: String?
    public var sender: String?
    public var body: [DBusValue]

    public init(kind: Kind, flags: UInt8 = 0, serial: UInt32 = 0,
                path: String? = nil, interface: String? = nil, member: String? = nil,
                errorName: String? = nil, replySerial: UInt32? = nil,
                destination: String? = nil, sender: String? = nil,
                body: [DBusValue] = []) {
        self.kind = kind
        self.flags = flags
        self.serial = serial
        self.path = path
        self.interface = interface
        self.member = member
        self.errorName = errorName
        self.replySerial = replySerial
        self.destination = destination
        self.sender = sender
        self.body = body
    }

    /// The concatenated signature of the body, which is what the SIGNATURE
    /// header field carries. Empty when there is no body, in which case the
    /// field is omitted entirely rather than sent as an empty string.
    public var bodySignature: String {
        body.map(\.signature).joined()
    }
}

public extension DBusMessage {
    /// Length of the fixed prologue: endianness, type, flags, version, body
    /// length, serial. The header field array starts immediately after.
    static let prologueLength = 12
    /// The specification's ceiling on a whole message, 128 MiB.
    static let maximumLength = 134_217_728

    /// Serialises the message.
    ///
    /// Everything is offset from byte zero, including the body, because D-Bus
    /// alignment is measured from the start of the message. Building the body
    /// separately and concatenating it is the mistake this signature prevents:
    /// `encode` writes into one buffer throughout.
    func encoded(littleEndian: Bool = true) throws -> [UInt8] {
        var bytes = [UInt8]()
        bytes.append(littleEndian ? 0x6C : 0x42)   // 'l' or 'B'
        bytes.append(kind.rawValue)
        bytes.append(flags)
        bytes.append(1)                            // protocol version
        // Body length is not known yet; reserve and patch once measured.
        let bodyLengthOffset = bytes.count
        appendUInt32(0, to: &bytes, littleEndian: littleEndian)
        appendUInt32(serial, to: &bytes, littleEndian: littleEndian)

        try DBusWire.encode(headerFields(), into: &bytes, littleEndian: littleEndian)
        // The body always starts on an 8-byte boundary, and this padding is
        // counted in neither the header array's length nor the body's.
        DBusWire.pad(&bytes, to: 8)

        let bodyStart = bytes.count
        for value in body {
            try DBusWire.encode(value, into: &bytes, littleEndian: littleEndian)
        }
        let bodyLength = bytes.count - bodyStart
        guard bytes.count <= Self.maximumLength else {
            throw DBusWireError.invalidPayload("message exceeds 128 MiB")
        }
        patchUInt32(UInt32(bodyLength), at: bodyLengthOffset, in: &bytes, littleEndian: littleEndian)
        return bytes
    }

    /// `a(yv)` — the header fields that are actually set.
    ///
    /// An unset field is omitted rather than sent empty: the bus reads a present
    /// REPLY_SERIAL of 0 as a reply to serial 0, not as "no reply serial".
    private func headerFields() -> DBusValue {
        var entries = [DBusValue]()
        func add(_ field: Field, _ value: DBusValue) {
            entries.append(.struct([.byte(field.rawValue), .variant(value)]))
        }
        if let path { add(.path, .objectPath(path)) }
        if let interface { add(.interface, .string(interface)) }
        if let member { add(.member, .string(member)) }
        if let errorName { add(.errorName, .string(errorName)) }
        if let replySerial { add(.replySerial, .uint32(replySerial)) }
        if let destination { add(.destination, .string(destination)) }
        if let sender { add(.sender, .string(sender)) }
        let signature = bodySignature
        if !signature.isEmpty { add(.signature, .signature(signature)) }
        return .array(element: "(yv)", values: entries)
    }

    /// Total length of the message beginning at `bytes`, or nil if the prologue
    /// and header array are not fully present yet.
    ///
    /// The transport needs this to know how much to read before it can parse:
    /// a stream gives no framing, so the length has to come out of the header.
    static func length(of bytes: [UInt8]) throws -> Int? {
        guard bytes.count >= prologueLength + 4 else { return nil }
        let littleEndian = try byteOrder(of: bytes)
        let bodyLength = readUInt32(bytes, at: 4, littleEndian: littleEndian)
        let fieldsLength = readUInt32(bytes, at: prologueLength, littleEndian: littleEndian)
        guard bodyLength <= maximumLength, fieldsLength <= maximumLength else {
            throw DBusWireError.invalidPayload("header claims an impossible length")
        }
        // Fixed prologue, the 4-byte array length, the fields, padding to 8,
        // then the body.
        let headerEnd = prologueLength + 4 + Int(fieldsLength)
        let bodyStart = headerEnd + ((8 - headerEnd % 8) % 8)
        let total = bodyStart + Int(bodyLength)
        guard total <= maximumLength else {
            throw DBusWireError.invalidPayload("message exceeds 128 MiB")
        }
        return total
    }

    /// Parses one complete message. `bytes` must hold exactly it, as `length(of:)`
    /// measured.
    static func decode(_ bytes: [UInt8]) throws -> DBusMessage {
        guard bytes.count >= prologueLength else { throw DBusWireError.truncated }
        let littleEndian = try byteOrder(of: bytes)
        guard let kind = Kind(rawValue: bytes[1]) else {
            // Types beyond the four are reserved. Rejecting is right: a message
            // we cannot classify is one we cannot safely reply to.
            throw DBusWireError.invalidPayload("unknown message type \(bytes[1])")
        }
        guard bytes[3] == 1 else {
            throw DBusWireError.invalidPayload("protocol version \(bytes[3])")
        }
        let bodyLength = Int(readUInt32(bytes, at: 4, littleEndian: littleEndian))
        var message = DBusMessage(kind: kind, flags: bytes[2],
                                  serial: readUInt32(bytes, at: 8, littleEndian: littleEndian))

        var offset = prologueLength
        let fields = try DBusWire.decode(signature: "a(yv)", from: bytes, offset: &offset,
                                         littleEndian: littleEndian)
        var signature = ""
        if case .array(_, let entries) = fields {
            for entry in entries {
                guard case .struct(let pair) = entry, pair.count == 2,
                      case .byte(let code) = pair[0], case .variant(let value) = pair[1],
                      let field = Field(rawValue: code) else { continue }
                switch (field, value) {
                case (.path, .objectPath(let v)): message.path = v
                case (.interface, .string(let v)): message.interface = v
                case (.member, .string(let v)): message.member = v
                case (.errorName, .string(let v)): message.errorName = v
                case (.replySerial, .uint32(let v)): message.replySerial = v
                case (.destination, .string(let v)): message.destination = v
                case (.sender, .string(let v)): message.sender = v
                case (.signature, .signature(let v)): signature = v
                default:
                    // A field carrying the wrong type is malformed, not a field
                    // we can helpfully ignore.
                    throw DBusWireError.invalidPayload("header field \(code) has type \(value.signature)")
                }
            }
        }

        // Skip to the 8-aligned body start.
        offset += (8 - offset % 8) % 8
        guard offset + bodyLength <= bytes.count else { throw DBusWireError.truncated }
        if !signature.isEmpty {
            guard let types = DBusSignature.split(signature) else {
                throw DBusWireError.malformedSignature(signature)
            }
            for type in types {
                message.body.append(try DBusWire.decode(signature: type, from: bytes,
                                                        offset: &offset,
                                                        littleEndian: littleEndian))
            }
        }
        return message
    }

    private static func byteOrder(of bytes: [UInt8]) throws -> Bool {
        switch bytes[0] {
        case 0x6C: return true   // 'l'
        case 0x42: return false  // 'B'
        default: throw DBusWireError.invalidPayload("byte order flag \(bytes[0])")
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int, littleEndian: Bool) -> UInt32 {
        var raw: UInt32 = 0
        withUnsafeMutableBytes(of: &raw) { buffer in
            for index in 0..<4 { buffer[index] = bytes[offset + index] }
        }
        return littleEndian ? UInt32(littleEndian: raw) : UInt32(bigEndian: raw)
    }
}

private func appendUInt32(_ value: UInt32, to bytes: inout [UInt8], littleEndian: Bool) {
    let raw = littleEndian ? value.littleEndian : value.bigEndian
    withUnsafeBytes(of: raw) { bytes.append(contentsOf: $0) }
}

private func patchUInt32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8],
                         littleEndian: Bool) {
    let raw = littleEndian ? value.littleEndian : value.bigEndian
    withUnsafeBytes(of: raw) { buffer in
        for (index, byte) in buffer.enumerated() { bytes[offset + index] = byte }
    }
}
