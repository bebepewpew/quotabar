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
    /// The most an unterminated line may grow to before the session gives up on
    /// it. A JSON-RPC reply from `codex app-server` is a few kilobytes, so this
    /// is three orders of magnitude of headroom; past it the child is writing
    /// something that is not a line and the session stops reading rather than
    /// growing for as long as it keeps going.
    static let maximumLineBytes = 1024 * 1024
    /// The most undelivered output the queue holds. Together with the line
    /// ceiling this is what the session can cost, whether or not anybody drains
    /// it.
    static let maximumPendingBytes = 4 * 1024 * 1024
    /// What each queued line costs on top of its own bytes. A line is not free
    /// to hold: it occupies an array element and, unless it is short enough to
    /// live inline in the `String`, an allocation of its own. Charging only the
    /// bytes would bound nothing against a child writing empty or one-character
    /// lines — a megabyte of newlines is a million entries that cost nothing —
    /// so the queue charges a fixed overhead per line too, which caps the number
    /// of entries at `maximumPendingBytes / pendingEntryBytes` no matter how
    /// small each one is.
    static let pendingEntryBytes = 64
    /// What a caller's transcript retains: enough of the tail for a probe to
    /// find an authentication complaint, and no more.
    static let maximumTranscriptLines = 200
    static let maximumTranscriptBytes = 256 * 1024
    /// How long a single `send` may spend trying to hand a request over.
    static let sendTimeout: TimeInterval = 5

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()

    private var buffer = ""
    private var pending: [String] = []
    private var pendingHead = 0
    private var pendingBytes = 0
    private var closed = false
    private var inputClosed = false

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
                    enqueue(buffer)
                    buffer = ""
                }
                closed = true
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            buffer += chunk
            // Only a chunk carrying a newline can complete a line. Rescanning
            // the whole buffer for one that did not is what made a child writing
            // megabytes without a newline quadratic as well as unbounded.
            if chunk.contains("\n") {
                // Split in one pass. Cutting the buffer down line by line copies
                // everything after each newline again, which is quadratic in the
                // size of a chunk once a child writes lines by the thousand.
                var parts = buffer.split(separator: "\n", omittingEmptySubsequences: false)
                let remainder = parts.removeLast()
                for part in parts { enqueue(String(part)) }
                buffer = String(remainder)
            }
            guard buffer.utf8.count > Self.maximumLineBytes else { return }
            // A line with no end in sight. Handing over the head of it and
            // ending the session is the bounded answer; the alternative is to
            // keep the whole thing resident for as long as the child writes.
            enqueue(String(decoding: Array(buffer.utf8.prefix(Self.maximumLineBytes)), as: UTF8.self))
            buffer = ""
            closed = true
            handle.readabilityHandler = nil
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
        try send(line, within: Self.sendTimeout)
    }

    /// A pipe write also blocks once the child stops reading and the buffer
    /// fills, and `FileHandle.write` offers no way to bound that: one request
    /// would then silently consume the caller's whole deadline before a single
    /// reply had been awaited. The descriptor goes non-blocking for the write
    /// and `poll` supplies the bound instead. Giving up part-way leaves a
    /// truncated request in the pipe, which is why it is an error the caller
    /// ends the session on rather than something to retry.
    func send(_ line: String, within timeout: TimeInterval) throws {
        let payload = Data((line + "\n").utf8)
        condition.lock()
        let gone = inputClosed
        condition.unlock()
        guard !gone else { throw ProbeError.message("The CLI is no longer accepting input") }

        #if os(Windows)
        try input.fileHandleForWriting.write(contentsOf: payload)
        #else
        let descriptor = input.fileHandleForWriting.fileDescriptor
        guard descriptor >= 0 else { throw ProbeError.message("The CLI is no longer accepting input") }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { throw ProbeError.message("The CLI is no longer accepting input") }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }

        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < payload.count {
                let written = write(descriptor, base + offset, payload.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if code == EINTR { continue }
                guard code == EAGAIN || code == EWOULDBLOCK else {
                    throw ProbeError.message("The CLI is no longer accepting input")
                }
                try Self.waitUntilWritable(descriptor, before: deadline)
            }
        }
        #endif
    }

    #if !os(Windows)
    private static func waitUntilWritable(_ descriptor: Int32, before deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw ProbeError.message("The CLI is not reading its input") }
        var watched = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&watched, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
        if ready < 0 {
            guard errno == EINTR else { throw ProbeError.message("The CLI is no longer accepting input") }
            return
        }
        guard ready > 0 else { throw ProbeError.message("The CLI is not reading its input") }
    }
    #endif

    /// Reads lines until one satisfies `matches` or the deadline passes. Every
    /// line seen is appended to `transcript`, so callers can inspect the whole
    /// exchange when looking for an authentication complaint.
    func waitForLine(matching matches: (String) -> Bool,
                     before deadline: Date,
                     transcript: inout [String]) -> String? {
        while let line = nextLine(before: deadline) {
            Self.retain(line, in: &transcript)
            if matches(line) { return line }
        }
        return nil
    }

    /// Appends to a caller's transcript, keeping the most recent lines within
    /// both ceilings — the same reason `CommandRunner.diagnostic` reads only the
    /// tail of a stream. A transcript exists so a probe can find an
    /// authentication complaint in what the CLI said; a child that says a great
    /// deal must not be able to use it as unbounded storage in the caller.
    static func retain(_ line: String, in transcript: inout [String]) {
        transcript.append(line)
        var bytes = 0, keep = 0
        for candidate in transcript.reversed() {
            bytes += candidate.utf8.count
            if keep > 0 && bytes > maximumTranscriptBytes { break }
            keep += 1
            if keep == maximumTranscriptLines { break }
        }
        if keep < transcript.count { transcript.removeFirst(transcript.count - keep) }
    }

    /// Queues a line for delivery, dropping the oldest undelivered ones once the
    /// queue passes its ceiling. The caller holds `condition`.
    ///
    /// The exchange is request/response, so the line being waited for is the
    /// newest one: a child that outruns its consumer loses its backlog rather
    /// than the reply, and the session's cost stays bounded either way. Each
    /// line is charged `pendingEntryBytes` on top of its own, so the ceiling
    /// bounds a flood of empty lines by count as well as one of long lines by
    /// size.
    private func enqueue(_ line: String) {
        pending.append(line)
        pendingBytes += line.utf8.count + Self.pendingEntryBytes
        while pendingBytes > Self.maximumPendingBytes && pending.count - pendingHead > 1 {
            _ = dequeue()
        }
    }

    /// Takes the oldest queued line. The read position moves rather than the
    /// array: `removeFirst` shifts everything behind it, which turns both
    /// draining and dropping into quadratic work once a child has put thousands
    /// of lines in the queue. The array is compacted when most of it is spent.
    private func dequeue() -> String? {
        guard pendingHead < pending.count else { return nil }
        let line = pending[pendingHead]
        pending[pendingHead] = ""
        pendingHead += 1
        pendingBytes -= line.utf8.count + Self.pendingEntryBytes
        if pendingHead >= 1_024 && pendingHead * 2 >= pending.count {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
        return line
    }

    private func nextLine(before deadline: Date) -> String? {
        condition.lock()
        defer { condition.unlock() }
        while pendingHead == pending.count && !closed {
            guard condition.wait(until: deadline) else { return nil }
        }
        return dequeue()
    }

    /// Terminates the complete process group. A bare `terminate()` would leave
    /// anything the child spawned running, and a child that ignores SIGTERM
    /// would linger past the caller's deadline.
    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        condition.lock()
        inputClosed = true
        condition.broadcast()
        condition.unlock()
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
        CommandRunner.deregisterLiveChild(pid)
    }

    private func waitForExit(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }
}
