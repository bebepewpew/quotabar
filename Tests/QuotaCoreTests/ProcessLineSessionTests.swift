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

    // MARK: - ceilings

    /// A child writing megabytes without a newline used to grow the buffer for
    /// as long as it kept going, because none of it was a line yet — 64 MB of it
    /// here. The bounded answer is the head of that line and an ended session,
    /// so what the app holds is the stated ceiling rather than whatever the
    /// child felt like writing.
    ///
    /// Against the old behaviour the first wait returns nothing at all: there is
    /// no newline in the whole flood, so it runs to its deadline having buffered
    /// every byte of it.
    func testAnEndlessLineIsTruncatedOnceAndEndsTheSession() throws {
        let shell = try systemBinary("sh")
        let session = try ProcessLineSession(
            executable: shell, arguments: ["-c", "head -c 67108864 /dev/zero | tr '\\0' 'a'"])
        defer { session.close() }

        var transcript: [String] = []
        let line = session.waitForLine(matching: { _ in true },
                                       before: Date().addingTimeInterval(10),
                                       transcript: &transcript)
        XCTAssertEqual(line?.utf8.count, ProcessLineSession.maximumLineBytes,
                       "the head of the line is handed over, clamped to the ceiling")
        XCTAssertEqual(transcript.count, 1, "a line with no end yields one truncated line and no more")

        let started = Date()
        XCTAssertNil(session.waitForLine(matching: { _ in true },
                                         before: Date().addingTimeInterval(5),
                                         transcript: &transcript),
                     "the session ends instead of reading the rest of the flood")
        XCTAssertEqual(transcript.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "an ended session answers at once")
    }

    /// The transcript is there so a probe can find an authentication complaint
    /// in what the CLI said, not so a chatty child can grow an array inside the
    /// caller. It keeps the tail, the way a diagnostic does.
    func testTheTranscriptRetainsOnlyTheMostRecentLines() throws {
        let shell = try systemBinary("sh")
        let session = try ProcessLineSession(
            executable: shell,
            arguments: ["-c", "i=0; while [ $i -lt 1000 ]; do echo line-$i; i=$((i+1)); done"])
        defer { session.close() }

        var transcript: [String] = []
        XCTAssertNil(session.waitForLine(matching: { $0 == "never printed" },
                                         before: Date().addingTimeInterval(10),
                                         transcript: &transcript))
        XCTAssertEqual(transcript.count, ProcessLineSession.maximumTranscriptLines,
                       "1,000 lines were written and every one of them was kept")
        XCTAssertEqual(transcript.first, "line-800")
        XCTAssertEqual(transcript.last, "line-999")
    }

    /// Both transcript ceilings at their exact boundary, with no child in the
    /// way. A single line larger than the byte ceiling is still kept: the
    /// alternative is a transcript that silently holds nothing at all.
    func testTheTranscriptCeilingsHoldExactlyAtTheirBoundary() {
        var counted: [String] = []
        for index in 0...ProcessLineSession.maximumTranscriptLines {
            ProcessLineSession.retain("line-\(index)", in: &counted)
        }
        XCTAssertEqual(counted.count, ProcessLineSession.maximumTranscriptLines)
        XCTAssertEqual(counted.first, "line-1", "the oldest line is the one that goes")

        var bulky: [String] = []
        let chunk = String(repeating: "a", count: 100_000)
        for _ in 0..<5 { ProcessLineSession.retain(chunk, in: &bulky) }
        XCTAssertEqual(bulky.count, 2, "two of these fit under the byte ceiling and a third does not")
        XCTAssertLessThanOrEqual(bulky.reduce(0) { $0 + $1.utf8.count },
                                 ProcessLineSession.maximumTranscriptBytes)

        var oversized: [String] = []
        ProcessLineSession.retain(String(repeating: "b", count: ProcessLineSession.maximumTranscriptBytes + 1),
                                  in: &oversized)
        XCTAssertEqual(oversized.count, 1, "the newest line is kept even when it alone passes the ceiling")
    }

    /// The other place a child could grow: lines that have arrived and nobody
    /// has drained yet. Past the queue's ceiling the oldest go, so the session
    /// costs the same whether or not a consumer is keeping up — and the reply a
    /// caller waits for, which is the newest line, survives.
    func testTheUndeliveredQueueDropsItsBacklogRatherThanGrowing() throws {
        let shell = try systemBinary("sh")
        let marker = scratch.appendingPathComponent("flood-finished").path
        let payload = String(repeating: "q", count: 8 * 1024)
        let session = try ProcessLineSession(
            executable: shell, arguments: ["-c", "yes '\(payload)' | head -n 1200; touch '\(marker)'"])
        defer { session.close() }

        XCTAssertTrue(waitUntil(30) { FileManager.default.fileExists(atPath: marker) },
                      "the child never finished writing its flood")
        // Whatever was left in the pipe when the child exited is still on its
        // way into the queue, and the queue is what this measures.
        Thread.sleep(forTimeInterval: 0.5)

        // Everything queued comes back without blocking; the deadline only
        // covers the wait for end of file once the queue is empty.
        var delivered = 0
        var transcript: [String] = []
        _ = session.waitForLine(matching: { _ in delivered += 1; return false },
                                before: Date().addingTimeInterval(2),
                                transcript: &transcript)
        XCTAssertGreaterThan(delivered, 100, "the queue holds the newest lines rather than dropping everything")
        XCTAssertLessThan(delivered, 900,
                          "all 1,200 lines were still queued, so nothing bounds what the queue holds")
        XCTAssertEqual(transcript.last, payload, "the newest line is the one that survives")
    }

    /// The same ceiling against the cheapest line there is. Charging the queue
    /// only the bytes of each line bounded nothing here: an empty line costs
    /// zero bytes, so `pendingBytes` never moved and the drop loop never ran,
    /// while the array grew one entry per newline for as long as the child kept
    /// writing them — a megabyte of newlines is a million entries that were all
    /// free, tens of megabytes of storage out of a megabyte of output.
    /// A fixed cost per entry is what turns the byte ceiling into a count
    /// ceiling as well.
    ///
    /// Against that behaviour the `oldest` line written before the flood is
    /// still queued behind every one of them, and the count runs past the
    /// ceiling.
    func testTheUndeliveredQueueBoundsAFloodOfEmptyLines() throws {
        let shell = try systemBinary("sh")
        let marker = scratch.appendingPathComponent("newlines-finished").path
        let ceiling = ProcessLineSession.maximumPendingBytes / ProcessLineSession.pendingEntryBytes
        // Four times what the queue may hold, so that the newlines the reader
        // has taken by the time the child finishes — everything but the pipe
        // buffer's worth still in flight — are well past the ceiling.
        let lines = 4 * ceiling
        let session = try ProcessLineSession(
            executable: shell,
            arguments: ["-c", "printf 'oldest\\n'; head -c \(lines) /dev/zero | tr '\\0' '\\n';"
                              + " touch '\(marker)'"])
        defer { session.close() }

        XCTAssertTrue(waitUntil(60) { FileManager.default.fileExists(atPath: marker) },
                      "the child never finished writing its newlines")
        // What was still in the pipe when the child exited is on its way into
        // the queue, and the queue is what this measures.
        Thread.sleep(forTimeInterval: 0.5)

        // Matching one line past the ceiling stops the drain there, so an
        // unbounded queue fails the count below rather than taking as long as
        // it takes to hand over everything it kept. The slack is for anything
        // the reader had not queued yet when the drain began; the deadline only
        // covers the wait once the queue is empty, never the drain itself.
        var delivered = 0
        var first: String?
        var transcript: [String] = []
        _ = session.waitForLine(matching: { line in
                                    if first == nil { first = line }
                                    delivered += 1
                                    return delivered > ceiling + 1_024
                                },
                                before: Date().addingTimeInterval(1),
                                transcript: &transcript)
        XCTAssertEqual(first, "",
                       "\(lines) empty lines followed `oldest` and it was still queued behind them")
        XCTAssertLessThanOrEqual(delivered, ceiling + 1_024,
                                 "nothing bounds how many lines the queue holds")
        XCTAssertGreaterThan(delivered, 1_000,
                             "the queue keeps the newest lines rather than dropping everything")
    }

    // MARK: - send

    /// A pipe write blocks once the child stops reading and the buffer fills.
    /// Unbounded, one request would consume the caller's whole deadline before a
    /// reply had even been awaited — and against the old behaviour this test
    /// does not fail, it hangs: `FileHandle.write` never comes back.
    func testSendGivesUpWhenTheChildIsNotReadingItsInput() throws {
        let shell = try systemBinary("sh")
        // Never reads stdin, so the pipe fills and stays full.
        let session = try ProcessLineSession(executable: shell, arguments: ["-c", "sleep 10"])
        defer { session.close() }

        let started = Date()
        XCTAssertThrowsError(try session.send(String(repeating: "x", count: 4 * 1024 * 1024), within: 0.3),
                             "a write that cannot complete has to surface rather than block")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the write is bounded by its own deadline")
    }

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
