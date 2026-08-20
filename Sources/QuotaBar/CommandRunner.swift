import Foundation
import Darwin

enum CommandRunner {
    static func find(_ executable: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let explicit = ["\(home)/.local/bin/\(executable)", "\(home)/.volta/bin/\(executable)",
                        "/opt/homebrew/bin/\(executable)", "/usr/local/bin/\(executable)", "/usr/bin/\(executable)"]
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(executable)" }
        if let match = (explicit + fromPath).first(where: FileManager.default.isExecutableFile) { return match }

        guard executable.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else { return nil }
        guard let data = try? run("/bin/zsh", ["-lic", "command -v -- \(executable)"], timeout: 4) else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init).last(where: FileManager.default.isExecutableFile)
    }

    static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 12, currentDirectory: URL? = nil) throws -> Data {
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
        if process.processIdentifier > 1 { _ = setpgid(process.processIdentifier, process.processIdentifier) }

        let stdout = LockedData(), stderr = LockedData(), readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.set(output.fileHandleForReading.readDataToEndOfFile()); readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.set(errors.fileHandleForReading.readDataToEndOfFile()); readers.leave()
        }
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            Self.terminate(process)
            _ = finished.wait(timeout: .now() + 1)
            if process.processIdentifier > 1 { _ = kill(-process.processIdentifier, SIGKILL) }
            _ = readers.wait(timeout: .now() + 2)
            throw ProbeError.message("The CLI did not respond in time")
        }
        if readers.wait(timeout: .now() + 2) == .timedOut {
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

    static func runExpect(_ script: String, timeout: TimeInterval = 18, currentDirectory: URL? = nil) throws -> String {
        let data = try run("/usr/bin/expect", ["-c", script], timeout: timeout, currentDirectory: currentDirectory)
        return String(decoding: data, as: UTF8.self)
    }

    static func tclQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[") + "\""
    }

    private static func terminate(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 1 else { return }
        _ = kill(-pid, SIGTERM)
        process.terminate()
    }

    private static func diagnostic(stdout: Data, stderr: Data) -> String {
        sanitizeDiagnostic(String(decoding: (stderr.isEmpty ? stdout : stderr).suffix(1_500), as: UTF8.self))
    }

    /// Turns terminal output into safe, readable text for the menu UI. Commands
    /// launched through a PTY can emit cursor movement and bracketed-paste modes,
    /// which otherwise appear as strings such as `[?2004h[2K` in error cards.
    static func sanitizeDiagnostic(_ input: String) -> String {
        var text = input
            .replacingOccurrences(of: "\u{1B}\\][^\u{7}]*(?:\u{7}|\u{1B}\\\\)", with: "", options: .regularExpression)
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

enum ProbeError: LocalizedError {
    case missing(String), timeout, message(String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .missing(let name): "\(name) is not installed"
        case .timeout: "The CLI did not respond in time"
        case .message(let value), .unsupported(let value): value
        }
    }
}
