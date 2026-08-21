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
/// a child that ignores `SIGTERM`.
///
/// `QuotaCoreTests` covers the interleaved request/response exchange the Codex
/// probe depends on. Everything here drives `/bin/sh` and `/bin/echo` with
/// sub-second deadlines, so the real pipe and signal behaviour is exercised
/// without the suite getting slow.
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

    // MARK: - Helpers

    private func systemBinary(_ name: String) throws -> String {
        let candidates = ["/bin/\(name)", "/usr/bin/\(name)"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("\(name) is not installed at a standard location on this machine")
        }
        return path
    }

    private func readPid(at path: String) throws -> pid_t {
        XCTAssertTrue(waitUntil(2) { FileManager.default.fileExists(atPath: path) },
                      "the child never recorded its pid")
        let text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                             "unreadable pid file: \(text)")
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
