import Foundation

/// A framed message connection over a `DBusChannel`.
///
/// A stream carries no framing, so every message has to be measured out of its
/// own header before it can be parsed. That buffering — and the serial
/// bookkeeping, and matching a reply to its call — is ordinary logic and is
/// tested against a buffer rather than a bus.
public final class DBusConnection {
    private let channel: DBusChannel
    private var inbox = [UInt8]()
    private var nextSerial: UInt32 = 1

    /// The unique name the bus assigned, e.g. `:1.42`. Nil until `hello()`.
    public private(set) var uniqueName: String?

    public init(channel: DBusChannel) {
        self.channel = channel
    }

    /// Authenticates and asks the bus for a unique name.
    ///
    /// `Hello` is mandatory: the bus refuses to route anything else until a
    /// client has called it.
    public func connect(uid: UInt32) throws {
        try DBusAuth.authenticate(over: channel, uid: uid)
        let reply = try call(destination: "org.freedesktop.DBus",
                             path: "/org/freedesktop/DBus",
                             interface: "org.freedesktop.DBus",
                             member: "Hello")
        guard case .string(let name)? = reply.body.first else {
            throw DBusConnectionError.authenticationFailed("Hello returned no name")
        }
        uniqueName = name
    }

    /// Sends a message, assigning it the next serial.
    @discardableResult
    public func send(_ message: DBusMessage) throws -> UInt32 {
        var outgoing = message
        outgoing.serial = nextSerial
        // Serials must be non-zero, so wrap to 1 rather than to 0.
        nextSerial = nextSerial == UInt32.max ? 1 : nextSerial + 1
        try channel.write(try outgoing.encoded())
        return outgoing.serial
    }

    /// Sends a method call and reads until its reply arrives.
    ///
    /// Signals and unrelated calls that arrive first are handed to `interleaved`
    /// rather than dropped: the bus may deliver a `NameOwnerChanged` between a
    /// call and its return, and discarding it would lose the tray's registration.
    @discardableResult
    public func call(destination: String, path: String, interface: String, member: String,
                     body: [DBusValue] = [],
                     interleaved: (DBusMessage) throws -> Void = { _ in }) throws -> DBusMessage {
        let serial = try send(DBusMessage(kind: .methodCall, path: path, interface: interface,
                                          member: member, destination: destination, body: body))
        while true {
            let message = try receive()
            if message.replySerial == serial {
                if message.kind == .error {
                    throw DBusConnectionError.remote(name: message.errorName ?? "unknown",
                                                     message: message.body.first.flatMap {
                                                         if case .string(let text) = $0 { return text }
                                                         return nil
                                                     } ?? "")
                }
                return message
            }
            try interleaved(message)
        }
    }

    /// Blocks until one whole message has been read.
    public func receive() throws -> DBusMessage {
        while true {
            if let length = try DBusMessage.length(of: inbox), inbox.count >= length {
                let frame = Array(inbox[0..<length])
                inbox.removeFirst(length)
                return try DBusMessage.decode(frame)
            }
            let chunk = try channel.read(upTo: 65_536)
            guard !chunk.isEmpty else { throw DBusConnectionError.disconnected }
            inbox.append(contentsOf: chunk)
        }
    }

    /// Reads a message if one is already buffered or immediately available,
    /// without blocking for a whole one to arrive.
    ///
    /// Used by the service loop so a refresh timer is not held up by a quiet bus.
    public func receiveBuffered() throws -> DBusMessage? {
        guard let length = try DBusMessage.length(of: inbox), inbox.count >= length else {
            return nil
        }
        let frame = Array(inbox[0..<length])
        inbox.removeFirst(length)
        return try DBusMessage.decode(frame)
    }

    /// Adds bytes that were read elsewhere, e.g. by a poll loop.
    public func feed(_ bytes: [UInt8]) {
        inbox.append(contentsOf: bytes)
    }

    public func close() {
        channel.close()
    }
}
