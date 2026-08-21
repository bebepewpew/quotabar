import Foundation

/// A D-Bus argument, and the signature that describes it.
///
/// The tray speaks StatusNotifierItem, which is a D-Bus protocol rather than a
/// toolkit API, so this models the wire types directly instead of depending on
/// GTK or libayatana-appindicator. Keeping the values here — separate from any
/// transport — is what lets the whole protocol layer be tested without a bus, a
/// display, or a Plasma session.
///
/// Only the types StatusNotifierItem and com.canonical.dbusmenu actually use are
/// modelled. There is no `UNIX_FD`: nothing in either interface passes one, and a
/// case that cannot be reached is a case that cannot be tested.
public indirect enum DBusValue: Equatable, Sendable {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)

    /// A homogeneous array. `element` is the signature of what it holds, carried
    /// explicitly because an *empty* array still has to declare its element type
    /// on the wire — `a{sv}` with no entries is not the same as `as` with none,
    /// and an empty `IconPixmap` array is a real state (no icon yet).
    case array(element: String, values: [DBusValue])

    /// A struct — `(...)` in a signature. Heterogeneous and fixed-shape.
    case `struct`([DBusValue])

    /// A variant — `v`. Carries its own signature on the wire, which is why the
    /// property dictionaries below can hold mixed types.
    case variant(DBusValue)

    /// One `{key value}` pair. Only ever legal inside an array, which is how
    /// D-Bus spells a dictionary: `a{sv}`.
    case dictEntry(key: DBusValue, value: DBusValue)

    /// The D-Bus signature of this value.
    ///
    /// A variant's signature is `v` regardless of what it wraps: the contained
    /// signature travels inside the variant on the wire, not in the outer one.
    public var signature: String {
        switch self {
        case .byte: return "y"
        case .boolean: return "b"
        case .int16: return "n"
        case .uint16: return "q"
        case .int32: return "i"
        case .uint32: return "u"
        case .int64: return "x"
        case .uint64: return "t"
        case .double: return "d"
        case .string: return "s"
        case .objectPath: return "o"
        case .signature: return "g"
        case .array(let element, _): return "a" + element
        case .struct(let members): return "(" + members.map(\.signature).joined() + ")"
        case .variant: return "v"
        case .dictEntry(let key, let value): return "{" + key.signature + value.signature + "}"
        }
    }

    /// Whether every element of an array matches the element signature it
    /// declares, recursively.
    ///
    /// D-Bus rejects a malformed message by disconnecting the sender rather than
    /// replying with an error, so a mismatch here would surface as the tray icon
    /// silently vanishing. Checking it as plain data means the bug is a failing
    /// assertion instead.
    public var isWellFormed: Bool {
        switch self {
        case .array(let element, let values):
            return values.allSatisfy { $0.signature == element && $0.isWellFormed }
        case .struct(let members):
            // An empty struct is not representable in a D-Bus signature.
            return !members.isEmpty && members.allSatisfy(\.isWellFormed)
        case .variant(let inner):
            return inner.isWellFormed
        case .dictEntry(let key, let value):
            // Keys must be basic types; `{av}` is not a legal dict entry.
            return key.isBasic && value.isWellFormed
        default:
            return true
        }
    }

    /// Whether this is a basic type — one legal as a dictionary key.
    public var isBasic: Bool {
        switch self {
        case .array, .struct, .variant, .dictEntry: return false
        default: return true
        }
    }
}

public extension DBusValue {
    /// `a{sv}` — the shape `org.freedesktop.DBus.Properties.GetAll` returns and
    /// the one dbusmenu uses for item properties.
    ///
    /// Sorted by key so a message is byte-identical for equal input. D-Bus
    /// attaches no meaning to dictionary order, but a stable one makes the tests
    /// assert on a value rather than on a set, and makes a diff of two captured
    /// messages readable.
    static func dictionary(_ entries: [String: DBusValue]) -> DBusValue {
        .array(element: "{sv}", values: entries.keys.sorted().map { key in
            .dictEntry(key: .string(key), value: .variant(entries[key]!))
        })
    }

    /// `as` — an array of strings, including when it is empty.
    static func strings(_ values: [String]) -> DBusValue {
        .array(element: "s", values: values.map { .string($0) })
    }

    /// `ay` — a byte array, the payload of one icon in `IconPixmap`.
    static func bytes(_ values: [UInt8]) -> DBusValue {
        .array(element: "y", values: values.map { .byte($0) })
    }
}
