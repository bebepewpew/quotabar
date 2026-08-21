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
    // One store for everything that persists, the way the CLI does it.
    private let store = StateStoreFactory.makeDefault()
    private let preferences: TrayPreferences
    private let recorder: UsageRecorder
    private var snapshots: [QuotaSnapshot]
    private var revision: UInt32 = 1
    private var current: TrayState
    private var refreshing = false

    init() {
        preferences = TrayPreferences(store: store)
        recorder = UsageRecorder(stateStore: store)
        let restored = SnapshotCache(store: store).all()
        snapshots = restored
        // Drawn from the cache before the first probe returns, so the icon
        // appears with last known numbers rather than blank for several seconds.
        current = TrayStateBuilder.make(snapshots: restored,
                                        selections: preferences.selections,
                                        revision: 1)
    }

    /// What the service should answer with right now.
    var state: TrayState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Claims the right to refresh, or returns false when one is already in
    /// flight.
    ///
    /// Tested and set BEFORE anything is enqueued. `refreshQueue` is serial, so
    /// a guard inside the queued block could never coalesce: each block only
    /// began once the previous had finished and cleared the flag, and clicking
    /// the icon repeatedly stacked up full probe runs — one of which drives a
    /// pseudo-terminal.
    func beginRefresh() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if refreshing { return false }
        refreshing = true
        return true
    }

    /// Probes every provider and returns the signals to emit. Only ever called
    /// after `beginRefresh()` has returned true.
    func refresh() -> [DBusMessage] {
        lock.lock()
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

        // Re-read before merging: this process is long-lived, and `quotabar`
        // runs may have written the cache since it started. Rewriting the whole
        // blob from a snapshot taken at launch would drop their entries.
        SnapshotCache().update(with: merged)
        recorder.record(fresh)
        return signals
    }
}

/// Exits after taking any probe still running down with us.
///
/// A probe may be mid-flight on the refresh thread, and its children are in
/// their own process groups with a deadline enforced by *this* process. Calling
/// `exit` straight from the serve thread would leave them orphaned, which is
/// exactly what AGENTS.md requires external processes not to be.
func quit(_ status: Int32) -> Never {
    CommandRunner.terminateLiveChildren()
    exit(status)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("quotabar-tray: " + message + "\n").utf8))
    quit(1)
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

// Writing the unit is the tray's own job. TrayAutostart has rendered it since
// the tray work began and nothing ever called it, so the documented
// `systemctl --user enable quotabar-tray.service` referred to a file that never
// existed on disk.
if arguments.installAutostart || arguments.removeAutostart {
    do {
        if arguments.installAutostart {
            let path = CommandLine.arguments[0]
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
            try TrayAutostart.install(execPath: resolved)
            print("Installed \(TrayAutostart.unitName). Start it with:")
            print("  systemctl --user enable --now \(TrayAutostart.unitName)")
        } else {
            try TrayAutostart.remove()
            print("Removed \(TrayAutostart.unitName).")
        }
        exit(0)
    } catch {
        fail("\(error)")
    }
}

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
    // Claimed here, not inside the block: the queue is serial, so a guard inside
    // would coalesce nothing.
    guard runtime.beginRefresh() else { return }
    refreshQueue.async {
        let signals = runtime.refresh()
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
                    quit(0)
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
        quit(0)
    } catch {
        fail("\(error)")
    }

    if Date() >= deadline {
        startRefresh()
        deadline = Date().addingTimeInterval(arguments.interval)
    }
}
