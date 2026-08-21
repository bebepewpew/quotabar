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
            throw ProbeError.message("The CLI did not respond in time")
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

    private static func terminate(_ process: Process) {
        guard process.processIdentifier > 1 else { return }
        signalGroup(of: process, SIGTERM)
        process.terminate()
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

public enum ProbeError: LocalizedError {
    case missing(String), timeout, message(String), unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .missing(let name): "\(name) is not installed"
        case .timeout: "The CLI did not respond in time"
        case .message(let value), .unsupported(let value): value
        }
    }
}
