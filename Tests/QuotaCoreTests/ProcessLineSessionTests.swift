import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import QuotaCore

/// The ends of a line session rather than its happy path: a child that reaches
/// end of file before the awaited line ever arrives, a final line with no
/// trailing newline, a deadline that expires while the child is halfway through
/// writing one, a write attempted after the pipe is gone, and a teardown facing
/// a child that ignores `SIGTERM` or that exited leaving a grandchild behind.
///
/// `QuotaCoreTests` covers the interleaved request/response exchange the Codex
/// probe depends on. Everything here drives `/bin/sh`, `/bin/echo` and — for
/// the grandchild cases — `bash`, with sub-second deadlines, so the real pipe
/// and signal behaviour is exercised without the suite getting slow.
final class ProcessLineSessionTests: XCTestCase {
    private var scratch = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-line-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - end of file

    /// A CLI that dies without answering must end the wait at once instead of
    /// holding the caller until the deadline, and the lines it did write have to
    /// survive in the transcript — that is where a probe looks for the
    /// authentication complaint explaining the silence.
    func testWaitForLineEndsAtEndOfFileWhenNoLineEverMatches() throws {
        let shell = try systemBinary("sh")
        let session = try ProcessLineSession(executable: shell, arguments: ["-c", "echo first; echo second"])
        defer { session.close() }

        var transcript: [String] = []
        let started = Date()
        let match = session.waitForLine(matching: { $0 == "never printed" },
                                        before: Date().addingTimeInterval(1.5),
                                        transcript: &transcript)
        XCTAssertNil(match)
        XCTAssertEqual(transcript, ["first", "second"], "every line seen is recorded, matching or not")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.4,
                          "end of file ends the wait rather than the deadline doing it")
    }

    /// Regression: the parent used to keep its own copy of the child's stdout
    /// write end, and a pipe reader sees end of file only when *every* write end
    /// is closed. Whether the wait ended at end of file or at the deadline then
    /// depended on when ARC happened to release that handle — the test above
    /// passed in about four milliseconds when it did and took the full deadline
    /// when it did not, failing perhaps three runs in five.
    ///
    /// One iteration cannot catch a race that loses only sometimes, so this
    /// repeats it: at eight iterations the old behaviour is caught essentially
    /// every time, and the fixed one costs a few milliseconds in total.
    func testEndOfFileEndsEveryWaitAndNotJustSomeOfThem() throws {
        let shell = try systemBinary("sh")
        for iteration in 1...8 {
            let session = try ProcessLineSession(executable: shell, arguments: ["-c", "echo first"])
            defer { session.close() }

            var transcript: [String] = []
            let started = Date()
            _ = session.waitForLine(matching: { $0 == "never printed" },
                                    before: Date().addingTimeInterval(1.5),
                                    transcript: &transcript)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                              "iteration \(iteration) waited for the deadline rather than end of file")
        }
    }

    /// Regression: a child that exits without terminating its last line used to
    /// have that line dropped, because only the text before a newline was ever
    /// promoted out of the buffer. The last line is usually the response.
    func testTheFinalLineIsDeliveredWhenTheChildOmitsTheTrailingNewline() throws {
        let shell = try systemBinary("sh")
        let session = try ProcessLineSession(executable: shell, arguments: ["-c", "printf 'first\\nlast'"])
        defer { session.close() }

        var transcript: [String] = []
        XCTAssertEqual(session.waitForLine(matching: { $0 == "last" },
                                           before: Date().addingTimeInterval(1.5),
                                           transcript: &transcript),
                       "last")
        XCTAssertEqual(transcript, ["first", "last"])
    }

    // MARK: - deadlines

    /// Half a line is not a line. A deadline that expires while the child is
    /// still writing one has to report nothing rather than a truncated line a
    /// parser would then read as malformed.
    func testADeadlineExpiringMidLineReportsNothingRatherThanAPartialLine() throws {
        let shell = try systemBinary("sh")
        let session = try ProcessLineSession(executable: shell,
                                             arguments: ["-c", "printf 'half a line'; sleep 5"])
        defer { session.close() }

        var transcript: [String] = []
        let started = Date()
        XCTAssertNil(session.waitForLine(matching: { _ in true },
                                         before: Date().addingTimeInterval(0.4),
                                         transcript: &transcript))
        XCTAssertTrue(transcript.isEmpty, "an unterminated line has not been read yet")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the deadline has to bound the wait")
    }

    // MARK: - send

    /// After teardown the write end is gone, so a further request cannot reach
    /// the child. That has to surface as an error rather than as a silent
    /// success the caller would then wait on for a reply that never comes.
    func testSendFailsOnceTheInputPipeIsClosed() throws {
        let cat = try systemBinary("cat")
        let session = try ProcessLineSession(executable: cat, arguments: [])
        try session.send("while the pipe is open")
        session.close()

        XCTAssertThrowsError(try session.send("after the pipe is closed"),
                             "a write into a closed pipe must not look like a delivered request")
    }

    /// The regression #34 was filed for, and the case the test above does *not*
    /// cover: there the local write end was closed, which fails with `EBADF` and
    /// throws under any signal disposition. Here the write end is still open and
    /// the *child* is gone, which is what the Codex probe hits when
    /// `codex app-server` exits between the initialize response and the
    /// `initialized`/`rateLimits` writes that follow it. That write returns
    /// `EPIPE` only because `SIGPIPE` is ignored; under the default disposition
    /// this test does not fail, it kills the test process with signal 13.
    func testSendThrowsRatherThanKillingTheProcessWhenTheChildHasExited() throws {
        let shell = try systemBinary("sh")
        // Exits immediately without ever reading stdin, leaving our write end open.
        let session = try ProcessLineSession(executable: shell, arguments: ["-c", "echo ready"])
        defer { session.close() }

        var transcript: [String] = []
        XCTAssertEqual(session.waitForLine(matching: { $0 == "ready" },
                                           before: Date().addingTimeInterval(2),
                                           transcript: &transcript), "ready")
        // Drains to end of file, which the child reaches only as it exits.
        _ = session.waitForLine(matching: { _ in false },
                                before: Date().addingTimeInterval(2),
                                transcript: &transcript)

        // The exit and the pipe teardown are not simultaneous, so the first write
        // can still land in the buffer. Reaching the deadline without throwing is
        // the failure; being killed by SIGPIPE never gets here at all.
        let deadline = Date().addingTimeInterval(2)
        var thrown: Error?
        while Date() < deadline && thrown == nil {
            do { try session.send("after the child exited") } catch { thrown = error }
        }
        XCTAssertNotNil(thrown, "a write to a dead child must surface as a thrown error")
    }

    // MARK: - close

    /// Nothing is left to signal once the child has exited on its own, and the
    /// probes call `close()` from a `defer` that can run after an earlier one.
    /// Neither may trap or stall.
    func testCloseIsBoundedAndRepeatableWhenTheChildHasAlreadyExited() throws {
        let echo = try systemBinary("echo")
        let session = try ProcessLineSession(executable: echo, arguments: ["done"])
        var transcript: [String] = []
        XCTAssertEqual(session.waitForLine(matching: { $0 == "done" },
                                           before: Date().addingTimeInterval(1.5),
                                           transcript: &transcript),
                       "done")

        let started = Date()
        session.close()
        session.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "closing an already finished session must not wait for an exit that happened")
    }

    /// A child that traps `SIGTERM` — the provider CLIs install handlers of
    /// their own — would otherwise outlive the app that started it. Teardown has
    /// to escalate to `SIGKILL` and still return bounded.
    func testCloseEscalatesToSIGKILLWhenTheChildIgnoresSIGTERM() throws {
        let shell = try systemBinary("sh")
        let pidFile = scratch.appendingPathComponent("stubborn.pid").path
        let session = try ProcessLineSession(executable: shell, arguments: [
            "-c", "trap '' TERM; echo $$ > '\(pidFile)'; echo ready; while : ; do sleep 0.2 ; done"
        ])

        var transcript: [String] = []
        XCTAssertEqual(session.waitForLine(matching: { $0 == "ready" },
                                           before: Date().addingTimeInterval(1.5),
                                           transcript: &transcript),
                       "ready")
        let child = try readPid(at: pidFile)

        let started = Date()
        session.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "the escalation stays bounded")
        XCTAssertTrue(waitUntil(3) { self.hasExited(child) },
                      "a child that ignores SIGTERM was left running after close()")
    }

    /// The case #76 was filed for. A provider CLI that hands its work to a
    /// helper and exits leaves that grandchild in the process group `init`
    /// created, still holding the stdout it inherited. Teardown used to keep
    /// every signal inside `if process.isRunning`, so once the direct child had
    /// been reaped nothing was signalled at all and the grandchild outlived the
    /// app that started it.
    func testCloseTerminatesAGrandchildThatOutlivedTheChild() throws {
        let shell = try systemBinary("sh")
        let childPid = scratch.appendingPathComponent("child.pid").path
        let grandchildPid = scratch.appendingPathComponent("grandchild.pid").path
        let session = try ProcessLineSession(executable: shell, arguments: [
            try grandchildScript(childPidFile: childPid,
                                 grandchildPidFile: grandchildPid,
                                 holdingOutput: true)
        ])

        var transcript: [String] = []
        XCTAssertEqual(session.waitForLine(matching: { $0 == "ready" },
                                           before: Date().addingTimeInterval(3),
                                           transcript: &transcript),
                       "ready")
        let child = try readPid(at: childPid)
        let grandchild = try readPid(at: grandchildPid)
        XCTAssertEqual(getpgid(grandchild), child,
                       "the grandchild has to be in the session's group for this to test anything")
        XCTAssertTrue(waitUntil(3) { !session.isChildRunning },
                      "the direct child has to be gone before close() for this to be the reaped path")

        let started = Date()
        session.close()
        // Repeating it is what the probes do from nested `defer`s, and the
        // second pass must not wait on a stream nobody is reading any more.
        session.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "teardown stays inside the bound the running-child path already spends")
        XCTAssertTrue(waitUntil(3) { self.hasExited(grandchild) },
                      "a grandchild holding the session's stdout was left running after close()")
    }

    /// The other half of that. A reaped pid belongs to the kernel again, so the
    /// only thing that justifies signalling its group is the stdout still being
    /// held: that pipe can only be held by something the child passed it to. A
    /// descendant that let go of the pipe is deliberately left alone rather
    /// than risk a signal landing on whatever now owns the number.
    func testCloseSignalsNothingWhenTheReapedChildLeftNoOneHoldingTheOutput() throws {
        let shell = try systemBinary("sh")
        let childPid = scratch.appendingPathComponent("child.pid").path
        let grandchildPid = scratch.appendingPathComponent("grandchild.pid").path
        let session = try ProcessLineSession(executable: shell, arguments: [
            try grandchildScript(childPidFile: childPid,
                                 grandchildPidFile: grandchildPid,
                                 holdingOutput: false)
        ])

        var transcript: [String] = []
        XCTAssertNil(session.waitForLine(matching: { _ in false },
                                         before: Date().addingTimeInterval(3),
                                         transcript: &transcript),
                     "the stream ends when the child exits, because nothing else holds the write end")
        XCTAssertEqual(transcript, ["ready"])
        let child = try readPid(at: childPid)
        let survivor = try readPid(at: grandchildPid)
        XCTAssertEqual(getpgid(survivor), child,
                       "a signal to the group would reach the survivor, which is what must not happen")
        XCTAssertTrue(waitUntil(3) { !session.isChildRunning },
                      "the direct child has to be gone before close() for this to be the reaped path")

        let started = Date()
        session.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "there is nothing to wait for once the stream has already ended")
        // Long enough for a SIGTERM to have been delivered and acted on.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(hasExited(survivor),
                       "close() signalled a process group it no longer has any claim to")
        // Nothing else will: it is not this process's child to wait on.
        _ = kill(survivor, SIGKILL)
    }

    // MARK: - Helpers

    private func systemBinary(_ name: String) throws -> String {
        let candidates = ["/bin/\(name)", "/usr/bin/\(name)"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("\(name) is not installed at a standard location on this machine")
        }
        return path
    }

    /// A child that spawns a grandchild and exits, the shape a provider CLI
    /// takes when it hands its work to a helper. The grandchild is forked only
    /// after a pause: the session sets the child's process group once `run()`
    /// has returned, and anything forked before that would land in this
    /// process's group instead and prove nothing.
    ///
    /// `holdingOutput` decides whether the grandchild keeps the stdout it
    /// inherited or redirects it away. That pipe is the only evidence teardown
    /// has left once the child itself has been reaped.
    ///
    /// The grandchild drops every inherited descriptor above stdio, which is
    /// what a helper meaning to outlive its launcher does anyway and is also
    /// what makes this reach the reaped path on Linux: swift-corelibs-foundation
    /// watches a socket it passes to the child, so a grandchild that keeps it
    /// open holds `Process.isRunning` at true for as long as it lives — measured
    /// here as the child sitting in state `Z` while Foundation still called it
    /// running. Darwin reports the exit either way, so the loop is a no-op cost
    /// there. `/dev/fd` names the open ones on both platforms, which a fixed
    /// range cannot: the whole suite has far more descriptors open than one test
    /// does, and Foundation's socket lands well above where a short range stops.
    /// It is `bash`, not `sh`: dash takes only single-digit descriptors in a
    /// redirection and reads `exec 30>&-` as a request to run a program called
    /// `30`, which replaces the grandchild with a failed exec.
    private func grandchildScript(childPidFile: String,
                                  grandchildPidFile: String,
                                  holdingOutput: Bool) throws -> String {
        let bash = try systemBinary("bash")
        let child = scratch.appendingPathComponent("child.sh")
        try """
        echo $$ > "\(childPidFile)"
        sleep 0.3
        \(bash) -c '
            for entry in /dev/fd/*; do
                fd="${entry##*/}"
                case "$fd" in
                    0|1|2|*[!0-9]*) continue ;;
                esac
                eval "exec $fd>&-"
            done
            echo $$ > "\(grandchildPidFile)"
            # Bounded, so a run where nothing signals the group cannot leave
            # this behind for the rest of the suite.
            count=0
            while [ $count -lt 100 ]; do
                sleep 0.2
                count=$((count + 1))
            done
        '\(holdingOutput ? "" : " > /dev/null") &
        echo ready
        """.write(to: child, atomically: true, encoding: .utf8)
        return child.path
    }

    /// Waits for a *readable* pid rather than for the file to exist: the shell
    /// creates it with the redirection and writes the number a moment later.
    private func readPid(at path: String) throws -> pid_t {
        XCTAssertTrue(waitUntil(2) { self.pid(at: path) != nil }, "the child never recorded its pid")
        return try XCTUnwrap(pid(at: path), "unreadable pid file")
    }

    private func pid(at path: String) -> pid_t? {
        let text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func hasExited(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return true }
        guard kill(pid, 0) == 0 else { return errno == ESRCH }
        #if os(Linux)
        // A killed child can sit around as an unreaped zombie when the
        // container's pid 1 does not reap; a zombie is not a running process.
        let stat = String(decoding: FileManager.default.contents(atPath: "/proc/\(pid)/stat") ?? Data(),
                          as: UTF8.self)
        if let afterName = stat.split(separator: ")").last,
           let state = afterName.split(separator: " ").first {
            return state == "Z"
        }
        #endif
        return false
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}
