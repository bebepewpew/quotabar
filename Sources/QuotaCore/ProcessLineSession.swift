import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A line-oriented conversation with a child process over ordinary pipes.
///
/// `CommandRunner.run` writes all input up front, which does not work for stdio
/// JSON-RPC servers that ignore requests arriving before the previous response.
/// `expect` solved that by driving a pseudo-terminal, but a PTY is the least
/// portable thing in this package — it needs the `expect` binary installed, and
/// has no equivalent on Windows. Anything that speaks a line-delimited protocol
/// over stdin/stdout needs none of that.
final class ProcessLineSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()

    private var buffer = ""
    private var pending: [String] = []
    private var closed = false

    init(executable: String, arguments: [String], currentDirectory: URL? = nil) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            condition.lock()
            defer { condition.broadcast(); condition.unlock() }
            guard !data.isEmpty else {
                closed = true
                handle.readabilityHandler = nil
                return
            }
            buffer += String(decoding: data, as: UTF8.self)
            while let newline = buffer.firstIndex(of: "\n") {
                pending.append(String(buffer[..<newline]))
                buffer = String(buffer[buffer.index(after: newline)...])
            }
        }

        try process.run()
        #if !os(Windows)
        // Own process group, so `close()` can take down children the CLI spawned
        // rather than orphaning them. A Job Object is the Windows equivalent.
        if process.processIdentifier > 1 {
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        }
        #endif
    }

    func send(_ line: String) throws {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Reads lines until one satisfies `matches` or the deadline passes. Every
    /// line seen is appended to `transcript`, so callers can inspect the whole
    /// exchange when looking for an authentication complaint.
    func waitForLine(matching matches: (String) -> Bool,
                     before deadline: Date,
                     transcript: inout [String]) -> String? {
        while let line = nextLine(before: deadline) {
            transcript.append(line)
            if matches(line) { return line }
        }
        return nil
    }

    private func nextLine(before deadline: Date) -> String? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && !closed {
            guard condition.wait(until: deadline) else { return nil }
        }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Terminates the complete process group. A bare `terminate()` would leave
    /// anything the child spawned running, and a child that ignores SIGTERM
    /// would linger past the caller's deadline.
    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()

        let pid = process.processIdentifier
        if process.isRunning {
            #if !os(Windows)
            if pid > 1 { _ = kill(-pid, SIGTERM) }
            #endif
            process.terminate()
            if !waitForExit(within: 2) {
                #if !os(Windows)
                if pid > 1 { _ = kill(-pid, SIGKILL) }
                #endif
            }
        }
        try? output.fileHandleForReading.close()
    }

    private func waitForExit(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }
}
