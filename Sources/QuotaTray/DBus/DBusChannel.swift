import Foundation

/// A bidirectional byte stream to the bus.
///
/// The socket is behind this so the handshake, the framing and the whole service
/// can be driven from a buffer in tests. Everything above this protocol is
/// ordinary logic; only `UnixSocketChannel` touches the kernel.
public protocol DBusChannel: AnyObject {
    /// Writes every byte, or throws.
    func write(_ bytes: [UInt8]) throws
    /// Reads at least one byte, up to `count`. An empty result means the peer
    /// closed the connection.
    func read(upTo count: Int) throws -> [UInt8]
    func close()
}

public enum DBusConnectionError: Error, Equatable {
    /// `DBUS_SESSION_BUS_ADDRESS` is absent or names no transport this supports.
    case unsupportedAddress(String)
    case connectFailed(String)
    case authenticationFailed(String)
    /// The peer closed the connection.
    case disconnected
    /// The bus answered a call with an error.
    case remote(name: String, message: String)
}

/// Parsing `DBUS_SESSION_BUS_ADDRESS`.
///
/// The variable is a semicolon-separated list of candidate transports, each with
/// comma-separated key=value pairs, and values are escaped percent-style. Only
/// the two unix forms are supported: `tcp:` exists in the spec but a session bus
/// reachable over TCP is not something the tray should quietly connect to.
public enum DBusAddress: Equatable, Sendable {
    /// A socket in the filesystem — what systemd user sessions use.
    case path(String)
    /// A Linux abstract socket, which has no filesystem entry.
    case abstract(String)

    /// Picks the first supported transport in the address list.
    public static func parse(_ address: String) -> DBusAddress? {
        for candidate in address.split(separator: ";", omittingEmptySubsequences: true) {
            guard let transport = candidate.split(separator: ":", maxSplits: 1).first,
                  transport == "unix" else { continue }
            let rest = candidate.dropFirst(transport.count + 1)
            var fields = [String: String]()
            for pair in rest.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                fields[String(parts[0])] = unescape(String(parts[1]))
            }
            // `path` wins when both are present; it is the form that works
            // outside Linux and the one a systemd session provides.
            if let path = fields["path"] { return .path(path) }
            if let abstract = fields["abstract"] { return .abstract(abstract) }
        }
        return nil
    }

    /// Undoes the address escaping: `%` followed by two hex digits.
    static func unescape(_ value: String) -> String {
        var output = [UInt8]()
        let characters = Array(value.utf8)
        var index = 0
        while index < characters.count {
            if characters[index] == UInt8(ascii: "%"), index + 2 < characters.count,
               let high = hexValue(characters[index + 1]), let low = hexValue(characters[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// The SASL handshake a D-Bus client performs before any message.
///
/// It is line-based ASCII, and then the stream turns binary at `BEGIN`. That
/// switch is why the lines are read one byte at a time: reading ahead into a
/// buffer would swallow the first bytes of the first message.
public enum DBusAuth {
    /// EXTERNAL means "the kernel already told you who I am" — the peer credential
    /// on the unix socket. No secret is sent, and QuotaBar reads no cookie file,
    /// which keeps it consistent with never touching credentials.
    public static func authenticate(over channel: DBusChannel, uid: UInt32) throws {
        // A single NUL first. The byte is not part of SASL; it is what tells the
        // server a client is starting on this socket.
        try channel.write([0])

        let identity = Array(String(uid).utf8)
            .map { String(format: "%02x", $0) }
            .joined()
        try send("AUTH EXTERNAL \(identity)", over: channel)

        let response = try readLine(from: channel)
        guard response.hasPrefix("OK") else {
            // REJECTED lists the mechanisms the server would accept. Reporting it
            // verbatim is the difference between a diagnosable failure and "the
            // tray did not start".
            throw DBusConnectionError.authenticationFailed(response)
        }
        try send("BEGIN", over: channel)
    }

    static func send(_ line: String, over channel: DBusChannel) throws {
        try channel.write(Array((line + "\r\n").utf8))
    }

    /// Reads one CRLF-terminated line, a byte at a time.
    static func readLine(from channel: DBusChannel, limit: Int = 8192) throws -> String {
        var bytes = [UInt8]()
        while bytes.count < limit {
            let chunk = try channel.read(upTo: 1)
            guard let byte = chunk.first else { throw DBusConnectionError.disconnected }
            if byte == UInt8(ascii: "\n") {
                if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
        }
        // A server that never terminates a line would otherwise hold the tray
        // open forever.
        throw DBusConnectionError.authenticationFailed("no line terminator within \(limit) bytes")
    }
}
