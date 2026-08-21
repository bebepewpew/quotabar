import Foundation
import QuotaCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The only part of the D-Bus client that touches the kernel.
///
/// Everything above it — the handshake, the framing, the service — runs against
/// `DBusChannel`, so this stays small enough to read in one sitting. That is
/// deliberate: it is the one piece the test suite cannot drive.
/// `@unchecked Sendable` because the only mutable state is the descriptor, and
/// every access to it — including `close` — is inside `lock`. That is what lets
/// the service read on one thread while a refresh writes on another.
public final class UnixSocketChannel: DBusChannel, @unchecked Sendable {
    private var descriptor: Int32
    private let lock = NSLock()

    /// Connects to a session bus socket.
    public init(address: DBusAddress) throws {
        // A write to a socket whose peer has gone raises SIGPIPE, which kills
        // the process by default. The tray must fail the write and report it
        // instead — the same hazard the probes have.
        ProcessSignals.ignoreBrokenPipe()

        descriptor = socket(AF_UNIX, socketStreamType, 0)
        guard descriptor >= 0 else {
            throw DBusConnectionError.connectFailed("socket: \(errorText())")
        }

        var raw = sockaddr_un()
        raw.sun_family = sa_family_t(AF_UNIX)
        let name: String
        let abstract: Bool
        switch address {
        case .path(let path): name = path; abstract = false
        case .abstract(let path): name = path; abstract = true
        }

        // sun_path is a fixed C array, and an abstract socket's name starts with
        // a NUL rather than being NUL-terminated — so the bytes are placed by
        // hand instead of with strcpy.
        let bytes = Array(name.utf8)
        let capacity = MemoryLayout.size(ofValue: raw.sun_path)
        // One spare byte either way: the leading NUL for an abstract name, the
        // trailing NUL for a filesystem path.
        guard bytes.count + 1 <= capacity else {
            close()
            throw DBusConnectionError.unsupportedAddress("socket path is too long: \(name)")
        }
        withUnsafeMutablePointer(to: &raw.sun_path) { field in
            field.withMemoryRebound(to: UInt8.self, capacity: capacity) { buffer in
                var index = 0
                if abstract {
                    buffer[0] = 0
                    index = 1
                }
                for byte in bytes {
                    buffer[index] = byte
                    index += 1
                }
                if !abstract { buffer[index] = 0 }
            }
        }
        // An abstract socket's length must cover exactly the leading NUL and the
        // name; padding it to the full struct would address a different socket.
        let length = socklen_t(MemoryLayout<sockaddr_un>.size(ofValue: raw)
            - capacity + bytes.count + 1)

        let connected = withUnsafePointer(to: &raw) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(descriptor, generic, length)
            }
        }
        guard connected == 0 else {
            let reason = errorText()
            close()
            throw DBusConnectionError.connectFailed("connect \(name): \(reason)")
        }
    }

    /// Resolves the bus from the environment, the way every D-Bus client does.
    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let value = environment["DBUS_SESSION_BUS_ADDRESS"], !value.isEmpty else {
            throw DBusConnectionError.unsupportedAddress(
                "DBUS_SESSION_BUS_ADDRESS is not set; there is no session bus to join")
        }
        guard let address = DBusAddress.parse(value) else {
            throw DBusConnectionError.unsupportedAddress(value)
        }
        try self.init(address: address)
    }

    deinit { close() }

    public func write(_ bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw DBusConnectionError.disconnected }
        var offset = 0
        try bytes.withUnsafeBytes { buffer in
            while offset < buffer.count {
                // A short write is normal on a stream socket, not an error.
                let written = send(descriptor, buffer.baseAddress! + offset,
                                   buffer.count - offset, 0)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                throw DBusConnectionError.connectFailed("write: \(errorText())")
            }
        }
    }

    public func read(upTo count: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw DBusConnectionError.disconnected }
        var buffer = [UInt8](repeating: 0, count: max(1, count))
        while true {
            let received = buffer.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if received > 0 { return Array(buffer[0..<received]) }
            // Zero is an orderly shutdown by the peer.
            if received == 0 { return [] }
            if errno == EINTR { continue }
            throw DBusConnectionError.connectFailed("read: \(errorText())")
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        #if canImport(Glibc)
        _ = Glibc.close(descriptor)
        #else
        _ = Darwin.close(descriptor)
        #endif
        descriptor = -1
    }
}

/// `SOCK_STREAM` is an enum on Linux and an Int32 on Darwin, so it needs one
/// conversion rather than a cast at every use.
private var socketStreamType: Int32 {
    #if canImport(Glibc)
    return Int32(SOCK_STREAM.rawValue)
    #else
    return SOCK_STREAM
    #endif
}

private func errorText() -> String {
    String(cString: strerror(errno))
}
