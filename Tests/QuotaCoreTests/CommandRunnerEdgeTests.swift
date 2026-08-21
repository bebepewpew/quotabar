import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import QuotaCore

/// The paths `CommandRunnerTests` leaves untouched: what happens when the known
/// install locations come up empty and the login-shell fallback has to answer,
/// when the configured shell rejects the flags it is handed, when the process
/// starts with no `PATH` at all, and when `runExpect` actually reaches a binary.
///
/// The fallback normally depends on whatever shells and CLIs the machine
/// happens to have, which is not something a test can assert against. So
/// `$SHELL` is pointed at a small script that stands in for the login shell —
/// one that answers `command -v`, and one that refuses its flags the way
/// nushell, elvish and restricted shells do. Everything here is a real process
/// with a short deadline.
final class CommandRunnerEdgeTests: XCTestCase {
    private var scratch = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-command-runner-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - find: the login-shell fallback

    /// Version managers put their shims on a `PATH` that only an interactive
    /// login shell sets up, so an executable in none of the known locations has
    /// to be resolvable through `command -v` — and the answer has to be checked
    /// for being executable rather than trusted as printed.
    func testFindResolvesThroughTheLoginShellWhenNoKnownLocationHasIt() throws {
        try requireLiveEnvironment()
        let name = "quotabar-shim-\(UUID().uuidString.prefix(8))"
        let installed = try makeExecutable(named: name, in: scratch.appendingPathComponent("version-manager"))
        let shell = try makeShell(named: "answering-shell", body: """
        echo 'not-a-path'
        echo '\(installed)'
        """)
        let empty = scratch.appendingPathComponent("empty-path")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        try withEnvironment(["SHELL": shell, "PATH": empty.path]) {
            XCTAssertEqual(CommandRunner.find(name), installed,
                           "the last executable line the shell printed is the installation")
        }
    }

    /// What a shell prints for `command -v` is a claim, not an installation:
    /// "not found" messages and paths to files that are gone or unreadable have
    /// to be discarded rather than handed back as a binary to execute.
    func testFindIgnoresAShellAnswerThatIsNotAnExecutableFile() throws {
        try requireLiveEnvironment()
        let name = "quotabar-absent-\(UUID().uuidString.prefix(8))"
        let shell = try makeShell(named: "lying-shell", body: """
        echo '\(name): not found'
        echo '/nowhere/\(name)'
        """)
        let empty = scratch.appendingPathComponent("empty-path")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        try withEnvironment(["SHELL": shell, "PATH": empty.path]) {
            XCTAssertNil(CommandRunner.find(name))
        }
    }

    /// A `$SHELL` that exits rather than accepting `-lc`/`-lic` must not make
    /// every provider look uninstalled: the candidate is skipped and the search
    /// carries on through the remaining shells.
    func testFindTriesTheNextCandidateWhenTheConfiguredShellRejectsItsFlags() throws {
        try requireLiveEnvironment()
        let log = scratch.appendingPathComponent("rejected.log").path
        let shell = try makeShell(named: "rejecting-shell", body: """
        echo "$@" >> "\(log)"
        exit 2
        """)
        let name = "quotabar-absent-\(UUID().uuidString.prefix(8))"

        let started = Date()
        try withEnvironment(["SHELL": shell]) {
            XCTAssertNil(CommandRunner.find(name))
            XCTAssertGreaterThan(CommandRunner.loginShells().count, 1,
                                 "a rejecting shell is only the first of several candidates")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "the fallback stays bounded")

        let recorded = String(decoding: FileManager.default.contents(atPath: log) ?? Data(), as: UTF8.self)
        XCTAssertTrue(recorded.contains("command -v -- \(name)"),
                      "the configured shell was never asked: \(recorded)")
    }

    /// A menu-bar app launched by `launchd` can start with no `PATH` at all.
    /// The search then rests entirely on the known locations and the login
    /// shell, and must still come back rather than trapping on the missing
    /// variable.
    func testFindStillAnswersWhenTheProcessHasNoPathAtAll() throws {
        try requireLiveEnvironment()
        let name = "quotabar-shim-\(UUID().uuidString.prefix(8))"
        let installed = try makeExecutable(named: name, in: scratch.appendingPathComponent("no-path-install"))
        let shell = try makeShell(named: "answering-shell", body: "echo '\(installed)'")

        try withEnvironment(["SHELL": shell, "PATH": nil]) {
            XCTAssertEqual(CommandRunner.find(name), installed)
        }
    }

    // MARK: - runExpect

    /// `CommandRunnerTests` covers the missing-`expect` branch and, where
    /// `expect` is installed, the real round trip. Neither reaches the forwarding
    /// in between on a machine without it, which a stub named `expect` on `PATH`
    /// does: the script has to arrive as the argument of `-c`, and the binary's
    /// output has to come back decoded and unmodified.
    func testRunExpectForwardsTheScriptToTheResolvedBinaryAndReturnsItsOutput() throws {
        try requireLiveEnvironment()
        let directory = scratch.appendingPathComponent("expect-stub")
        let stub = try makeExecutable(named: "expect", in: directory, body: """
        echo "flag=$1"
        echo "$2"
        """)

        try withEnvironment(["PATH": directory.path]) {
            guard CommandRunner.find("expect") == stub else {
                throw XCTSkip("a real expect is installed in a known location, so the stub cannot be reached")
            }
            let output = try CommandRunner.runExpect("puts quotabar", timeout: 5)
            XCTAssertEqual(output, "flag=-c\nputs quotabar\n")
        }
    }

    // MARK: - Helpers

    /// A script that stands in for a login shell. It is deliberately indifferent
    /// to the flags it is given, so the test is about `find`'s handling of the
    /// answer rather than about any real shell's dialect.
    private func makeShell(named name: String, body: String) throws -> String {
        try makeExecutable(named: name, in: scratch.appendingPathComponent("shells"), body: body)
    }

    @discardableResult
    private func makeExecutable(named name: String, in directory: URL,
                                body: String = "exit 0") throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Stages environment variables for the duration of `body` and restores
    /// them afterwards; a `nil` value removes the variable entirely.
    private func withEnvironment(_ values: [String: String?], _ body: () throws -> Void) rethrows {
        var previous: [String: String?] = [:]
        for key in values.keys { previous[key] = ProcessInfo.processInfo.environment[key] }
        for (key, value) in values {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        try body()
    }

    /// `find` and `loginShells` read the environment through `ProcessInfo`, and
    /// a Foundation that snapshots it once cannot be driven from a test.
    private func requireLiveEnvironment() throws {
        let name = "QUOTABAR_ENV_PROBE_\(UUID().uuidString.prefix(8))"
        setenv(name, "1", 1)
        defer { unsetenv(name) }
        guard ProcessInfo.processInfo.environment[name] == "1" else {
            throw XCTSkip("ProcessInfo snapshots the environment here, so the search cannot be staged")
        }
    }
    // MARK: - SIGPIPE

    /// The `CommandRunner` half of #34. A child that exits without reading its
    /// stdin leaves `input` writing into a pipe with no reader; under the default
    /// signal disposition that killed the whole process with signal 13 instead of
    /// failing one refresh. The command's own exit status is what gets reported.
    func testRunSurvivesAChildThatExitsWithoutReadingItsInput() throws {
        let shell = try systemBinary("sh")
        // Large enough that the write cannot all sit in the pipe buffer.
        let payload = Data(String(repeating: "x", count: 512 * 1024).utf8)

        let output = try CommandRunner.run(shell, ["-c", "echo done"], input: payload, timeout: 5)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "done\n",
                       "the child's output is returned rather than the process dying on SIGPIPE")
    }

    /// The same path when the child also fails: what is reported has to be the
    /// child's own failure, not the broken pipe the input write hit. The exit
    /// status is what says so — the child's stderr is kept for classification
    /// and stays out of the message.
    func testRunReportsTheChildsFailureRatherThanTheBrokenInputPipe() throws {
        let shell = try systemBinary("sh")
        let payload = Data(String(repeating: "x", count: 512 * 1024).utf8)

        XCTAssertThrowsError(
            try CommandRunner.run(shell, ["-c", "echo refused >&2; exit 3"], input: payload, timeout: 5)
        ) { error in
            guard case .commandFailed(let failure)? = error as? ProbeError else {
                return XCTFail("expected the child's own failure, got \(error)")
            }
            XCTAssertEqual(failure.status, 3, "the child's exit status explains this better than EPIPE does")
            XCTAssertEqual(failure.detail, "refused", "the child's stderr is kept for a probe to classify")
            XCTAssertFalse("\(failure.message)".contains("refused"), "…and never shown")
        }
    }

    /// `ignoreBrokenPipe` is what makes the two tests above possible, asserted on
    /// a bare POSIX pipe so nothing else can explain the result. It is called
    /// twice because every seam that owns a pipe requests it.
    ///
    /// Without the disposition installed, this does not fail — the `write` below
    /// raises `SIGPIPE` and kills the test process.
    func testIgnoreBrokenPipeTurnsAWriteWithNoReaderIntoEPIPE() throws {
        ProcessSignals.ignoreBrokenPipe()
        ProcessSignals.ignoreBrokenPipe()

        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        close(descriptors[0])
        defer { close(descriptors[1]) }

        var byte: UInt8 = 0x41
        errno = 0
        XCTAssertEqual(write(descriptors[1], &byte, 1), -1)
        XCTAssertEqual(errno, EPIPE, "the write has to report a broken pipe instead of signalling one")
    }

    // MARK: - Fixtures

    private func systemBinary(_ name: String) throws -> String {
        let candidates = ["/bin/\(name)", "/usr/bin/\(name)"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("\(name) is not installed at a standard location on this machine")
        }
        return path
    }

    /// Guards the invariant `ProcessLineSessionTests` covers for the other pipe:
    /// output arrives when the child closes its end, not when a fallback timer
    /// gives up.
    ///
    /// Be clear about what this does not do. Removing the two `close()` calls in
    /// `CommandRunner.run` does **not** make this fail — it was tried, and eight
    /// iterations passed in eight milliseconds either way, because nothing here
    /// keeps the pipe alive the way a stored property does. So this is a guard
    /// against the invariant being broken later, not proof that it was broken;
    /// the failing test for that defect is in `ProcessLineSessionTests`.
    func testOutputArrivesAtEndOfFileRatherThanAtTheReaderFallback() throws {
        let shell = try systemBinary("sh")
        for iteration in 1...8 {
            let started = Date()
            let data = try CommandRunner.run(shell, ["-c", "echo ready"])
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "ready\n",
                           "iteration \(iteration) lost the child's output")
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                              "iteration \(iteration) waited for the reader fallback rather than end of file")
        }
    }
}
