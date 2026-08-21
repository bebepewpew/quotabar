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
        // Every case here stages `$PATH`/`$SHELL` and then asks `find`, so each
        // has to start from a memo that remembers nothing from the last one.
        CommandRunner.resetDiscoveryMemo()
    }

    override func tearDown() {
        CommandRunner.resetDiscoveryMemo()
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

    // MARK: - find: the discovery memo

    /// Issue #78. A binary that is genuinely absent makes `find` run every
    /// candidate in the ladder, and nothing about the answer changes within a
    /// process — yet the Gemini probe asked for `expect` on every refresh, so a
    /// user with Gemini installed and no `expect` re-executed their interactive
    /// startup files forever. The second search must not reach a shell at all.
    func testFindAsksTheLoginShellLadderOnlyOnceForABinaryThatIsNotInstalled() throws {
        try requireLiveEnvironment()
        let log = scratch.appendingPathComponent("ladder.log").path
        let shell = try makeCountingShell(loggingTo: log)
        let name = "quotabar-absent-\(UUID().uuidString.prefix(8))"
        let empty = try emptyDirectory()

        withEnvironment(["SHELL": shell, "PATH": empty.path]) {
            XCTAssertNil(CommandRunner.find(name))
            XCTAssertEqual(ladderRuns(loggedAt: log).count, 1, "the first search has to ask")

            XCTAssertNil(CommandRunner.find(name))
            XCTAssertEqual(ladderRuns(loggedAt: log).count, 1,
                           "the second search re-ran the login-shell ladder: \(ladderRuns(loggedAt: log))")

            // The seam the tests rely on, and the only way anything forgets an
            // answer before its lifetime is up.
            CommandRunner.resetDiscoveryMemo()
            XCTAssertNil(CommandRunner.find(name))
            XCTAssertEqual(ladderRuns(loggedAt: log).count, 2, "a reset memo has to ask again")
        }
    }

    /// A hit costs the same ladder as a miss, so it is remembered too — and the
    /// path handed back stays the one the shell resolved.
    func testAPathTheLadderResolvedIsRememberedRatherThanAskedForAgain() throws {
        try requireLiveEnvironment()
        let name = "quotabar-shim-\(UUID().uuidString.prefix(8))"
        let installed = try makeExecutable(named: name, in: scratch.appendingPathComponent("version-manager"))
        let log = scratch.appendingPathComponent("resolving.log").path
        let shell = try makeShell(named: "resolving-shell", body: """
        echo "$@" >> "\(log)"
        echo '\(installed)'
        """)
        let empty = try emptyDirectory()

        withEnvironment(["SHELL": shell, "PATH": empty.path]) {
            XCTAssertEqual(CommandRunner.find(name), installed)
            XCTAssertEqual(CommandRunner.find(name), installed)
            XCTAssertEqual(ladderRuns(loggedAt: log).count, 1,
                           "the second search asked a login shell for a path it already had")
        }
    }

    /// The acceptance criterion of #78, through the probe that pays for it:
    /// `GeminiTerminalProbe.fetch()` resolves `gemini` and then asks
    /// `CommandRunner.runExpect` for `expect`, which is what runs the ladder.
    func testRepeatedGeminiProbesAskTheLoginShellLadderAtMostOnce() throws {
        try requireLiveEnvironment()
        let installed = scratch.appendingPathComponent("provider-bin")
        try makeExecutable(named: "gemini", in: installed)
        let log = scratch.appendingPathComponent("gemini-ladder.log").path
        let shell = try makeCountingShell(loggingTo: log)

        try withEnvironment(["SHELL": shell, "PATH": installed.path]) {
            guard CommandRunner.find("expect") == nil else {
                throw XCTSkip("expect is installed in a known location here, so the ladder never runs")
            }
            CommandRunner.resetDiscoveryMemo()
            try? FileManager.default.removeItem(atPath: log)

            for attempt in 1...2 {
                XCTAssertThrowsError(try GeminiTerminalProbe().fetch(), "refresh \(attempt)") { error in
                    XCTAssertEqual((error as? ProbeError)?.errorDescription, CommandRunner.expectInstallHint)
                }
            }

            let asked = ladderRuns(loggedAt: log)
            XCTAssertEqual(asked.count, 1, "two refreshes ran the login-shell ladder twice: \(asked)")
            XCTAssertTrue(asked.first?.contains("command -v -- expect") == true,
                          "the ladder asked for something else: \(asked)")
        }
    }

    /// The invalidation half of the memo, and why it does not turn "install
    /// expect, then refresh" into "install expect, then restart QuotaBar": only
    /// the ladder is remembered, so the known locations and `$PATH` are still
    /// searched on every call and an install lands immediately.
    func testARememberedMissDoesNotHideABinaryThatIsInstalledAfterwards() throws {
        try requireLiveEnvironment()
        let log = scratch.appendingPathComponent("ladder.log").path
        let shell = try makeCountingShell(loggingTo: log)
        let name = "quotabar-late-\(UUID().uuidString.prefix(8))"
        let directory = try emptyDirectory()

        try withEnvironment(["SHELL": shell, "PATH": directory.path]) {
            XCTAssertNil(CommandRunner.find(name))

            let installed = try makeExecutable(named: name, in: directory)
            XCTAssertEqual(CommandRunner.find(name), installed,
                           "a remembered miss must not outlive the install that answers it")
            XCTAssertEqual(ladderRuns(loggedAt: log).count, 1,
                           "the cheap half of the search answers without asking a shell again")
        }
    }

    /// `$PATH` and `$SHELL` decide what the ladder can see, so they are part of
    /// what is remembered rather than something a stale entry can outlive.
    func testAChangedEnvironmentIsNotAnsweredFromTheOldMemo() throws {
        try requireLiveEnvironment()
        let name = "quotabar-shim-\(UUID().uuidString.prefix(8))"
        let installed = try makeExecutable(named: name, in: scratch.appendingPathComponent("version-manager"))
        let silent = try makeShell(named: "silent-shell", body: "exit 1")
        let answering = try makeShell(named: "answering-shell", body: "echo '\(installed)'")
        let empty = try emptyDirectory()

        withEnvironment(["SHELL": silent, "PATH": empty.path]) {
            XCTAssertNil(CommandRunner.find(name))
        }
        withEnvironment(["SHELL": answering, "PATH": empty.path]) {
            XCTAssertEqual(CommandRunner.find(name), installed,
                           "the miss was remembered for a shell that is no longer the one being used")
        }
    }

    /// A miss is only trusted for `missLifetime`; after that the ladder is asked
    /// again, so an install that only an interactive login shell can see becomes
    /// visible without restarting QuotaBar.
    func testARememberedMissExpiresSoTheLadderIsAskedAgain() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let memo = DiscoveryMemo(now: { clock }, isExecutable: { _ in true })
        let key = DiscoveryMemo.Key(executable: "expect", path: "/usr/bin", shell: "/bin/zsh")

        XCTAssertEqual(memo.recall(key), .unknown, "nothing is remembered before the first search")
        memo.remember(nil, for: key)
        XCTAssertEqual(memo.recall(key), .absent)

        clock += DiscoveryMemo.missLifetime - 1
        XCTAssertEqual(memo.recall(key), .absent, "the answer is still fresh a second before it expires")

        clock += 2
        XCTAssertEqual(memo.recall(key), .unknown, "an expired miss has to be asked again")
        XCTAssertEqual(memo.recall(key), .unknown, "and stays forgotten")
    }

    /// A remembered path is a claim about a file that can be uninstalled while
    /// QuotaBar runs, so it is checked before it is handed back.
    func testARememberedHitIsDroppedOnceItsBinaryIsGone() {
        var installed = true
        let memo = DiscoveryMemo(isExecutable: { _ in installed })
        let key = DiscoveryMemo.Key(executable: "gemini", path: "/usr/bin", shell: "/bin/zsh")
        memo.remember("/home/user/.nvm/bin/gemini", for: key)

        XCTAssertEqual(memo.recall(key), .resolved("/home/user/.nvm/bin/gemini"))
        installed = false
        XCTAssertEqual(memo.recall(key), .unknown, "an uninstalled binary must not be handed back as a path to run")

        installed = true
        XCTAssertEqual(memo.recall(key), .unknown, "the dropped entry is gone rather than merely hidden")
    }

    func testResettingTheMemoForgetsEverythingItHeld() {
        let memo = DiscoveryMemo()
        let absent = DiscoveryMemo.Key(executable: "expect", path: "/usr/bin", shell: "/bin/sh")
        let resolved = DiscoveryMemo.Key(executable: "sh", path: "/usr/bin", shell: "/bin/sh")
        memo.remember(nil, for: absent)
        memo.remember("/bin/sh", for: resolved)

        memo.reset()

        XCTAssertEqual(memo.recall(absent), .unknown)
        XCTAssertEqual(memo.recall(resolved), .unknown)
    }

    // MARK: - loginShells

    /// Two spellings of one shell under one name are one candidate. On a
    /// merged-`/usr` Linux `/bin/bash` and `/usr/bin/bash` are the same file,
    /// and running the user's startup files twice to learn the same answer is
    /// pure cost. The symlink here carries its target's own basename, because
    /// that is the case the merged-`/usr` duplicate is: same file, same
    /// invocation name, two paths.
    func testLoginShellsListAnExecutableOnceEvenUnderSeveralPaths() throws {
        try requireLiveEnvironment()
        let target = try systemBinary("sh")
        let directory = scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent(URL(fileURLWithPath: target).lastPathComponent)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)

        withEnvironment(["SHELL": link.path]) {
            let shells = CommandRunner.loginShells()
            XCTAssertEqual(shells.first?.path, link.path, "the configured shell is still tried first")
            XCTAssertFalse(shells.dropFirst().contains { $0.path == target },
                           "the symlinked shell and its target are one candidate: \(shells.map(\.path))")

            let invocations = shells.map { Self.invocation($0) }
            XCTAssertEqual(Set(invocations).count, invocations.count,
                           "one shell was going to be asked the same question twice: \(invocations)")
        }
    }

    /// The other half of that rule: bash decides from `argv[0]` whether it is
    /// restricted, so `/bin/rbash` and `/bin/bash` are one file and two shells.
    /// Collapsing them would leave a user whose `$SHELL` is a restricted shell —
    /// or a bash-backed `/bin/sh` — with no rung that sources `~/.bashrc`, which
    /// is exactly where a version manager puts its shims.
    func testLoginShellsKeepAShellWhoseNameChangesWhatItDoes() throws {
        try requireLiveEnvironment()
        let bash = try systemBinary("bash")
        let restricted = scratch.appendingPathComponent("rbash")
        try FileManager.default.createSymbolicLink(atPath: restricted.path, withDestinationPath: bash)

        withEnvironment(["SHELL": restricted.path]) {
            let shells = CommandRunner.loginShells()
            XCTAssertEqual(shells.first?.path, restricted.path, "the configured shell is still tried first")
            XCTAssertEqual(shells.first?.flags, "-lc", "a shell named rbash is not asked for -i")
            XCTAssertTrue(shells.dropFirst().contains { $0.path == bash && $0.flags == "-lic" },
                          "the same file invoked as bash is a different, unrestricted shell and has to survive "
                              + "the deduplication: \(shells.map(\.path))")
        }
    }

    private static func invocation(_ shell: (path: String, flags: String)) -> String {
        "\(CommandRunner.resolvedPath(shell.path)) as \(URL(fileURLWithPath: shell.path).lastPathComponent)"
    }

    /// An unresolvable path keeps its own spelling rather than disappearing from
    /// the candidate list.
    func testResolvedPathKeepsAPathItCannotResolve() {
        let dangling = scratch.appendingPathComponent("dangling-\(UUID().uuidString.prefix(8))").path
        XCTAssertEqual(CommandRunner.resolvedPath(dangling), dangling)
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

    /// A stand-in login shell that records every invocation, so a test can count
    /// how many times the ladder was actually walked. It refuses the way
    /// `command -v` refuses a name it cannot resolve, which sends `find` on to
    /// the next candidate.
    private func makeCountingShell(loggingTo log: String) throws -> String {
        try makeShell(named: "counting-shell", body: """
        echo "$@" >> "\(log)"
        exit 1
        """)
    }

    private func ladderRuns(loggedAt log: String) -> [String] {
        String(decoding: FileManager.default.contents(atPath: log) ?? Data(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    private func emptyDirectory() throws -> URL {
        let directory = scratch.appendingPathComponent("empty-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

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

    /// The same path when the child also fails: the reported error has to be the
    /// child's own diagnostic, not the broken pipe the input write hit.
    func testRunReportsTheChildsFailureRatherThanTheBrokenInputPipe() throws {
        let shell = try systemBinary("sh")
        let payload = Data(String(repeating: "x", count: 512 * 1024).utf8)

        XCTAssertThrowsError(
            try CommandRunner.run(shell, ["-c", "echo refused >&2; exit 3"], input: payload, timeout: 5)
        ) { error in
            XCTAssertTrue("\(error)".contains("refused"),
                          "the child's stderr explains the failure better than EPIPE does; got \(error)")
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
