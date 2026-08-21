import XCTest
import Foundation
@testable import QuotaTray
#if canImport(Glibc)
import Glibc
#endif

/// The tray driven end to end over a real session bus.
///
/// Everything else in this target tests a value or a function. This launches the
/// built `quotabar-tray`, acts as the StatusNotifierWatcher it registers with,
/// and talks to it over the bus — which is the only way to catch the parts that
/// only exist when the pieces are wired together: that registration actually
/// happens, that the process answers while it is probing, that a click routes,
/// and that Quit exits.
///
/// Skipped unless there is a session bus whose StatusNotifierWatcher name is
/// free. On a desktop that name belongs to Plasma, so this never disturbs a real
/// session; CI runs it under `dbus-run-session`, where the bus is empty.
final class TrayIntegrationTests: XCTestCase {
    private var watcher: WatcherStub!
    private var tray: Process!
    /// Scratch space for a staged fake provider and a private state directory.
    /// Rooted at /tmp rather than NSTemporaryDirectory() for the same reason the
    /// socket tests are: Darwin's per-user temp path is long.
    private var directory: URL!

    override func setUpWithError() throws {
        guard let address = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
              DBusAddress.parse(address) != nil else {
            throw XCTSkip("no session bus; run under dbus-run-session")
        }
        guard Self.trayBinary() != nil else {
            throw XCTSkip("quotabar-tray is not built; run `swift build --product quotabar-tray`")
        }
        directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("qb-tray-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watcher = try WatcherStub()
        guard try watcher.claimName() else {
            // Plasma already owns it. Skipping is right: hijacking the name on a
            // live desktop would take every tray icon off the panel.
            throw XCTSkip("org.kde.StatusNotifierWatcher is already owned on this bus")
        }
        watcher.serve()

        tray = try launchTray()
    }

    /// Starts `quotabar-tray` against the current bus.
    ///
    /// `extraPath` goes in front of PATH, which is how a test stages a fake
    /// provider CLI for the probes to find.
    @discardableResult
    private func launchTray(extraPath: String? = nil) throws -> Process {
        let binary = try XCTUnwrap(Self.trayBinary())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--interval", "30"]
        var environment = ProcessInfo.processInfo.environment
        if let extraPath {
            environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "")
        }
        // A private state directory, so a test never reads or writes the state
        // of the machine it runs on.
        environment["XDG_CONFIG_HOME"] = directory.appendingPathComponent("config").path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    override func tearDownWithError() throws {
        if let tray, tray.isRunning {
            kill(-tray.processIdentifier, SIGKILL)
            tray.terminate()
        }
        watcher?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Where `swift build --product quotabar-tray` leaves it.
    private static func trayBinary() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["QUOTABAR_TRAY_BIN"],
           FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        // The test bundle sits beside the products in `.build/<triple>/<config>`.
        let bundle = Bundle.main.bundleURL.deletingLastPathComponent()
        for candidate in [bundle.appendingPathComponent("quotabar-tray").path,
                          bundle.deletingLastPathComponent()
                              .appendingPathComponent("quotabar-tray").path] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: The tests

    /// The whole point: the icon reaches the panel.
    func testTheTrayRegistersItselfWithTheWatcher() throws {
        let name = try XCTUnwrap(watcher.awaitRegistration(within: 20),
                                 "the tray never called RegisterStatusNotifierItem")
        XCTAssertTrue(name.hasPrefix(":"), "expected a unique bus name, got \(name)")
    }

    /// Every property Plasma reads before it draws anything.
    func testTheTrayAnswersEveryPropertyATrayReads() throws {
        let name = try XCTUnwrap(watcher.awaitRegistration(within: 20))
        let client = try WatcherStub()   // a second connection, as a tray would be

        let all = try client.getAll(destination: name,
                                    path: StatusNotifierService.itemPath,
                                    interface: StatusNotifierService.itemInterface)
        XCTAssertEqual(all["Id"], .string("quotabar"))
        XCTAssertEqual(all["Category"], .string("ApplicationStatus"))
        XCTAssertEqual(all["ItemIsMenu"], .boolean(false))
        XCTAssertEqual(all["Menu"], .objectPath("/MenuBar"))
        XCTAssertEqual(all["Status"]?.signature, "s")

        // The icon has to be drawable, not merely present.
        guard case .array(_, let pixmaps)? = all["IconPixmap"], let first = pixmaps.first,
              case .struct(let fields) = first, fields.count == 3,
              case .int32(let width) = fields[0], case .int32(let height) = fields[1],
              case .array(_, let bytes) = fields[2] else {
            return XCTFail("IconPixmap is not a(iiay): \(String(describing: all["IconPixmap"]))")
        }
        XCTAssertGreaterThan(width, 0)
        XCTAssertEqual(bytes.count, Int(width) * Int(height) * 4,
                       "pixel buffer does not match its declared size")
        client.stop()
    }

    func testTheTrayServesItsMenu() throws {
        let name = try XCTUnwrap(watcher.awaitRegistration(within: 20))
        let client = try WatcherStub()

        let reply = try client.call(destination: name, path: "/MenuBar",
                                    interface: StatusNotifierService.menuInterface,
                                    member: "GetLayout",
                                    body: [.int32(0), .int32(-1), .strings([])])
        XCTAssertEqual(reply.body.count, 2)
        XCTAssertEqual(reply.body[0].signature, "u")
        XCTAssertEqual(reply.body[1].signature, "(ia{sv}av)")

        // Refresh and Quit must both be there, or the menu is decoration.
        let labels = Self.labels(in: reply.body[1])
        XCTAssertTrue(labels.contains("Refresh"), "\(labels)")
        XCTAssertTrue(labels.contains("Quit"), "\(labels)")
        client.stop()
    }

    /// Introspection is what makes a tray that has not appeared diagnosable.
    func testTheTrayIsIntrospectable() throws {
        let name = try XCTUnwrap(watcher.awaitRegistration(within: 20))
        let client = try WatcherStub()
        let reply = try client.call(destination: name, path: StatusNotifierService.itemPath,
                                    interface: "org.freedesktop.DBus.Introspectable",
                                    member: "Introspect")
        guard case .string(let xml)? = reply.body.first else { return XCTFail("no XML") }
        XCTAssertTrue(xml.contains("org.kde.StatusNotifierItem"))
        client.stop()
    }

    /// Clicking Quit must actually end the process — the one path a unit test can
    /// only assert an intention about.
    func testClickingQuitExitsTheProcess() throws {
        let name = try XCTUnwrap(watcher.awaitRegistration(within: 20))
        let client = try WatcherStub()

        let layout = try client.call(destination: name, path: "/MenuBar",
                                     interface: StatusNotifierService.menuInterface,
                                     member: "GetLayout",
                                     body: [.int32(0), .int32(-1), .strings([])])
        let quitID = try XCTUnwrap(Self.id(ofLabel: "Quit", in: layout.body[1]),
                                   "no Quit row in the layout")

        try client.send(DBusMessage(kind: .methodCall, flags: DBusMessage.noReplyExpected,
                                    path: "/MenuBar",
                                    interface: StatusNotifierService.menuInterface,
                                    member: "Event", destination: name,
                                    body: [.int32(quitID), .string("clicked"),
                                           .variant(.string("")), .uint32(0)]))

        let deadline = Date().addingTimeInterval(15)
        while tray.isRunning && Date() < deadline { usleep(100_000) }
        XCTAssertFalse(tray.isRunning, "the tray ignored a click on Quit")
        XCTAssertEqual(tray.terminationStatus, 0, "Quit should be a clean exit")
        client.stop()
    }

    /// A tray that stops answering is dropped from the panel, so it must keep
    /// replying while a probe is running.
    ///
    /// The point is the timing, and the previous version proved nothing: with no
    /// provider CLI on PATH every probe returned instantly, so the round trips
    /// would have succeeded even from a single-threaded tray. This one stages a
    /// deliberately slow fake provider and asserts the replies come back in a
    /// fraction of the time that provider takes — which is only possible if the
    /// probe is on another thread.
    func testTheTrayKeepsAnsweringWhileItProbes() throws {
        let slowSeconds = 8.0
        let binDir = directory.appendingPathComponent("slow-bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // Named for a provider the tray actually probes, so a refresh runs it.
        for name in ["codex", "claude", "gemini"] {
            let script = binDir.appendingPathComponent(name)
            try "#!/bin/sh\nsleep \(Int(slowSeconds))\nexit 1\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        }

        // The setUp tray has already registered, so awaiting now would hand back
        // ITS name and time the round trips against a tray with no slow provider
        // — which is how the first version of this test passed in 1.0s while
        // proving nothing. Retire it and wait for a genuinely new registration.
        kill(-tray.processIdentifier, SIGKILL)
        tray.terminate()
        tray.waitUntilExit()
        watcher.forgetRegistration()

        let slowTray = try launchTray(extraPath: binDir.path)
        defer { kill(-slowTray.processIdentifier, SIGKILL); slowTray.terminate() }
        let name = try XCTUnwrap(watcher.awaitRegistration(within: 20),
                                 "the slow-probe tray never registered")
        let client = try WatcherStub()

        // It probes on startup, so a probe is already in flight here. Ask for
        // another to be sure, then time the round trips.
        try client.send(DBusMessage(kind: .methodCall, flags: DBusMessage.noReplyExpected,
                                    path: StatusNotifierService.itemPath,
                                    interface: StatusNotifierService.itemInterface,
                                    member: "Activate", destination: name,
                                    body: [.int32(0), .int32(0)]))

        let started = Date()
        for _ in 0..<5 {
            let reply = try client.call(destination: name, path: StatusNotifierService.itemPath,
                                        interface: "org.freedesktop.DBus.Properties",
                                        member: "Get",
                                        body: [.string(StatusNotifierService.itemInterface),
                                               .string("Status")])
            XCTAssertEqual(reply.body.first?.signature, "v")
        }
        let elapsed = Date().timeIntervalSince(started)
        // Half the provider's own duration: comfortably above any plausible
        // round-trip cost, and impossible if the serve loop were blocked on it.
        XCTAssertLessThan(elapsed, slowSeconds / 2,
                          "five round trips took \(elapsed)s; the tray was blocked on its probe")
        client.stop()
    }

    // MARK: Layout helpers

    private static func rows(in layout: DBusValue) -> [(Int32, [String: DBusValue])] {
        guard case .struct(let root) = layout, root.count == 3,
              case .array(_, let children) = root[2] else { return [] }
        return children.compactMap { child in
            guard case .variant(let node) = child, case .struct(let fields) = node,
                  fields.count == 3, case .int32(let id) = fields[0],
                  case .array(_, let entries) = fields[1] else { return nil }
            var properties = [String: DBusValue]()
            for entry in entries {
                guard case .dictEntry(let key, let value) = entry,
                      case .string(let name) = key, case .variant(let inner) = value else { continue }
                properties[name] = inner
            }
            return (id, properties)
        }
    }

    private static func labels(in layout: DBusValue) -> [String] {
        rows(in: layout).compactMap {
            guard case .string(let label)? = $0.1["label"] else { return nil }
            return label
        }
    }

    private static func id(ofLabel label: String, in layout: DBusValue) -> Int32? {
        rows(in: layout).first { row in
            if case .string(let found)? = row.1["label"] { return found == label }
            return false
        }?.0
    }
}

/// A minimal StatusNotifierWatcher, and a general-purpose bus client.
///
/// Built on the same `DBusConnection` the tray uses. That is deliberate: if the
/// connection were broken in a way both sides shared, the unit tests above would
/// still catch it, and this proves the wire is real by talking to a separate
/// process over it.
private final class WatcherStub: @unchecked Sendable {
    private let connection: DBusConnection
    private let lock = NSLock()
    private var registered: String?
    private var running = true
    private var thread: Thread?

    init() throws {
        connection = DBusConnection(channel: try UnixSocketChannel(timeout: 1))
        try connection.connect(uid: UInt32(getuid()))
    }

    /// Returns false when the name already has an owner.
    func claimName() throws -> Bool {
        let reply = try connection.call(destination: "org.freedesktop.DBus",
                                        path: "/org/freedesktop/DBus",
                                        interface: "org.freedesktop.DBus",
                                        member: "RequestName",
                                        // 0x4 = DO_NOT_QUEUE: fail rather than
                                        // wait for Plasma to exit.
                                        body: [.string(StatusNotifierService.watcherService),
                                               .uint32(0x4)])
        guard case .uint32(let code)? = reply.body.first else { return false }
        return code == 1   // PRIMARY_OWNER
    }

    /// Answers what a registering item asks of a watcher.
    func serve() {
        let thread = Thread { [weak self] in
            while self?.isRunning == true {
                guard let self else { return }
                do {
                    guard let message = try self.connection.receiveBuffered() else {
                        _ = try self.connection.pump()
                        continue
                    }
                    try self.answer(message)
                } catch {
                    return
                }
            }
        }
        thread.start()
        self.thread = thread
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func answer(_ message: DBusMessage) throws {
        guard message.kind == .methodCall else { return }
        switch message.member {
        case "RegisterStatusNotifierItem":
            if case .string(let name)? = message.body.first {
                lock.lock()
                // The item registers under its own unique name, which is what a
                // real watcher records and hands to hosts.
                registered = name.hasPrefix(":") ? name : (message.sender ?? name)
                lock.unlock()
            }
            try connection.send(DBusMessage(kind: .methodReturn, replySerial: message.serial,
                                            destination: message.sender))
        case "Get", "GetAll":
            // A real watcher exposes IsStatusNotifierHostRegistered; some items
            // check it before drawing.
            let body: [DBusValue] = message.member == "GetAll"
                ? [.dictionary(["IsStatusNotifierHostRegistered": .boolean(true),
                                "ProtocolVersion": .int32(0),
                                "RegisteredStatusNotifierItems": .strings([])])]
                : [.variant(.boolean(true))]
            try connection.send(DBusMessage(kind: .methodReturn, replySerial: message.serial,
                                            destination: message.sender, body: body))
        default:
            try connection.send(DBusMessage(kind: .error,
                                            errorName: "org.freedesktop.DBus.Error.UnknownMethod",
                                            replySerial: message.serial,
                                            destination: message.sender,
                                            body: [.string(message.member ?? "?")]))
        }
    }

    /// Drops any registration already seen, so a later `awaitRegistration` waits
    /// for a new one rather than returning the last.
    func forgetRegistration() {
        lock.lock(); registered = nil; lock.unlock()
    }

    /// Blocks until an item registers, or the deadline passes.
    func awaitRegistration(within seconds: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock()
            let name = registered
            lock.unlock()
            if let name { return name }
            usleep(50_000)
        }
        return nil
    }

    // MARK: Client side

    @discardableResult
    func call(destination: String, path: String, interface: String, member: String,
              body: [DBusValue] = []) throws -> DBusMessage {
        try connection.call(destination: destination, path: path, interface: interface,
                            member: member, body: body)
    }

    func send(_ message: DBusMessage) throws {
        try connection.send(message)
    }

    func getAll(destination: String, path: String, interface: String) throws -> [String: DBusValue] {
        let reply = try call(destination: destination, path: path,
                             interface: "org.freedesktop.DBus.Properties",
                             member: "GetAll", body: [.string(interface)])
        guard case .array(_, let entries)? = reply.body.first else { return [:] }
        var table = [String: DBusValue]()
        for entry in entries {
            guard case .dictEntry(let key, let value) = entry,
                  case .string(let name) = key, case .variant(let inner) = value else { continue }
            table[name] = inner
        }
        return table
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        connection.close()
    }
}
