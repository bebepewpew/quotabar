import XCTest
import Foundation
@testable import QuotaTray
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A listening unix socket in a temp directory.
///
/// `UnixSocketChannel` is the one piece that touches the kernel, so it is tested
/// against a real socket rather than left uncovered — nothing here needs a
/// session bus, only a peer that accepts a connection.
/// `@unchecked Sendable`: `accepted` is written once by the accept task and read
/// only after `waitForClient()` has observed the semaphore, which orders them.
private final class SocketServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private var accepted: Int32 = -1
    private let ready = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "socket-server")

    init(directory: URL) throws {
        path = directory.appendingPathComponent("sock").path
        #if canImport(Glibc)
        listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard listener >= 0 else { throw XCTSkip("cannot create a unix socket here") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // The same guard `UnixSocketChannel` has. Without it this wrote
        // `path.utf8.count + 1` bytes into a fixed C array — fine on Linux,
        // where sun_path is 108 and NSTemporaryDirectory() is "/tmp/", and an
        // out-of-bounds stack write on Darwin, where sun_path is 104 and the
        // per-user temp directory alone is 48 characters.
        guard bytes.count + 1 <= capacity else {
            throw XCTSkip("socket path does not fit sun_path here: \(path)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: UInt8.self, capacity: capacity) { buffer in
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                buffer[bytes.count] = 0
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            throw XCTSkip("cannot bind a unix socket here")
        }
        queue.async { [self] in
            accepted = accept(listener, nil, nil)
            ready.signal()
        }
    }

    /// Blocks until the client has connected.
    func waitForClient() { ready.wait() }

    func receive(_ count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let read = buffer.withUnsafeMutableBytes { recv(accepted, $0.baseAddress, $0.count, 0) }
        return read > 0 ? Array(buffer[0..<read]) : []
    }

    func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Glibc_send(accepted, $0.baseAddress!, $0.count) }
    }

    /// Closes the accepted connection, which is what makes a client read see EOF.
    func hangUp() {
        if accepted >= 0 { closeDescriptor(accepted); accepted = -1 }
    }

    deinit {
        hangUp()
        if listener >= 0 { closeDescriptor(listener) }
        unlink(path)
    }
}

private func Glibc_send(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.send(fd, pointer, count, 0)
    #else
    return Darwin.send(fd, pointer, count, 0)
    #endif
}

private func closeDescriptor(_ fd: Int32) {
    #if canImport(Glibc)
    _ = Glibc.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

final class UnixSocketChannelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Deliberately not NSTemporaryDirectory(): on macOS that is a ~48
        // character per-user path, which with a UUID leaves no room in the
        // 104-byte sun_path and would skip every test here.
        directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("qb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testConnectsToAListeningSocketAndWrites() throws {
        let server = try SocketServer(directory: directory)
        let channel = try UnixSocketChannel(address: .path(server.path))
        server.waitForClient()

        try channel.write(Array("AUTH EXTERNAL\r\n".utf8))
        XCTAssertEqual(String(decoding: server.receive(64), as: UTF8.self), "AUTH EXTERNAL\r\n")
        channel.close()
    }

    func testReadsWhatThePeerSends() throws {
        let server = try SocketServer(directory: directory)
        let channel = try UnixSocketChannel(address: .path(server.path))
        server.waitForClient()

        server.send(Array("OK deadbeef\r\n".utf8))
        XCTAssertEqual(String(decoding: try channel.read(upTo: 64), as: UTF8.self),
                       "OK deadbeef\r\n")
        channel.close()
    }

    /// The whole handshake, over a real socket rather than a buffer.
    func testTheHandshakeCompletesOverARealSocket() throws {
        let server = try SocketServer(directory: directory)
        let channel = try UnixSocketChannel(address: .path(server.path))
        server.waitForClient()

        let done = expectation(description: "authenticated")
        DispatchQueue.global().async {
            try? DBusAuth.authenticate(over: channel, uid: 4242)
            done.fulfill()
        }
        // NUL, then the AUTH line the client waits on a reply for.
        XCTAssertEqual(server.receive(1), [0])
        let request = String(decoding: server.receive(128), as: UTF8.self)
        XCTAssertEqual(request, "AUTH EXTERNAL 34323432\r\n")
        server.send(Array("OK abc\r\n".utf8))
        wait(for: [done], timeout: 5)
        XCTAssertTrue(String(decoding: server.receive(64), as: UTF8.self).contains("BEGIN"))
        channel.close()
    }

    /// Zero from `recv` is an orderly shutdown, which the channel reports as an
    /// empty read so the connection layer can call it a disconnect.
    func testAPeerHangingUpReadsAsEndOfStream() throws {
        let server = try SocketServer(directory: directory)
        let channel = try UnixSocketChannel(address: .path(server.path))
        server.waitForClient()

        server.hangUp()
        XCTAssertEqual(try channel.read(upTo: 64), [])
        channel.close()
    }

    /// A peer that accepts and then says nothing used to hold the tray forever:
    /// the handshake is bounded in bytes but was not bounded in time.
    func testAStalledPeerTimesOutRatherThanBlockingForever() throws {
        let server = try SocketServer(directory: directory)
        let channel = try UnixSocketChannel(address: .path(server.path), timeout: 0.25)
        server.waitForClient()

        let started = Date()
        XCTAssertThrowsError(try channel.read(upTo: 64)) { error in
            guard case .connectFailed(let reason)? = error as? DBusConnectionError else {
                return XCTFail("expected connectFailed, got \(error)")
            }
            XCTAssertEqual(reason, "read timed out")
        }
        // Proves it returned because of the deadline, not because the peer
        // closed: the server is still up and has sent nothing.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        channel.close()
    }

    /// A timeout must not be mistaken for the orderly hang-up that ends a
    /// connection, which reads as an empty result rather than an error.
    func testATimeoutIsDistinctFromAPeerHangingUp() throws {
        let server = try SocketServer(directory: directory)
        let channel = try UnixSocketChannel(address: .path(server.path), timeout: 0.25)
        server.waitForClient()
        server.hangUp()
        XCTAssertEqual(try channel.read(upTo: 64), [])
        channel.close()
    }

    func testConnectingToANonexistentPathFails() {
        let missing = directory.appendingPathComponent("absent").path
        XCTAssertThrowsError(try UnixSocketChannel(address: .path(missing))) { error in
            guard case .connectFailed(let reason)? = error as? DBusConnectionError else {
                return XCTFail("expected connectFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains(missing), reason)
        }
    }

    /// sun_path is a fixed C array, so an over-long name has to be refused
    /// rather than silently truncated to address a different socket.
    ///
    /// Asserted at the exact boundary, from the platform's own capacity: a name
    /// tested far past the limit would still pass with an off-by-one in the very
    /// guard that protects the array.
    func testTheLengthGuardSitsExactlyAtTheCapacityOfSunPath() {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

        // One byte spare for the terminator: allowed past the guard, and so it
        // fails later on connect instead.
        let longest = "/tmp/" + String(repeating: "a", count: capacity - 1 - 5)
        XCTAssertThrowsError(try UnixSocketChannel(address: .path(longest))) { error in
            guard case .connectFailed? = error as? DBusConnectionError else {
                return XCTFail("a name of capacity-1 should reach connect, got \(error)")
            }
        }

        // One byte longer, and there is no room for the terminator.
        let tooLong = longest + "a"
        XCTAssertThrowsError(try UnixSocketChannel(address: .path(tooLong))) { error in
            guard case .unsupportedAddress(let reason)? = error as? DBusConnectionError else {
                return XCTFail("expected unsupportedAddress, got \(error)")
            }
            XCTAssertTrue(reason.contains("too long"), reason)
        }
    }

    /// The abstract form spends the same spare byte on its leading NUL, so the
    /// boundary is identical rather than one larger.
    func testTheLengthGuardAppliesToAbstractNamesToo() {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let tooLong = String(repeating: "a", count: capacity)
        XCTAssertThrowsError(try UnixSocketChannel(address: .abstract(tooLong))) { error in
            guard case .unsupportedAddress? = error as? DBusConnectionError else {
                return XCTFail("expected unsupportedAddress, got \(error)")
            }
        }
    }

    func testWritingAfterCloseIsADisconnectRatherThanACrash() throws {
        let server = try SocketServer(directory: directory)
        let channel = try UnixSocketChannel(address: .path(server.path))
        server.waitForClient()
        channel.close()
        // Idempotent: a second close must not touch a recycled descriptor.
        channel.close()

        XCTAssertThrowsError(try channel.write([1])) {
            XCTAssertEqual($0 as? DBusConnectionError, .disconnected)
        }
        XCTAssertThrowsError(try channel.read(upTo: 1)) {
            XCTAssertEqual($0 as? DBusConnectionError, .disconnected)
        }
    }

    // MARK: Resolving the bus from the environment

    func testAMissingBusAddressSaysSoRatherThanFailingObscurely() {
        XCTAssertThrowsError(try UnixSocketChannel(environment: [:])) { error in
            guard case .unsupportedAddress(let reason)? = error as? DBusConnectionError else {
                return XCTFail("expected unsupportedAddress, got \(error)")
            }
            XCTAssertTrue(reason.contains("DBUS_SESSION_BUS_ADDRESS"), reason)
        }
    }

    func testAnEmptyBusAddressIsTreatedAsAbsent() {
        XCTAssertThrowsError(
            try UnixSocketChannel(environment: ["DBUS_SESSION_BUS_ADDRESS": ""])
        ) { error in
            // "Treated as absent" means the same error as absent, not merely
            // that something was thrown.
            guard case .unsupportedAddress(let reason)? = error as? DBusConnectionError else {
                return XCTFail("expected unsupportedAddress, got \(error)")
            }
            XCTAssertTrue(reason.contains("DBUS_SESSION_BUS_ADDRESS"), reason)
        }
    }

    func testAnUnsupportedTransportIsReportedWithItsAddress() {
        let address = "tcp:host=localhost,port=1234"
        XCTAssertThrowsError(
            try UnixSocketChannel(environment: ["DBUS_SESSION_BUS_ADDRESS": address])
        ) { error in
            XCTAssertEqual(error as? DBusConnectionError, .unsupportedAddress(address))
        }
    }

    func testTheEnvironmentPathIsTheOneConnectedTo() throws {
        let server = try SocketServer(directory: directory)
        let channel = try UnixSocketChannel(
            environment: ["DBUS_SESSION_BUS_ADDRESS": "unix:path=\(server.path)"])
        server.waitForClient()
        try channel.write([0x42])
        XCTAssertEqual(server.receive(1), [0x42])
        channel.close()
    }
}
