import Foundation

/// A framed message connection over a `DBusChannel`.
///
/// A stream carries no framing, so every message has to be measured out of its
/// own header before it can be parsed. That buffering — and the serial
/// bookkeeping, and matching a reply to its call — is ordinary logic and is
/// tested against a buffer rather than a bus.
/// `@unchecked Sendable`: every mutable field is behind `lock`.
///
/// The tray needs this. Its refresh runs on another thread so a slow probe
/// cannot stop it answering the bus, and that thread emits change signals while
/// the serving loop is sending replies — so two threads call `send` at once. An
/// unguarded serial counter would hand two messages the same number, and a reply
/// matched by serial would then be matched to the wrong call.
public final class DBusConnection: @unchecked Sendable {
    private let channel: DBusChannel
    private let lock = NSLock()
    private var inbox = [UInt8]()
    private var nextSerial: UInt32 = 1

    /// The unique name the bus assigned, e.g. `:1.42`. Nil until `connect`.
    public var uniqueName: String? {
        lock.lock(); defer { lock.unlock() }
        return storedUniqueName
    }
    private var storedUniqueName: String?

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
        lock.lock()
        storedUniqueName = name
        lock.unlock()
    }

    /// Sends a message, assigning it the next serial.
    @discardableResult
    public func send(_ message: DBusMessage) throws -> UInt32 {
        lock.lock()
        var outgoing = message
        outgoing.serial = nextSerial
        // Serials must be non-zero, so wrap to 1 rather than to 0.
        nextSerial = nextSerial == UInt32.max ? 1 : nextSerial + 1
        lock.unlock()
        // Encoded and written outside the lock, but written in ONE call: the
        // channel writes a whole buffer under its own lock, so two concurrent
        // messages cannot interleave their bytes on the stream.
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
            // Not `try?`: swallowing a framing or parse error turns a protocol
            // fault into a stall that later surfaces as a read timeout, pointing
            // at the peer rather than at the real reason.
            let buffered: DBusMessage?
            lock.lock()
            do {
                buffered = try takeBufferedLocked()
            } catch {
                lock.unlock()
                throw error
            }
            lock.unlock()
            if let message = buffered { return message }

            let chunk = try channel.read(upTo: 65_536)
            guard !chunk.isEmpty else { throw DBusConnectionError.disconnected }
            lock.lock()
            inbox.append(contentsOf: chunk)
            lock.unlock()
        }
    }

    /// Reads a message if one is already buffered or immediately available,
    /// without blocking for a whole one to arrive.
    ///
    /// Used by the service loop so a refresh timer is not held up by a quiet bus.
    public func receiveBuffered() throws -> DBusMessage? {
        lock.lock(); defer { lock.unlock() }
        return try takeBufferedLocked()
    }

    private func takeBufferedLocked() throws -> DBusMessage? {
        guard let length = try DBusMessage.length(of: inbox), inbox.count >= length else {
            return nil
        }
        let frame = Array(inbox[0..<length])
        inbox.removeFirst(length)
        return try DBusMessage.decode(frame)
    }

    /// Adds bytes that were read elsewhere, e.g. by a poll loop.
    public func feed(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        inbox.append(contentsOf: bytes)
    }

    /// Reads once from the channel into the buffer.
    ///
    /// This is how a service loop waits: the channel's own deadline turns a
    /// quiet bus into a timer tick, so the loop can fire a scheduled refresh
    /// without a second thread polling the socket. Returns false when the read
    /// timed out — not a failure, just nothing to do.
    @discardableResult
    public func pump() throws -> Bool {
        do {
            let chunk = try channel.read(upTo: 65_536)
            guard !chunk.isEmpty else { throw DBusConnectionError.disconnected }
            lock.lock()
            inbox.append(contentsOf: chunk)
            lock.unlock()
            return true
        } catch DBusConnectionError.connectFailed(let reason) where reason == "read timed out" {
            return false
        }
    }

    public func close() {
        channel.close()
    }
}
