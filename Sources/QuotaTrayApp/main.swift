import Foundation
import QuotaCore
import QuotaTray
#if canImport(Glibc)
import Glibc
#endif

// A StatusNotifierItem tray icon for QuotaBar.
//
// The protocol lives in QuotaTray and is tested there; what a tray sees is built
// by TrayStateBuilder and tested there too. This file owns only the socket, the
// clock and the thread that probes — the parts that need a live session to mean
// anything. Keeping it thin is deliberate: it is the only code here the suite
// cannot drive.

/// Mutable state, off the main actor.
///
/// Top-level variables in `main.swift` are main-actor isolated and probes run on
/// another thread, so the shared state lives here behind a lock instead.
final class TrayRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private let cache = SnapshotCache()
    private let preferences = TrayPreferences()
    private var snapshots: [QuotaSnapshot]
    private var revision: UInt32 = 1
    private var current: TrayState
    private var refreshing = false

    init() {
        let restored = SnapshotCache().all()
        snapshots = restored
        // Drawn from the cache before the first probe returns, so the icon
        // appears with last known numbers rather than blank for several seconds.
        current = TrayStateBuilder.make(snapshots: restored,
                                        selections: TrayPreferences().selections,
                                        revision: 1)
    }

    /// What the service should answer with right now.
    var state: TrayState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Probes every provider and returns the signals to emit, or nil when a
    /// refresh is already in flight.
    ///
    /// Coalesced rather than queued: clicking the icon repeatedly must not stack
    /// up probe runs, one of which drives a pseudo-terminal.
    func refresh() -> [DBusMessage]? {
        lock.lock()
        if refreshing { lock.unlock(); return nil }
        refreshing = true
        let previous = snapshots
        lock.unlock()

        let fresh = Provider.allCases.map { QuotaEngine.load($0) }
        let merged = QuotaEngine.retainingLastGood(fresh: fresh, previous: previous)

        lock.lock()
        snapshots = merged
        revision = TrayStateBuilder.nextRevision(after: revision)
        current = TrayStateBuilder.make(snapshots: merged,
                                        selections: preferences.selections,
                                        revision: revision)
        let signals = StatusNotifierService.changeSignals(revision: revision)
        refreshing = false
        lock.unlock()

        cache.update(with: merged)
        return signals
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("quotabar-tray: " + message + "\n").utf8))
    exit(1)
}

// MARK: Arguments

let arguments = TrayArguments.parse(Array(CommandLine.arguments.dropFirst()))
if !arguments.unknown.isEmpty {
    // Reported rather than ignored: a mistyped flag that silently does nothing
    // looks like the tray ignoring a setting.
    for problem in arguments.unknown {
        FileHandle.standardError.write(Data("quotabar-tray: \(problem)\n".utf8))
    }
    FileHandle.standardError.write(Data((TrayArguments.usage + "\n").utf8))
    exit(2)
}
if arguments.help { print(TrayArguments.usage); exit(0) }
if arguments.version { print("quotabar-tray \(TrayArguments.version)"); exit(0) }

// MARK: Connect

/// A provider CLI that exits mid-write must fail one refresh, not kill the tray.
ProcessSignals.ignoreBrokenPipe()

let runtime = TrayRuntime()
let connection: DBusConnection
do {
    // The socket deadline is the tray's clock: a read that times out is the cue
    // to check whether a refresh is due, so nothing else has to poll.
    connection = DBusConnection(channel: try UnixSocketChannel(timeout: 2))
    try connection.connect(uid: UInt32(getuid()))
} catch DBusConnectionError.unsupportedAddress(let detail) {
    fail("no session bus: \(detail)")
} catch {
    fail("cannot join the session bus: \(error)")
}

guard let uniqueName = connection.uniqueName else { fail("the bus assigned no name") }

// MARK: Register

do {
    try connection.call(destination: StatusNotifierService.watcherService,
                        path: StatusNotifierService.watcherPath,
                        interface: StatusNotifierService.watcherService,
                        member: "RegisterStatusNotifierItem",
                        body: [.string(uniqueName)]) { incoming in
        // A tray may call straight back before the watcher's reply lands, so
        // anything arriving meanwhile is served rather than dropped — otherwise
        // the first GetAll goes unanswered and the icon never draws.
        for message in StatusNotifierService.handle(incoming, state: runtime.state).replies {
            try connection.send(message)
        }
    }
} catch DBusConnectionError.remote(let name, _) where name.hasSuffix("ServiceUnknown") {
    fail("""
        no StatusNotifierWatcher on this session bus.
        KDE Plasma provides one; on GNOME it comes from the AppIndicator extension.
        The `quotabar` command needs neither and works anywhere.
        """)
} catch {
    fail("the tray refused the registration: \(error)")
}

// MARK: Serve

/// Probes block on subprocesses — Gemini's for several seconds — and a tray that
/// stops answering the bus is dropped from the panel. So probing happens off the
/// serving thread and the icon stays put while it runs.
let refreshQueue = DispatchQueue(label: "quotabar-tray.refresh", qos: .utility)

@Sendable func startRefresh() {
    refreshQueue.async {
        guard let signals = runtime.refresh() else { return }
        // Best effort: the bus going away between the probe and the signal is
        // the session ending, which the serve loop below notices and exits on.
        for signal in signals { _ = try? connection.send(signal) }
    }
}

startRefresh()
var deadline = Date().addingTimeInterval(arguments.interval)

while true {
    do {
        if let message = try connection.receiveBuffered() {
            let response = StatusNotifierService.handle(message, state: runtime.state)
            for reply in response.replies { try connection.send(reply) }
            if let action = response.action {
                switch action {
                case .refresh:
                    startRefresh()
                case .quit:
                    connection.close()
                    exit(0)
                }
            }
            continue
        }
        // Nothing buffered: wait on the socket. Its deadline is what turns a
        // quiet bus into a timer tick, so `pump` returning false IS the timer.
        try connection.pump()
    } catch DBusConnectionError.disconnected {
        // The bus went away, so the session is ending. Exiting quietly is right:
        // a tray that outlives its bus is a stray process nobody can see.
        exit(0)
    } catch {
        fail("\(error)")
    }

    if Date() >= deadline {
        startRefresh()
        deadline = Date().addingTimeInterval(arguments.interval)
    }
}
