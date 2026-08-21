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
    private var tornDown = false

    init(executable: String, arguments: [String], currentDirectory: URL? = nil) throws {
        // Before the first write can reach a child that may already be gone.
        ProcessSignals.ignoreBrokenPipe()
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
                // End of file. Whatever is still buffered is a final line the
                // child wrote without a trailing newline; dropping it would lose
                // the last response of a CLI that does not terminate its output.
                if !buffer.isEmpty {
                    pending.append(buffer)
                    buffer = ""
                }
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
        // The child has its own copy of the pipe now, and a reader sees end of
        // file only when *every* write end is closed. Holding this one leaves
        // the child's exit invisible: `waitForLine` then runs to its deadline
        // instead of returning at once, which is the whole point of the deadline
        // being an upper bound rather than the normal cost of a dead CLI.
        try? output.fileHandleForWriting.close()
        #if !os(Windows)
        // Own process group, so `close()` can take down children the CLI spawned
        // rather than orphaning them. A Job Object is the Windows equivalent.
        if process.processIdentifier > 1 {
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        }
        #endif
        // The tray exits from a thread that is not this one, so it needs a way
        // to reach a session still running. `close()` deregisters.
        CommandRunner.registerLiveChild(process.processIdentifier)
    }

    /// Writing through the string's own UTF-8 view rather than the optional
    /// `data(using:)`: that conversion cannot fail for a Swift string, and
    /// returning quietly when it did would have dropped a request the caller
    /// believes it sent. A write that really fails — the pipe is closed, or the
    /// child is gone — throws, which holds only because `SIGPIPE` is ignored:
    /// under the default disposition a write to a child that has exited kills
    /// this process outright instead of returning `EPIPE`.
    func send(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
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

    /// Whether the direct child is still running. Teardown takes a different
    /// path once it has exited and been reaped, and a test aiming at that path
    /// has to be able to wait for it rather than guess at the timing.
    var isChildRunning: Bool { process.isRunning }

    /// Terminates the complete process group. A bare `terminate()` would leave
    /// anything the child spawned running, and a child that ignores SIGTERM
    /// would linger past the caller's deadline.
    ///
    /// The child exiting is not the tree exiting: `codex app-server` can spawn
    /// something of its own and leave, and that grandchild stays in the group
    /// `init` created, still holding the stdout it inherited. Firing
    /// `kill(-pid, …)` unconditionally once the child has been reaped would be
    /// the wrong answer though — the kernel is free to hand that number to an
    /// unrelated process — so the reaped path is gated on evidence that the
    /// tree is still ours: the group still has a member, and the read end has
    /// not reached end of file. `CommandRunner.run` reads the same evidence off
    /// its readers when the command is gone but its pipes are still held.
    func close() {
        // Teardown runs once. The probes call `close()` from a `defer` that can
        // follow an earlier one, and a second pass would wait on a handler that
        // is already gone before signalling a group that is already dead.
        condition.lock()
        let alreadyTornDown = tornDown
        tornDown = true
        condition.unlock()
        guard !alreadyTornDown else { return }

        try? input.fileHandleForWriting.close()

        let pid = process.processIdentifier
        if process.isRunning {
            signalGroup(pid, SIGTERM)
            process.terminate()
            if !waitForExit(within: 2) { signalGroup(pid, SIGKILL) }
        } else if groupHasMembers(pid) && !waitForEndOfOutput(within: 0.25) {
            // Grandchild territory. The waits are shorter than the running-child
            // path's so that the whole teardown still fits inside its two
            // seconds, and each one ends as soon as the pipe is finally
            // released rather than running to its bound.
            signalGroup(pid, SIGTERM)
            if !waitForEndOfOutput(within: 0.75) {
                signalGroup(pid, SIGKILL)
                _ = waitForEndOfOutput(within: 0.75)
            }
        }
        // Last, not first: while the handler is live it keeps draining, so a
        // descendant blocked writing into a full pipe can still reach its exit.
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        CommandRunner.deregisterLiveChild(pid)
    }

    /// Signals the child's complete process group. `init` gave the child a
    /// group of its own, so this reaches the grandchildren too; a bare signal
    /// to the child would orphan them.
    private func signalGroup(_ pid: pid_t, _ signal: Int32) {
        guard pid > 1 else { return }
        #if !os(Windows)
        _ = kill(-pid, signal)
        #endif
    }

    /// Whether anything is left in the child's process group. Signal `0` is
    /// delivered to nobody and only reports reachability, which is how a pid
    /// that has been reaped and reissued elsewhere is told apart from one whose
    /// group this process still owns: a group that is gone answers `ESRCH`, and
    /// one that is not ours to signal answers `EPERM`. Neither gets a signal.
    private func groupHasMembers(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        #if os(Windows)
        return false
        #else
        return kill(-pid, 0) == 0
        #endif
    }

    /// Waits for the read end to reach end of file, which happens only when
    /// every copy of the write end is closed — the child's, and every one it
    /// passed on. Returning false means the pipe is still held after the child
    /// itself is gone, which is the evidence a descendant is still alive.
    private func waitForEndOfOutput(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        defer { condition.unlock() }
        while !closed {
            guard condition.wait(until: deadline) else { return closed }
        }
        return true
    }

    private func waitForExit(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }
}
