import XCTest
import Foundation
@testable import QuotaTray

/// A `DBusChannel` backed by buffers, so the handshake and the framing can be
/// driven exactly — including the partial reads a real socket produces and a
/// test against a live bus would never reliably reproduce.
final class MemoryChannel: DBusChannel {
    private(set) var written = [UInt8]()
    private var toRead: [UInt8]
    private(set) var closed = false
    /// Caps each read so a caller that assumes it gets everything at once fails.
    var readChunk = Int.max

    init(toRead: [UInt8] = []) {
        self.toRead = toRead
    }

    func queue(_ bytes: [UInt8]) { toRead.append(contentsOf: bytes) }

    func write(_ bytes: [UInt8]) throws { written.append(contentsOf: bytes) }

    func read(upTo count: Int) throws -> [UInt8] {
        let limit = min(count, readChunk, toRead.count)
        guard limit > 0 else { return [] }
        defer { toRead.removeFirst(limit) }
        return Array(toRead[0..<limit])
    }

    func close() { closed = true }

    var writtenText: String { String(decoding: written, as: UTF8.self) }
}

final class DBusAddressTests: XCTestCase {
    func testParsesTheFilesystemSocketFormSystemdProvides() {
        XCTAssertEqual(DBusAddress.parse("unix:path=/run/user/1000/bus"),
                       .path("/run/user/1000/bus"))
    }

    func testParsesAnAbstractSocket() {
        XCTAssertEqual(DBusAddress.parse("unix:abstract=/tmp/dbus-Abc123,guid=deadbeef"),
                       .abstract("/tmp/dbus-Abc123"))
    }

    func testPrefersPathWhenBothArePresent() {
        XCTAssertEqual(DBusAddress.parse("unix:abstract=/a,path=/b"), .path("/b"))
    }

    func testTakesTheFirstSupportedTransportFromAList() {
        XCTAssertEqual(DBusAddress.parse("tcp:host=localhost,port=1;unix:path=/run/bus"),
                       .path("/run/bus"))
    }

    /// A session bus reachable over TCP is not something the tray should quietly
    /// connect to, so an address offering only that is unsupported.
    func testRejectsAnAddressWithNoUnixTransport() {
        XCTAssertNil(DBusAddress.parse("tcp:host=localhost,port=12345"))
        XCTAssertNil(DBusAddress.parse(""))
        XCTAssertNil(DBusAddress.parse("nonsense"))
    }

    func testUnescapesPercentEncodedValues() {
        XCTAssertEqual(DBusAddress.parse("unix:path=/run/a%20b/bus"), .path("/run/a b/bus"))
        XCTAssertEqual(DBusAddress.unescape("%2Ftmp"), "/tmp")
        // A stray percent that is not a valid escape is left alone rather than
        // swallowing the bytes after it.
        XCTAssertEqual(DBusAddress.unescape("100%"), "100%")
        XCTAssertEqual(DBusAddress.unescape("%zz"), "%zz")
    }
}

final class DBusAuthTests: XCTestCase {
    /// The NUL is not part of SASL; it is what tells the server a client is
    /// starting on this socket. Without it the server never answers.
    func testHandshakeSendsTheNulThenExternalThenBegin() throws {
        let channel = MemoryChannel(toRead: Array("OK 1234deadbeef\r\n".utf8))
        try DBusAuth.authenticate(over: channel, uid: 1000)

        XCTAssertEqual(channel.written.first, 0)
        let text = String(decoding: channel.written.dropFirst(), as: UTF8.self)
        // "1000" as hex-encoded ASCII.
        XCTAssertEqual(text, "AUTH EXTERNAL 31303030\r\nBEGIN\r\n")
    }

    func testIdentityIsTheHexOfTheUidsDigits() throws {
        let channel = MemoryChannel(toRead: Array("OK x\r\n".utf8))
        try DBusAuth.authenticate(over: channel, uid: 0)
        XCTAssertTrue(channel.writtenText.contains("AUTH EXTERNAL 30\r\n"))
    }

    /// REJECTED lists the mechanisms the server would accept; reporting it
    /// verbatim is the difference between a diagnosable failure and "the tray
    /// did not start".
    func testRejectionIsReportedVerbatim() {
        let channel = MemoryChannel(toRead: Array("REJECTED EXTERNAL DBUS_COOKIE_SHA1\r\n".utf8))
        XCTAssertThrowsError(try DBusAuth.authenticate(over: channel, uid: 1000)) {
            XCTAssertEqual($0 as? DBusConnectionError,
                           .authenticationFailed("REJECTED EXTERNAL DBUS_COOKIE_SHA1"))
        }
    }

    func testAClosedSocketDuringTheHandshakeIsADisconnect() {
        let channel = MemoryChannel(toRead: [])
        XCTAssertThrowsError(try DBusAuth.authenticate(over: channel, uid: 1000)) {
            XCTAssertEqual($0 as? DBusConnectionError, .disconnected)
        }
    }

    /// A server that never terminates a line would otherwise hold the tray open
    /// forever.
    func testAnUnterminatedLineIsBounded() {
        let channel = MemoryChannel(toRead: [UInt8](repeating: UInt8(ascii: "x"), count: 100))
        XCTAssertThrowsError(try DBusAuth.readLine(from: channel, limit: 16)) {
            XCTAssertEqual($0 as? DBusConnectionError,
                           .authenticationFailed("no line terminator within 16 bytes"))
        }
    }

    func testALineTerminatedWithBareNewlineIsAccepted() throws {
        let channel = MemoryChannel(toRead: Array("OK abc\n".utf8))
        XCTAssertEqual(try DBusAuth.readLine(from: channel), "OK abc")
    }
}

final class DBusConnectionTests: XCTestCase {
    /// Builds the bytes a bus would send for a reply to `serial`.
    private func reply(to serial: UInt32, body: [DBusValue] = [],
                       kind: DBusMessage.Kind = .methodReturn,
                       errorName: String? = nil) -> [UInt8] {
        var message = DBusMessage(kind: kind, serial: 99, errorName: errorName,
                                  replySerial: serial, sender: "org.freedesktop.DBus")
        message.body = body
        return try! message.encoded()
    }

    func testHelloAssignsTheUniqueName() throws {
        let channel = MemoryChannel(toRead: Array("OK abc\r\n".utf8))
        channel.queue(reply(to: 1, body: [.string(":1.42")]))
        let connection = DBusConnection(channel: channel)
        try connection.connect(uid: 1000)
        XCTAssertEqual(connection.uniqueName, ":1.42")
    }

    func testSerialsStartAtOneAndIncrement() throws {
        let channel = MemoryChannel()
        let connection = DBusConnection(channel: channel)
        XCTAssertEqual(try connection.send(DBusMessage(kind: .signal, path: "/a")), 1)
        XCTAssertEqual(try connection.send(DBusMessage(kind: .signal, path: "/a")), 2)
    }

    /// A reply is matched by serial, so an interleaved signal must not be
    /// mistaken for one — and must not be dropped either: the bus may deliver
    /// NameOwnerChanged between a call and its return.
    func testAnInterleavedSignalIsDeliveredRatherThanDiscarded() throws {
        let channel = MemoryChannel(toRead: Array("OK abc\r\n".utf8))
        var signal = DBusMessage(kind: .signal, serial: 50, path: "/org/freedesktop/DBus",
                                 interface: "org.freedesktop.DBus", member: "NameOwnerChanged")
        signal.body = [.string("org.kde.StatusNotifierWatcher")]
        channel.queue(try signal.encoded())
        channel.queue(reply(to: 1, body: [.string(":1.7")]))

        var seen = [DBusMessage]()
        let connection = DBusConnection(channel: channel)
        try DBusAuth.authenticate(over: channel, uid: 1000)
        let result = try connection.call(destination: "org.freedesktop.DBus",
                                         path: "/org/freedesktop/DBus",
                                         interface: "org.freedesktop.DBus",
                                         member: "Hello") { seen.append($0) }
        XCTAssertEqual(result.body, [.string(":1.7")])
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.member, "NameOwnerChanged")
    }

    func testAnErrorReplyBecomesARemoteError() throws {
        let channel = MemoryChannel()
        channel.queue(reply(to: 1, body: [.string("no such name")], kind: .error,
                            errorName: "org.freedesktop.DBus.Error.ServiceUnknown"))
        let connection = DBusConnection(channel: channel)
        XCTAssertThrowsError(try connection.call(destination: "x", path: "/x",
                                                 interface: "x", member: "M")) { error in
            XCTAssertEqual(error as? DBusConnectionError,
                           .remote(name: "org.freedesktop.DBus.Error.ServiceUnknown",
                                   message: "no such name"))
        }
    }

    /// A socket delivers whatever it has, not whole messages. Reassembly is the
    /// part a live-bus test would never reliably exercise.
    func testAMessageSplitAcrossManyReadsIsReassembled() throws {
        let channel = MemoryChannel()
        channel.readChunk = 3
        var message = DBusMessage(kind: .signal, serial: 4, path: "/a", interface: "i.f",
                                  member: "M")
        message.body = [.string("a longer payload to span several reads")]
        channel.queue(try message.encoded())

        let connection = DBusConnection(channel: channel)
        XCTAssertEqual(try connection.receive(), message)
    }

    func testTwoMessagesInOneReadAreBothDelivered() throws {
        let channel = MemoryChannel()
        let first = DBusMessage(kind: .signal, serial: 1, path: "/a", interface: "i.f", member: "A")
        let second = DBusMessage(kind: .signal, serial: 2, path: "/b", interface: "i.f", member: "B")
        channel.queue(try first.encoded())
        channel.queue(try second.encoded())

        let connection = DBusConnection(channel: channel)
        XCTAssertEqual(try connection.receive(), first)
        XCTAssertEqual(try connection.receive(), second)
    }

    func testAClosedSocketIsADisconnect() {
        let connection = DBusConnection(channel: MemoryChannel())
        XCTAssertThrowsError(try connection.receive()) {
            XCTAssertEqual($0 as? DBusConnectionError, .disconnected)
        }
    }

    func testBufferedReceiveDoesNotBlockOnAQuietBus() throws {
        let connection = DBusConnection(channel: MemoryChannel())
        XCTAssertNil(try connection.receiveBuffered())

        let message = DBusMessage(kind: .signal, serial: 1, path: "/a", interface: "i.f", member: "M")
        connection.feed(try message.encoded())
        XCTAssertEqual(try connection.receiveBuffered(), message)
        XCTAssertNil(try connection.receiveBuffered())
    }

    func testCloseReachesTheChannel() {
        let channel = MemoryChannel()
        DBusConnection(channel: channel).close()
        XCTAssertTrue(channel.closed)
    }
}
