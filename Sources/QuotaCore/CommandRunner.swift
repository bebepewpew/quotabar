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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let explicit = ["\(home)/.local/bin/\(executable)", "\(home)/.volta/bin/\(executable)",
                        "\(home)/.npm-global/bin/\(executable)", "\(home)/.bun/bin/\(executable)",
                        "/opt/homebrew/bin/\(executable)", "/usr/local/bin/\(executable)", "/usr/bin/\(executable)"]
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(executable)" }
        if let match = (explicit + fromPath).first(where: FileManager.default.isExecutableFile) { return match }

        guard executable.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else { return nil }
        for shell in loginShells() {
            guard let data = try? run(shell.path, [shell.flags, "command -v -- \(executable)"], timeout: 4) else { continue }
            if let match = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map(String.init)
                .last(where: FileManager.default.isExecutableFile) { return match }
        }
        return nil
    }

    /// Interactive login shells, so PATH additions made in `.zshrc`/`.bashrc` —
    /// where version managers put CLI shims — are visible. Candidates are tried in
    /// turn rather than only the first: a `$SHELL` that rejects `-l` or `-i`
    /// (nushell, elvish, restricted shells) must not make every provider look
    /// uninstalled. `sh` gets `-lc`, since a POSIX shell need not accept `-i`
    /// alongside `-c`.
    static func loginShells() -> [(path: String, flags: String)] {
        var seen = Set<String>()
        return [ProcessInfo.processInfo.environment["SHELL"],
                "/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash", "/bin/sh"]
            .compactMap { $0 }
            .filter { FileManager.default.isExecutableFile(atPath: $0) && seen.insert($0).inserted }
            .map { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return (path, ["zsh", "bash"].contains(name) ? "-lic" : "-lc")
            }
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
        // `readDataToEndOfFile` would let the child decide how much memory this
        // process holds, so each stream is drained in chunks up to a fixed cap.
        // A reader that reaches the cap stops there and wakes the wait below,
        // which takes the process group down and reports the cap rather than
        // whatever the deadline would have said several seconds later.
        let overflowed = LockedFlag()
        for (pipe, sink) in [(output, stdout), (errors, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                let capped = Self.readCapped(pipe.fileHandleForReading, limit: Self.maximumCapturedBytes)
                sink.set(capped.data)
                if capped.truncated {
                    overflowed.raise()
                    attention.signal()
                }
                readers.leave()
            }
        }
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
            _ = readers.wait(timeout: .now() + 2)
            throw ProbeError.message("The CLI did not respond in time")
        }
        if overflowed.isSet { throw Self.abandonAfterOverflow(process, readers, output, errors) }
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
        // The child can exit long before whatever it spawned fills a stream, so
        // the cap is checked again now the readers are done.
        if overflowed.isSet { throw Self.abandonAfterOverflow(process, readers, output, errors) }
        guard process.terminationStatus == 0 else {
            let detail = diagnostic(stdout: stdout.value, stderr: stderr.value)
            throw ProbeError.message(detail.isEmpty ? "Command failed with exit code \(process.terminationStatus)" : detail)
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

    /// Drains a stream to end of file, keeping at most `limit` bytes and
    /// reporting whether the child wrote more than that. Reading in chunks
    /// rather than through `readDataToEndOfFile` is the whole point: the loop
    /// can stop, and what it holds is bounded by the cap plus the chunk that
    /// crossed it.
    private static func readCapped(_ handle: FileHandle, limit: Int) -> (data: Data, truncated: Bool) {
        var captured = Data()
        var seen = 0
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return (captured, false) }
            seen += chunk.count
            guard seen <= limit else {
                captured.append(chunk.prefix(max(0, limit - captured.count)))
                return (captured, true)
            }
            captured.append(chunk)
        }
    }

    /// Ends a run the byte cap cut short. Nothing is draining that stream any
    /// more, so a child still writing to it would block in `write` and outlive
    /// this call: the complete group goes down, with the usual escalation, before
    /// the error is returned.
    private static func abandonAfterOverflow(_ process: Process, _ readers: DispatchGroup,
                                             _ output: Pipe, _ errors: Pipe) -> ProbeError {
        terminate(process)
        if readers.wait(timeout: .now() + 1) == .timedOut {
            signalGroup(of: process, SIGKILL)
            _ = readers.wait(timeout: .now() + 1)
        }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        return .outputTooLarge
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

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var value: Data { lock.withLock { storage } }
    func set(_ data: Data) { lock.withLock { storage = data } }
}

/// A one-way flag a reader thread raises and the caller reads.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

public enum ProbeError: LocalizedError {
    case missing(String), timeout, message(String), unsupported(String), outputTooLarge
    public var errorDescription: String? {
        switch self {
        case .missing(let name): "\(name) is not installed"
        case .timeout: "The CLI did not respond in time"
        case .outputTooLarge: "The CLI produced more output than QuotaBar will read"
        case .message(let value), .unsupported(let value): value
        }
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
