import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum CommandRunner {
    public static func find(_ executable: String) -> String? {
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
        let resolved = searchLoginShells(for: executable)
        discoveryMemo.remember(resolved, for: key)
        return resolved
    }

    /// The expensive half of `find`, kept apart so `DiscoveryMemo` has something
    /// to remember. Every candidate is an interactive login shell that re-executes
    /// the user's startup files, and the loop returns early only on success, so a
    /// binary that is genuinely absent pays for all of them.
    private static func searchLoginShells(for executable: String) -> String? {
        for shell in loginShells() {
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
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        #if !os(Windows)
        // Give the child its own process group so a timeout can take the whole
        // tree down — the provider CLIs spawn children of their own. The Windows
        // equivalent is a Job Object, which belongs with a Windows front-end.
        if process.processIdentifier > 1 { _ = setpgid(process.processIdentifier, process.processIdentifier) }
        #endif
        // Same reason the stdin write end is closed below: the child holds its
        // own copies, and `readDataToEndOfFile` returns only once every other
        // write end is gone. This one has never been observed to stall — unlike
        // `ProcessLineSession`, which held its pipe in a stored property and did
        // — so it is here to stop the invariant depending on when Foundation
        // happens to close a handle, not to fix a failure anyone has seen.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        Self.liveChildren.insert(process.processIdentifier)
        defer { Self.liveChildren.remove(process.processIdentifier) }

        let stdout = LockedData(), stderr = LockedData(), readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.set(output.fileHandleForReading.readDataToEndOfFile()); readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.set(errors.fileHandleForReading.readDataToEndOfFile()); readers.leave()
        }
        // A child that read no stdin and exited leaves this write failing with
        // `EPIPE`. That is not the interesting failure: the exit status and the
        // child's own stderr below say far more than "broken pipe", so the write
        // is allowed to fail and the normal diagnostic path reports the cause.
        // The throwing `write(contentsOf:)` is deliberate — the non-throwing
        // `write(_:)` raises an unrecoverable exception on the same error.
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            Self.terminate(process)
            _ = finished.wait(timeout: .now() + 1)
            Self.signalGroup(of: process, SIGKILL)
            _ = readers.wait(timeout: .now() + 2)
            // The readers above are waited on before giving up so that whatever
            // the child printed still travels with the error. A CLI that says
            // what went wrong and only then hangs — clearing up its own
            // children, say — has already answered the caller's question.
            throw ProbeError.timeout(partialOutput: String(decoding: stdout.value, as: UTF8.self))
        }
        if readers.wait(timeout: .now() + 2) == .timedOut {
            // The command itself is gone, so whatever still holds the pipes is
            // something it spawned. Leaving that behind would outlive the
            // caller's deadline, so the group goes down before reporting.
            Self.signalGroup(of: process, SIGTERM)
            if readers.wait(timeout: .now() + 1) == .timedOut {
                Self.signalGroup(of: process, SIGKILL)
                _ = readers.wait(timeout: .now() + 1)
            }
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            throw ProbeError.message("The CLI exited but left its output stream open")
        }
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

    private static func terminate(_ process: Process) {
        guard process.processIdentifier > 1 else { return }
        signalGroup(of: process, SIGTERM)
        process.terminate()
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

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var value: Data { lock.withLock { storage } }
    func set(_ data: Data) { lock.withLock { storage = data } }
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
