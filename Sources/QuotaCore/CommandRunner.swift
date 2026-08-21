import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum CommandRunner {
    /// The most either stream may buffer before a run is abandoned.
    ///
    /// A provider CLI answers a quota question in a few kilobytes, and only the
    /// last 1_500 bytes of what it wrote ever reach a diagnostic. Without a
    /// ceiling the child decides the resident size of a menu-bar app that stays
    /// running for weeks, so a stream that goes past this one is treated as a
    /// malfunctioning or hostile child rather than as output worth keeping.
    public static let maximumCapturedBytes = 8 * 1024 * 1024

    public static func find(_ executable: String) -> String? {
        find(executable, shells: loginShells())
    }

    /// The search with its shell ladder supplied. Shipped code goes through
    /// `find(_:)` above, which passes the real `loginShells()`; a test passes a
    /// staged ladder instead.
    ///
    /// It has to be a parameter rather than a staged `$SHELL`, because a name
    /// that resolves nowhere is asked of *every* candidate — so a stub in
    /// `$SHELL` would still be followed by the machine's own `/bin/zsh -lic`,
    /// an interactive login shell sourcing whatever the developer keeps in
    /// `~/.zshrc`. The ladder is an autoclosure so it is still only built when
    /// the known locations and `PATH` come up empty.
    ///
    /// `DiscoveryMemo` is keyed on the executable, `$PATH` and `$SHELL` and not
    /// on the ladder, because production has only ever one ladder. A test that
    /// stages a different one under the same environment therefore has to use a
    /// name of its own or call `resetDiscoveryMemo()` first, which is what the
    /// discovery cases do.
    static func find(_ executable: String, shells: @autoclosure () -> [(path: String, flags: String)]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let explicit = ["\(home)/.local/bin/\(executable)", "\(home)/.volta/bin/\(executable)",
                        "\(home)/.npm-global/bin/\(executable)", "\(home)/.bun/bin/\(executable)",
                        "/opt/homebrew/bin/\(executable)", "/usr/local/bin/\(executable)", "/usr/bin/\(executable)"]
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(executable)" }
        if let match = (explicit + fromPath).first(where: FileManager.default.isExecutableFile) { return match }

        guard executable.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else { return nil }

        let key = DiscoveryMemo.Key(executable: executable,
                                    path: ProcessInfo.processInfo.environment["PATH"] ?? "",
                                    shell: ProcessInfo.processInfo.environment["SHELL"] ?? "")
        switch discoveryMemo.recall(key) {
        case .resolved(let remembered): return remembered
        case .absent: return nil
        case .unknown: break
        }
        let resolved = searchLoginShells(for: executable, shells: shells())
        discoveryMemo.remember(resolved, for: key)
        return resolved
    }

    /// The expensive half of `find`, kept apart so `DiscoveryMemo` has something
    /// to remember. Every candidate is an interactive login shell that re-executes
    /// the user's startup files, and the loop returns early only on success, so a
    /// binary that is genuinely absent pays for all of them. That is also why a
    /// test hands its own ladder in rather than letting the machine's shells run.
    private static func searchLoginShells(for executable: String,
                                          shells: [(path: String, flags: String)]) -> String? {
        for shell in shells {
            guard let data = try? run(shell.path, [shell.flags, "command -v -- \(executable)"], timeout: 4) else { continue }
            if let match = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map(String.init)
                .last(where: FileManager.default.isExecutableFile) { return match }
        }
        return nil
    }

    /// The one memo in the process. `find` is its only writer; `DiscoveryMemo`
    /// documents what it keeps and when it stops trusting it.
    static let discoveryMemo = DiscoveryMemo()

    /// Forgets every remembered ladder answer. Tests stage `$PATH` and `$SHELL`
    /// around `find` and need each case to start from an empty memo; production
    /// has no reason to call this, because the memo invalidates itself.
    static func resetDiscoveryMemo() { discoveryMemo.reset() }

    /// Interactive login shells, so PATH additions made in `.zshrc`/`.bashrc` —
    /// where version managers put CLI shims — are visible. Candidates are tried in
    /// turn rather than only the first: a `$SHELL` that rejects `-l` or `-i`
    /// (nushell, elvish, restricted shells) must not make every provider look
    /// uninstalled. `sh` gets `-lc`, since a POSIX shell need not accept `-i`
    /// alongside `-c`.
    ///
    /// Candidates are compared by the file they resolve to *and* the name they
    /// are invoked under. The file matters because on a merged-`/usr` Linux
    /// `/bin/bash` and `/usr/bin/bash` are one executable, and spawning both
    /// runs the user's startup files twice to learn the same answer. The name
    /// matters because bash reads `argv[0]`: invoked as `rbash` it is a
    /// restricted shell and as `sh` it is a POSIX one. `/bin/rbash` and
    /// `/bin/bash` are one file on Arch, Debian and Fedora but not one shell,
    /// so deduplicating on the file alone would delete the only unrestricted,
    /// `~/.bashrc`-sourcing rung for anyone whose `$SHELL` is `/bin/rbash` or a
    /// bash-backed `/bin/sh`.
    static func loginShells() -> [(path: String, flags: String)] {
        var seen = Set<String>()
        return [ProcessInfo.processInfo.environment["SHELL"],
                "/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash", "/bin/sh"]
            .compactMap { $0 }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { (path: $0, name: URL(fileURLWithPath: $0).lastPathComponent) }
            // A NUL appears in neither half, so one pair has one spelling and
            // two different pairs cannot collide into it.
            .filter { seen.insert("\(resolvedPath($0.path))\u{0}\($0.name)").inserted }
            .map { ($0.path, ["zsh", "bash"].contains($0.name) ? "-lic" : "-lc") }
    }

    /// The file a candidate path actually names, so two spellings of one shell
    /// under one name are recognised as one. Anything that cannot be resolved —
    /// a dangling symlink, a path that vanished between the check and here —
    /// keeps its original spelling and is simply not deduplicated.
    static func resolvedPath(_ path: String) -> String {
        #if os(Windows)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        #else
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
        #endif
    }

    public static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 12, currentDirectory: URL? = nil) throws -> Data {
        // Before `input` is written to a child that may already have exited.
        ProcessSignals.ignoreBrokenPipe()
        let process = Process()
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
        process.currentDirectoryURL = currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        // Signalled by the child exiting *and* by a reader that hits the byte
        // cap below, so the wait further down ends on whichever comes first
        // rather than letting an overflowing child run out the whole deadline.
        let attention = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in attention.signal() }
        try process.run()
        #if !os(Windows)
        // Give the child its own process group so a timeout can take the whole
        // tree down — the provider CLIs spawn children of their own. The Windows
        // equivalent is a Job Object, which belongs with a Windows front-end.
        if process.processIdentifier > 1 { _ = setpgid(process.processIdentifier, process.processIdentifier) }
        #endif
        // Same reason the stdin write end is closed below: the child holds its
        // own copies, and a reader reaches end of file only once every other
        // write end is gone. This one has never been observed to stall — unlike
        // `ProcessLineSession`, which held its pipe in a stored property and did
        // — so it is here to stop the invariant depending on when Foundation
        // happens to close a handle, not to fix a failure anyone has seen.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        Self.liveChildren.insert(process.processIdentifier)
        defer { Self.liveChildren.remove(process.processIdentifier) }

        // `readDataToEndOfFile` would let the child decide how much memory this
        // process holds, and could not be told to stop, so each stream gets a
        // `PipeReader`: chunked, bounded by a fixed cap, and cancellable. A
        // reader that reaches the cap stops there and wakes the wait below,
        // which takes the process group down and reports the cap rather than
        // whatever the deadline would have said several seconds later.
        let readers = DispatchGroup()
        let overflowed = LockedFlag()
        let reportOverflow: @Sendable () -> Void = {
            overflowed.raise()
            attention.signal()
        }
        let stdout = PipeReader(output, in: readers,
                                limit: Self.maximumCapturedBytes, onOverflow: reportOverflow)
        let stderr = PipeReader(errors, in: readers,
                                limit: Self.maximumCapturedBytes, onOverflow: reportOverflow)
        // A child that read no stdin and exited leaves this write failing with
        // `EPIPE`. That is not the interesting failure: the exit status and the
        // child's own stderr below say far more than "broken pipe", so the write
        // is allowed to fail and the normal diagnostic path reports the cause.
        // The throwing `write(contentsOf:)` is deliberate — the non-throwing
        // `write(_:)` raises an unrecoverable exception on the same error.
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()

        if attention.wait(timeout: .now() + timeout) == .timedOut {
            Self.terminate(process)
            _ = attention.wait(timeout: .now() + 1)
            Self.signalGroup(of: process, SIGKILL)
            // The readers are waited on before giving up so that whatever the
            // child printed still travels with the error. A CLI that says what
            // went wrong and only then hangs — clearing up its own children,
            // say — has already answered the caller's question.
            if readers.wait(timeout: .now() + 2) == .timedOut {
                // Whatever still holds the write ends left the process group, so
                // the kill above never reached it — a grandchild that called
                // `setsid()` is exactly this case. Both readers would then sit on
                // a thread and a descriptor apiece until the process exits, and a
                // menu bar refreshing for weeks accumulates a pair per deadline.
                Self.stopReading(stdout, stderr, in: readers)
            }
            throw ProbeError.timeout(partialOutput: String(decoding: stdout.value, as: UTF8.self))
        }
        if overflowed.isSet { throw Self.abandonAfterOverflow(process, readers, stdout, stderr) }
        if readers.wait(timeout: .now() + 2) == .timedOut {
            // The command itself is gone, so whatever still holds the pipes is
            // something it spawned. Leaving that behind would outlive the
            // caller's deadline, so the group goes down before reporting.
            Self.signalGroup(of: process, SIGTERM)
            if readers.wait(timeout: .now() + 1) == .timedOut {
                Self.signalGroup(of: process, SIGKILL)
                if readers.wait(timeout: .now() + 1) == .timedOut {
                    Self.stopReading(stdout, stderr, in: readers)
                }
            }
            throw ProbeError.message("The CLI exited but left its output stream open")
        }
        // The child can exit long before whatever it spawned fills a stream, so
        // the cap is checked again now the readers are done.
        if overflowed.isSet { throw Self.abandonAfterOverflow(process, readers, stdout, stderr) }
        guard process.terminationStatus == 0 else {
            // What the child printed goes into the failure as `detail`, never
            // into the message: it is untrusted text to be classified, not
            // echoed. See `ProbeError.CommandFailure`.
            throw ProbeError.commandFailed(.init(command: commandName(executable),
                                                 status: process.terminationStatus,
                                                 detail: diagnostic(stdout: stdout.value, stderr: stderr.value)))
        }
        return stdout.value
    }

    public static func runExpect(_ script: String, timeout: TimeInterval = 18, currentDirectory: URL? = nil) throws -> String {
        guard let expect = find("expect") else { throw ProbeError.unsupported(expectInstallHint) }
        let data = try run(expect, ["-c", script], timeout: timeout, currentDirectory: currentDirectory)
        return String(decoding: data, as: UTF8.self)
    }

    static var expectInstallHint: String {
        #if os(macOS)
        "expect is not installed. Install it with `brew install expect`."
        #elseif os(Windows)
        "expect is not installed, and there is no Windows build of it. The Gemini probe needs a pseudo-terminal and is not supported on Windows yet."
        #else
        "expect is not installed. Install it with `sudo pacman -S expect` or `sudo apt install expect`."
        #endif
    }

    public static func tclQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[") + "\""
    }

    /// Ends a run the byte cap cut short. Nothing is draining that stream any
    /// more, so a child still writing to it would block in `write` and outlive
    /// this call: the complete group goes down, with the usual escalation, before
    /// the error is returned.
    ///
    /// The other reader may still be waiting on a stream that never ends, so it
    /// is cancelled rather than left holding a thread and a descriptor — the
    /// same reason the deadline path does. Neither pipe is closed from here: a
    /// `PipeReader` is the only thing that closes the handle it reads.
    private static func abandonAfterOverflow(_ process: Process, _ readers: DispatchGroup,
                                             _ stdout: PipeReader, _ stderr: PipeReader) -> ProbeError {
        terminate(process)
        if readers.wait(timeout: .now() + 1) == .timedOut {
            signalGroup(of: process, SIGKILL)
            if readers.wait(timeout: .now() + 1) == .timedOut {
                stopReading(stdout, stderr, in: readers)
            }
        }
        return .outputTooLarge
    }

    private static func terminate(_ process: Process) {
        guard process.processIdentifier > 1 else { return }
        signalGroup(of: process, SIGTERM)
        process.terminate()
    }

    /// Ends readers that are still waiting on output nobody is going to send,
    /// and waits — bounded, like everything else here — for them to hand their
    /// threads and descriptors back before the caller is told the run failed.
    ///
    /// Cancellation is cooperative because the obvious alternative is worse:
    /// closing a descriptor out from under a blocked reader does not wake it on
    /// Linux, and the reader then trips the `try!` inside Foundation the next
    /// time it touches that descriptor — a leaked pipe traded for a crashed menu
    /// bar. A `PipeReader` closes its own handle instead, so no descriptor is
    /// ever pulled out from under the only thread that reads it.
    private static func stopReading(_ readers: PipeReader..., in group: DispatchGroup) {
        for reader in readers { reader.cancel() }
        _ = group.wait(timeout: .now() + 1)
    }

    /// Process groups of children that are running right now.
    ///
    /// A one-shot `quotabar` run exits with its probes, so nothing needed this.
    /// The tray is long-lived and exits on a click or when the bus goes away —
    /// from a different thread than the one probing — and the deadline that
    /// would have killed a stuck child is enforced by this process. Leaving
    /// without them orphans exactly what AGENTS.md says must not be orphaned.
    private static let liveChildren = LockedPIDs()

    /// Records a child spawned outside `run`, such as a `ProcessLineSession`.
    public static func registerLiveChild(_ pid: Int32) { liveChildren.insert(pid) }

    /// Forgets a child that has been reaped by its owner.
    public static func deregisterLiveChild(_ pid: Int32) { liveChildren.remove(pid) }

    /// Terminates every probe still running, group and all.
    ///
    /// Call it before exiting from anywhere that is not the probing thread.
    /// Safe to call when nothing is running.
    public static func terminateLiveChildren() {
        #if !os(Windows)
        for pid in liveChildren.drain() {
            _ = kill(-pid, SIGTERM)
            _ = kill(-pid, SIGKILL)
        }
        #endif
    }

    /// Signals the child's complete process group. Every child gets a group of
    /// its own above, so this also reaches the grandchildren a provider CLI
    /// spawned — a bare signal to the child would orphan them.
    private static func signalGroup(of process: Process, _ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 1 else { return }
        #if !os(Windows)
        _ = kill(-pid, signal)
        #endif
    }

    /// The bare name of the executable, so a failure can say *which* command
    /// failed without printing the path it was found at.
    ///
    /// That path comes from `PATH` or from a login shell's answer, so its last
    /// component is untrusted like everything else around a provider CLI. Only
    /// a plain name is used; anything else is dropped rather than reworded into
    /// something that would look official in an error card.
    static func commandName(_ executable: String) -> String? {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return name.range(of: #"^[A-Za-z0-9._+-]{1,32}$"#, options: .regularExpression) != nil ? name : nil
    }

    private static func diagnostic(stdout: Data, stderr: Data) -> String {
        sanitizeDiagnostic(String(decoding: (stderr.isEmpty ? stdout : stderr).suffix(1_500), as: UTF8.self))
    }

    /// Turns terminal output into safe, readable text for the menu UI. Commands
    /// launched through a PTY can emit cursor movement and bracketed-paste modes,
    /// which otherwise appear as strings such as `[?2004h[2K` in error cards.
    ///
    /// The operating-system-command pattern stops at the next escape as well as
    /// at `BEL`: a hyperlink or title pair terminated by `ESC \` would otherwise
    /// match greedily from the first sequence to the last, swallowing the error
    /// text between them.
    public static func sanitizeDiagnostic(_ input: String) -> String {
        var text = input
            .replacingOccurrences(of: "\u{1B}\\][^\u{7}\u{1B}]*(?:\u{7}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[@-_]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = String(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7f && !(0x80...0x9f).contains(scalar.value))
        })
        return text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Remembers what the login-shell ladder answered, so a binary that is genuinely
/// absent stops costing a ladder run on every refresh.
///
/// The ladder is the expensive half of `CommandRunner.find`: up to six
/// candidates, each an interactive login shell that re-executes the user's
/// startup files, at a four-second deadline apiece. It returns early only on
/// success, so a machine with Gemini installed but no `expect` paid for the
/// whole ladder every time the Gemini probe ran, forever, and the answer never
/// changed within a process.
///
/// **Lifetime and invalidation.** Nothing is written to disk; the memo dies with
/// the process. Within it:
///
/// - Only the ladder is memoised. The cheap half of `find` — the known install
///   locations, then `$PATH`, a handful of `stat` calls — still runs on every
///   call, so an `expect` that arrives in `/usr/bin`, `/usr/local/bin`,
///   `/opt/homebrew/bin` or anywhere on `$PATH` is picked up by the next refresh
///   with nothing to invalidate.
/// - An entry is keyed on the inputs that decided the answer: the executable
///   name, `$PATH` and `$SHELL`. Change either variable and the ladder runs again.
/// - A remembered hit is re-validated with one `stat` before it is handed back,
///   so a binary that was uninstalled or moved is never offered as an executable.
/// - A remembered miss expires after `missLifetime`. Without that, "install
///   expect, then refresh" would become "install expect, then restart QuotaBar"
///   for an install only an interactive login shell can see.
///
/// Two callers racing on the same absent binary can each run the ladder once;
/// that is far cheaper than holding a lock across six subprocesses.
final class DiscoveryMemo: @unchecked Sendable {
    /// Everything that decides the ladder's answer, so a change to any of it
    /// asks again instead of replaying a stale one.
    struct Key: Hashable {
        let executable: String, path: String, shell: String
    }

    enum Answer: Equatable {
        /// Nothing is remembered, or what was remembered is no longer trusted.
        case unknown
        /// The ladder found nothing, recently enough to still believe it.
        case absent
        /// The ladder resolved a path that is still an executable file.
        case resolved(String)
    }

    /// How long a "not installed" answer is trusted. Ten minutes is twice the
    /// shortest refresh interval, so a busy cycle stops re-running the ladder,
    /// while an install stays invisible for minutes rather than until a restart.
    static let missLifetime: TimeInterval = 10 * 60

    private struct Entry {
        let resolved: String?, recordedAt: Date
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private let now: () -> Date
    private let isExecutable: (String) -> Bool

    init(now: @escaping () -> Date = Date.init,
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.now = now
        self.isExecutable = isExecutable
    }

    func recall(_ key: Key) -> Answer {
        guard let entry = lock.withLock({ entries[key] }) else { return .unknown }
        guard let resolved = entry.resolved else {
            guard now().timeIntervalSince(entry.recordedAt) < Self.missLifetime else { return forget(key) }
            return .absent
        }
        guard isExecutable(resolved) else { return forget(key) }
        return .resolved(resolved)
    }

    func remember(_ resolved: String?, for key: Key) {
        lock.withLock { entries[key] = Entry(resolved: resolved, recordedAt: now()) }
    }

    func reset() {
        lock.withLock { entries.removeAll() }
    }

    private func forget(_ key: Key) -> Answer {
        lock.withLock { _ = entries.removeValue(forKey: key) }
        return .unknown
    }
}

/// Collects everything a child writes to one of its output pipes, on a thread of
/// its own, up to a byte ceiling, and can be told to stop and let the pipe go.
///
/// `readDataToEndOfFile()` can be told neither of those things. It returns only
/// once every write end is closed — which a grandchild that escaped the process
/// group can prevent for as long as the app runs — and it lets the child decide
/// how much memory this process holds on the way. There is no safe way to take
/// the descriptor away from it either: closing the handle leaves the reader
/// blocked on Linux and then traps the whole process on Foundation's `try!` when
/// it reads again. So the descriptor is read directly, in short waits and
/// bounded chunks, and the reader — the only thing that ever closes this handle
/// — closes it on the way out.
private final class PipeReader: @unchecked Sendable {
    /// How long a reader waits for output before looking at `stopped` again.
    /// Short enough not to hold up a deadline that is already overdue, long
    /// enough to cost nothing on a run that behaves.
    private static let waitMilliseconds: Int32 = 100
    private static let bufferSize = 32 * 1_024

    private let handle: FileHandle
    /// The most this reader will retain before it gives up on the stream.
    private let limit: Int
    /// Told once, when the child writes past `limit`, so the caller's wait can
    /// end there rather than running the deadline out on a flood.
    private let onOverflow: @Sendable () -> Void
    private let lock = NSLock()
    private var storage = Data()
    private var stopped = false

    /// Starts reading straight away and leaves `group` when the pipe is done
    /// with, whether that is end of file, the byte ceiling or a cancellation.
    init(_ pipe: Pipe, in group: DispatchGroup, limit: Int, onOverflow: @escaping @Sendable () -> Void) {
        handle = pipe.fileHandleForReading
        self.limit = limit
        self.onOverflow = onOverflow
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            drain()
            group.leave()
        }
    }

    /// Everything read so far.
    var value: Data { lock.withLock { storage } }

    /// Asks the reader to give up. It closes the pipe on its way out, within one
    /// wait interval of this call.
    func cancel() { lock.withLock { stopped = true } }

    /// Keeps what fits under the ceiling and reports whether reading may go on.
    /// A chunk that crosses the ceiling is kept only as far as the ceiling, so
    /// what this holds is bounded by `limit` exactly rather than by `limit` plus
    /// however large the crossing read happened to be.
    private func accept(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        lock.lock()
        let room = max(0, limit - storage.count)
        storage.append(bytes, count: Swift.min(count, room))
        let past = count > room
        lock.unlock()
        return !past
    }

    private func drain() {
        #if os(Windows)
        // `poll` is POSIX-only; the cancellable equivalent is an overlapped read,
        // and it belongs with a Windows front-end.
        let data = handle.readDataToEndOfFile()
        let fits = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            return accept(base, count: raw.count)
        }
        try? handle.close()
        if !fits { onOverflow() }
        #else
        let descriptor = handle.fileDescriptor
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 1)
        var overflowed = false
        defer {
            buffer.deallocate()
            try? handle.close()
            // After the handle is gone: the caller wakes on this and takes the
            // process group down, and a descriptor it has been told to stop
            // reading must not still be open when it does.
            if overflowed { onOverflow() }
        }
        guard descriptor >= 0 else { return }
        while !lock.withLock({ stopped }) {
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, Self.waitMilliseconds)
            if ready < 0 && errno != EINTR { return }
            guard ready > 0 else { continue }
            let count = read(descriptor, buffer, Self.bufferSize)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            guard accept(buffer.assumingMemoryBound(to: UInt8.self), count: count) else {
                // Past the ceiling. Nothing more is worth reading: the run is
                // about to be abandoned and the group taken down.
                overflowed = true
                return
            }
        }
        #endif
    }
}

/// A one-way flag a reader thread raises and the caller reads.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

public enum ProbeError: LocalizedError {
    case missing(String)
    /// A deadline expired, carrying whatever the child had already printed.
    ///
    /// The payload is diagnostic input for the caller, never display text: a
    /// script that announced *why* it was giving up and then stalled clearing
    /// up its children would otherwise have that verdict replaced by a bare
    /// "did not respond in time". `errorDescription` deliberately drops it, so
    /// raw provider output cannot reach an error card.
    case timeout(partialOutput: String)
    case message(String), unsupported(String)
    /// The child wrote more than a probe is willing to buffer, so the read was
    /// abandoned rather than allowed to grow without bound.
    case outputTooLarge
    /// A command that ran and exited non-zero for a reason no probe classified.
    case commandFailed(CommandFailure)

    /// What a failed command is allowed to say for itself.
    ///
    /// `detail` is the CLI's own output, stripped of terminal control sequences
    /// but not judged: it is whatever the provider chose to print, and that has
    /// included API keys, prompts and file paths. Every `errorDescription`
    /// reaches the menu card, the text table and `--json`, so the message is
    /// fixed text built from the command name and the exit status instead.
    /// `detail` stays internal to `QuotaCore`, where a probe can match it to
    /// produce an actionable error of its own and no front-end can render it.
    public struct CommandFailure: Sendable {
        /// The bare command name, when it had a plain one.
        public let command: String?
        public let status: Int32
        let detail: String

        init(command: String?, status: Int32, detail: String) {
            self.command = command
            self.status = status
            self.detail = detail
        }

        /// Concise, actionable, and free of anything the command printed — the
        /// output itself is one command away for whoever wants to read it.
        public var message: String {
            "\(command ?? "The CLI") exited with status \(status). Run it in a terminal to see what it reported."
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missing(let name): "\(name) is not installed"
        case .timeout: "The CLI did not respond in time"
        case .outputTooLarge: "The CLI produced more output than QuotaBar will read"
        case .message(let value), .unsupported(let value): value
        case .commandFailed(let failure): failure.message
        }
    }

    /// The failing command's own output, for matching inside `QuotaCore` only,
    /// so a probe can turn a recognised complaint into a message of its own.
    /// Nothing may display it, which is why it is not public.
    var diagnosticDetail: String? {
        guard case .commandFailed(let failure) = self, !failure.detail.isEmpty else { return nil }
        return failure.detail
    }

    /// What the child managed to print before its deadline, if this is a
    /// timeout and anything arrived at all.
    public var partialOutput: String? {
        guard case .timeout(let output) = self, !output.isEmpty else { return nil }
        return output
    }
}


/// The set of process groups a `terminateLiveChildren()` should reach.
///
/// Its own type so the locking is in one place: probes register from a worker
/// thread and the tray drains from whichever thread is exiting.
private final class LockedPIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var pids = Set<Int32>()

    func insert(_ pid: Int32) {
        guard pid > 1 else { return }
        lock.lock(); pids.insert(pid); lock.unlock()
    }

    func remove(_ pid: Int32) {
        lock.lock(); pids.remove(pid); lock.unlock()
    }

    /// Takes the set and empties it, so a second exit path cannot signal a pid
    /// the kernel may already have recycled.
    func drain() -> Set<Int32> {
        lock.lock(); defer { lock.unlock() }
        let current = pids
        pids.removeAll()
        return current
    }
}
