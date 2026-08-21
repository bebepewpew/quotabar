import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import QuotaCore

/// Coverage for the process plumbing every probe runs through: what `run`
/// captures, how it reports a failure, and — the part this project has already
/// been bitten by — that a deadline takes down the complete process group
/// rather than the direct child alone.
///
/// Everything here drives real trivial binaries (`echo`, `sh`, `cat`) with
/// short deadlines, so the suite exercises the real spawn/signal paths without
/// getting slow or depending on a provider CLI being installed.
final class CommandRunnerTests: XCTestCase {
    private var scratch = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-command-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // `find` remembers what the login-shell ladder answered, so a case that
        // stages `$PATH` starts from an empty memo rather than the last one's.
        CommandRunner.resetDiscoveryMemo()
    }

    override func tearDown() {
        CommandRunner.resetDiscoveryMemo()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - run: output and input

    func testCapturesStandardOutputOfASuccessfulRun() throws {
        let echo = try systemBinary("echo")
        let output = try CommandRunner.run(echo, ["quota", "bar"], timeout: 5)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "quota bar\n")
    }

    func testReturnsOnlyStandardOutputWhenTheChildAlsoWritesToStandardError() throws {
        let shell = try systemBinary("sh")
        let output = try CommandRunner.run(shell, ["-c", "echo wanted; echo noise >&2"], timeout: 5)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "wanted\n")
    }

    /// `cat` only reaches end of file once the runner closes the write end of
    /// stdin, so this also pins down that the input pipe is closed after the
    /// payload is written.
    func testWritesInputToTheChildAndClosesStandardIn() throws {
        let cat = try systemBinary("cat")
        let output = try CommandRunner.run(cat, [], input: Data("first\nsecond\n".utf8), timeout: 5)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "first\nsecond\n")
    }

    func testRunsInTheRequestedWorkingDirectory() throws {
        let pwd = try systemBinary("pwd")
        let output = try CommandRunner.run(pwd, [], timeout: 5, currentDirectory: scratch)
        let reported = URL(fileURLWithPath: String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(reported.resolvingSymlinksInPath().path, scratch.resolvingSymlinksInPath().path)
    }

    // MARK: - run: failure diagnostics

    /// A command that fails is reported as an exit status, never as whatever it
    /// printed. Its stderr is untrusted text that has carried API keys, and
    /// every error description reaches the menu card, the table and `--json`.
    func testNonZeroExitReportsTheStatusWithoutEchoingWhatTheCLIPrinted() throws {
        let shell = try systemBinary("sh")
        let secret = "sk-live-QUOTABARNOTAREALKEY"
        XCTAssertThrowsError(try CommandRunner.run(
            shell, ["-c", "echo 'Error: credential \(secret) was rejected' >&2; exit 3"], timeout: 5)) { error in
            let message = (error as? ProbeError)?.errorDescription ?? ""
            XCTAssertFalse(message.contains(secret), "the CLI's own stderr reached the message: \(message)")
            XCTAssertFalse(message.contains("rejected"), "no part of the CLI's stderr may be quoted: \(message)")
            XCTAssertEqual(message, "sh exited with status 3. Run it in a terminal to see what it reported.")
        }
    }

    /// stdout is no safer than stderr, and an empty stream changes nothing: the
    /// status is what gets reported either way. What the command printed is
    /// kept beside the error for a probe to classify, off the display path.
    func testNonZeroExitWithholdsStandardOutputAndKeepsItOnlyAsDetail() throws {
        let shell = try systemBinary("sh")
        XCTAssertThrowsError(try CommandRunner.run(shell, ["-c", "echo printed to stdout; exit 1"], timeout: 5)) { error in
            XCTAssertEqual((error as? ProbeError)?.errorDescription,
                           "sh exited with status 1. Run it in a terminal to see what it reported.")
            XCTAssertEqual((error as? ProbeError)?.diagnosticDetail, "printed to stdout")
        }
        XCTAssertThrowsError(try CommandRunner.run(shell, ["-c", "exit 7"], timeout: 5)) { error in
            XCTAssertEqual((error as? ProbeError)?.errorDescription,
                           "sh exited with status 7. Run it in a terminal to see what it reported.")
            XCTAssertNil((error as? ProbeError)?.diagnosticDetail, "a silent command leaves nothing to classify")
        }
    }

    /// The retained detail is still sanitized and bounded. It is only ever
    /// matched against, but terminal control bytes make a match unreliable and
    /// a screenful of noise is not free to carry around.
    func testTheRetainedDetailIsSanitizedAndClampedToTheTailOfTheStream() throws {
        let shell = try systemBinary("sh")
        XCTAssertThrowsError(try CommandRunner.run(
            shell, ["-c", "printf '\\033[2K\\033[1Aquota exhausted\\r\\n' >&2; exit 1"], timeout: 5)) { error in
            XCTAssertEqual((error as? ProbeError)?.diagnosticDetail, "quota exhausted")
            XCTAssertFalse((error as? ProbeError)?.errorDescription?.contains("quota exhausted") ?? true)
        }
        XCTAssertThrowsError(try CommandRunner.run(
            shell, ["-c", "printf '%3000s' '' | tr ' ' A >&2; exit 1"], timeout: 5)) { error in
            let detail = (error as? ProbeError)?.diagnosticDetail ?? ""
            XCTAssertEqual(detail.count, 1_500, "only the tail of a noisy stream is kept")
            XCTAssertTrue(detail.allSatisfy { $0 == "A" })
        }
    }

    /// The message names the command, so the three failure kinds stay distinct,
    /// but it names it only when the name is plain: the path is resolved from
    /// `PATH` or from a login shell, so its last component is untrusted too.
    func testOnlyAPlainCommandNameIsQuotedBackInTheMessage() {
        XCTAssertEqual(CommandRunner.commandName("/opt/quota bar/claude"), "claude")
        XCTAssertEqual(CommandRunner.commandName("gemini-2.5_pro+beta"), "gemini-2.5_pro+beta")
        XCTAssertNil(CommandRunner.commandName("/tmp/claude \u{1B}[31mfake"))
        XCTAssertNil(CommandRunner.commandName("/tmp/claude;id"))
        XCTAssertNil(CommandRunner.commandName("/tmp/" + String(repeating: "a", count: 33)))

        XCTAssertEqual(ProbeError.commandFailed(.init(command: nil, status: 2, detail: "boom")).errorDescription,
                       "The CLI exited with status 2. Run it in a terminal to see what it reported.")
        XCTAssertNil(ProbeError.commandFailed(.init(command: "claude", status: 1, detail: "")).diagnosticDetail)
        XCTAssertNil(ProbeError.message("plain").diagnosticDetail, "only a command failure carries CLI output")
        XCTAssertNil(ProbeError.timeout(partialOutput: "boom").diagnosticDetail,
                     "a deadline's partial output is not a command failure's detail")
    }

    /// Exit status, timeout and a stuck output stream have to stay tellable
    /// apart: they need different things done about them.
    func testTheThreeCommandFailuresKeepDistinctMessages() {
        let messages = [ProbeError.commandFailed(.init(command: "claude", status: 3, detail: "sk-live-key")),
                        .timeout(partialOutput: ""),
                        .message("The CLI exited but left its output stream open")]
            .map { $0.errorDescription ?? "" }
        XCTAssertEqual(Set(messages).count, 3, "\(messages)")
        XCTAssertTrue(messages[0].contains("status 3"))
        XCTAssertFalse(messages[0].contains("sk-live-key"))
    }

    // MARK: - run: deadlines and process groups

    func testTimeoutReturnsABoundedErrorRatherThanHanging() throws {
        let shell = try systemBinary("sh")
        let started = Date()
        XCTAssertThrowsError(try CommandRunner.run(shell, ["-c", "sleep 5"], timeout: 1)) { error in
            XCTAssertEqual((error as? ProbeError)?.errorDescription, "The CLI did not respond in time")
            XCTAssertNil((error as? ProbeError)?.partialOutput, "a silent child has nothing to hand back")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "the deadline has to bound the call")
    }

    /// A CLI that says why it is giving up and only then hangs — clearing up its
    /// own children, say — has already answered the caller's question. The
    /// deadline used to discard that output, so the caller had nothing left to
    /// report but the timeout itself. `echo` runs as its own process so the test
    /// pins down the runner's behaviour rather than a shell's output buffering.
    func testTimeoutCarriesWhatTheChildAlreadyPrinted() throws {
        let shell = try systemBinary("sh")
        let echo = try systemBinary("echo")
        let started = Date()
        XCTAssertThrowsError(try CommandRunner.run(shell, ["-c", "\(echo) QUOTABAR_TRUST; sleep 5"], timeout: 1)) { error in
            guard case .timeout(let partial)? = error as? ProbeError else {
                return XCTFail("expected ProbeError.timeout, got \(error)")
            }
            XCTAssertEqual(partial.trimmingCharacters(in: .newlines), "QUOTABAR_TRUST")
            XCTAssertEqual((error as? ProbeError)?.partialOutput, partial)
            XCTAssertEqual((error as? ProbeError)?.errorDescription, "The CLI did not respond in time",
                           "the transcript is for the caller to classify, never for display")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "draining the output stays inside the deadline")
    }

    /// The regression this file exists for. Provider CLIs spawn children of
    /// their own, so a deadline that signals only the direct child leaves the
    /// grandchild running with the pipes it inherited. `run` puts the child in
    /// its own process group and signals the group, which has to reach the
    /// grandchild and everything below it.
    ///
    /// The leading `sleep 1` keeps the grandchild from being forked before the
    /// runner has had a chance to create that process group; without it the
    /// test would be measuring a spawn race rather than the kill.
    func testTimeoutTerminatesTheWholeProcessGroupIncludingAGrandchild() throws {
        let shell = try systemBinary("sh")
        let pidFile = scratch.appendingPathComponent("grandchild.pid").path
        let heartbeat = scratch.appendingPathComponent("heartbeat").path
        let script = """
        sleep 1
        \(shell) -c 'while : ; do echo tick >> \(heartbeat) ; sleep 1 ; done' &
        echo $! > \(pidFile)
        wait
        """

        let started = Date()
        XCTAssertThrowsError(try CommandRunner.run(shell, ["-c", script], timeout: 2)) { error in
            XCTAssertEqual((error as? ProbeError)?.errorDescription, "The CLI did not respond in time")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "the whole teardown stays bounded")

        let grandchild = try readPid(at: pidFile)
        XCTAssertTrue(waitUntil(3) { self.hasExited(grandchild) },
                      "the grandchild outlived the deadline, so the process group was not terminated")

        // The grandchild spawns children of its own, so also check the group
        // stopped doing work rather than only that one pid is gone.
        let ticks = fileSize(heartbeat)
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertEqual(fileSize(heartbeat), ticks, "something in the process group is still running")
    }

    /// A child can exit while something it spawned keeps the inherited pipes
    /// open. Which failure gets reported is platform-dependent — Darwin reports
    /// the child's exit straight away and the runner then gives up draining,
    /// while swift-corelibs-foundation only reports the exit once the pipes
    /// close, so the deadline fires first — but neither may leave the runaway
    /// behind, and both have to come back inside the deadline.
    func testARunawayGrandchildIsNotLeftBehindWhenTheChildExitsFirst() throws {
        let shell = try systemBinary("sh")
        let pidFile = scratch.appendingPathComponent("holder.pid").path
        let heartbeat = scratch.appendingPathComponent("holder-heartbeat").path
        let script = """
        sleep 1
        \(shell) -c 'while : ; do echo tick >> \(heartbeat) ; sleep 1 ; done' &
        echo $! > \(pidFile)
        exit 0
        """

        let started = Date()
        XCTAssertThrowsError(try CommandRunner.run(shell, ["-c", script], timeout: 2)) { error in
            let message = (error as? ProbeError)?.errorDescription ?? ""
            XCTAssertTrue(["The CLI did not respond in time",
                           "The CLI exited but left its output stream open"].contains(message),
                          "unexpected diagnostic: \(message)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "giving up on the output stays bounded")

        let grandchild = try readPid(at: pidFile)
        XCTAssertTrue(waitUntil(3) { self.hasExited(grandchild) },
                      "the runaway grandchild was left running after the runner gave up on its output")
    }

    func testMissingExecutableFailsInsteadOfBlocking() {
        let absent = scratch.appendingPathComponent("not-a-binary").path
        XCTAssertThrowsError(try CommandRunner.run(absent, [], timeout: 5))
    }

    // MARK: - find

    func testFindResolvesFromPathInOrderAndSkipsNonExecutableMatches() throws {
        try requireLiveEnvironment()
        let name = "quotabar-probe-\(UUID().uuidString.prefix(8))"
        let decoy = scratch.appendingPathComponent("decoy")
        let winner = scratch.appendingPathComponent("winner")
        let loser = scratch.appendingPathComponent("loser")
        _ = try makeExecutable(named: name, in: decoy, executable: false)
        let expected = try makeExecutable(named: name, in: winner)
        _ = try makeExecutable(named: name, in: loser)

        try withPath("\(decoy.path):\(winner.path):\(loser.path)") {
            XCTAssertEqual(CommandRunner.find(name), expected)
        }
    }

    /// The known install locations are searched before `PATH`, so a stray entry
    /// earlier on `PATH` cannot shadow a real installation.
    func testFindPrefersKnownInstallLocationsOverPath() throws {
        try requireLiveEnvironment()
        // Pin to an entry that is actually in find()'s explicit list. Comparing
        // against whatever the system calls "echo" passes on a merged-usr Linux,
        // where /bin is a symlink to /usr/bin, and fails on macOS, where
        // /bin/echo and /usr/bin/echo are distinct files and only /usr/bin is
        // searched. The point of the test is the ordering, not the path.
        let known = "/usr/bin/echo"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: known),
                          "\(known) is absent, so there is no known install location to prefer")
        let shadow = scratch.appendingPathComponent("shadow")
        let fake = try makeExecutable(named: "echo", in: shadow)

        try withPath("\(shadow.path):/usr/bin:/bin") {
            let resolved = CommandRunner.find("echo")
            XCTAssertNotEqual(resolved, fake, "a PATH entry must not shadow a known install location")
            XCTAssertEqual(resolved, known)
        }
    }

    func testFindRejectsNamesThatCouldReachTheLoginShell() {
        let started = Date()
        XCTAssertNil(CommandRunner.find("echo; id"))
        XCTAssertNil(CommandRunner.find("gemini $(id)"))
        XCTAssertNil(CommandRunner.find("gemini|tee /tmp/x"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "an unsafe name is rejected before any shell is spawned")
    }

    func testFindReturnsNilWhenNothingProvidesTheExecutable() {
        let started = Date()
        XCTAssertNil(CommandRunner.find("quotabar-absent-\(UUID().uuidString.prefix(8))"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "the login-shell fallback stays bounded")
    }

    func testLoginShellsAreExecutableUniqueAndFlaggedForTheirDialect() {
        let shells = CommandRunner.loginShells()
        XCTAssertFalse(shells.isEmpty, "there is always a POSIX shell to fall back on")
        XCTAssertEqual(Set(shells.map(\.path)).count, shells.count, "each candidate is tried once")
        for shell in shells {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell.path))
            let name = URL(fileURLWithPath: shell.path).lastPathComponent
            XCTAssertEqual(shell.flags, ["zsh", "bash"].contains(name) ? "-lic" : "-lc",
                           "a POSIX shell need not accept -i alongside -c")
        }
    }

    func testLoginShellsStartWithTheConfiguredShell() throws {
        try requireLiveEnvironment()
        let shell = try systemBinary("sh")
        let previous = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell, 1)
        defer {
            if let previous { setenv("SHELL", previous, 1) } else { unsetenv("SHELL") }
        }
        let first = CommandRunner.loginShells().first
        XCTAssertEqual(first?.path, shell)
        XCTAssertEqual(first?.flags, "-lc")
    }

    // MARK: - expect

    func testExpectInstallHintNamesThePlatformInstaller() {
        let hint = CommandRunner.expectInstallHint
        #if os(macOS)
        XCTAssertTrue(hint.contains("expect is not installed"))
        XCTAssertTrue(hint.contains("brew install expect"))
        #elseif os(Windows)
        XCTAssertTrue(hint.contains("not supported on Windows"))
        #else
        XCTAssertTrue(hint.contains("expect is not installed"))
        XCTAssertTrue(hint.contains("pacman -S expect"))
        XCTAssertTrue(hint.contains("apt install expect"))
        #endif
    }

    func testRunExpectReportsAnUnsupportedProbeWhenExpectIsMissing() throws {
        guard CommandRunner.find("expect") == nil else {
            throw XCTSkip("expect is installed here, so the missing-binary branch cannot be reached")
        }
        XCTAssertThrowsError(try CommandRunner.runExpect("puts quotabar", timeout: 5)) { error in
            guard case .unsupported(let hint)? = error as? ProbeError else {
                return XCTFail("expected ProbeError.unsupported, got \(error)")
            }
            XCTAssertEqual(hint, CommandRunner.expectInstallHint)
        }
    }

    /// End-to-end check that a quoted value survives Tcl substitution intact.
    func testRunExpectReturnsTheScriptOutputWhenExpectIsInstalled() throws {
        guard CommandRunner.find("expect") != nil else {
            throw XCTSkip("expect is not installed here")
        }
        let value = #"/Users/a b/gemini "100%" [$HOME] \ok"#
        let output = try CommandRunner.runExpect("puts \(CommandRunner.tclQuoted(value))", timeout: 10)
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), value)
    }

    func testTclQuotedEscapesEverySubstitutionTclWouldPerform() {
        XCTAssertEqual(CommandRunner.tclQuoted("plain"), #""plain""#)
        XCTAssertEqual(CommandRunner.tclQuoted(""), #""""#)
        XCTAssertEqual(CommandRunner.tclQuoted("/Users/a b/gemini"), #""/Users/a b/gemini""#)
        XCTAssertEqual(CommandRunner.tclQuoted(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(CommandRunner.tclQuoted(#"C:\dir"#), #""C:\\dir""#)
        XCTAssertEqual(CommandRunner.tclQuoted("$HOME"), #""\$HOME""#)
        XCTAssertEqual(CommandRunner.tclQuoted("[exec id]"), #""\[exec id]""#)
        // A backslash must be doubled before the dollar is escaped, or the
        // escape the quoting adds would itself be swallowed by Tcl.
        XCTAssertEqual(CommandRunner.tclQuoted(#"\$x"#), #""\\\$x""#)
    }

    // MARK: - sanitizeDiagnostic

    func testSanitizeStripsOperatingSystemCommandsButKeepsTheTextAroundThem() {
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic("\u{1B}]0;title\u{7}not logged in"), "not logged in")
        // A hyperlink pair is terminated by ESC-backslash rather than BEL, and
        // the text between the two sequences is the actual message.
        XCTAssertEqual(
            CommandRunner.sanitizeDiagnostic("\u{1B}]8;;https://example.test\u{1B}\\sign in\u{1B}]8;;\u{1B}\\"),
            "sign in")
    }

    func testSanitizeStripsTwoCharacterEscapesAndStrayControlBytes() {
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic("before\u{1B}Mmiddle\u{1B}Dafter"), "beforemiddleafter")
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic("truncated\u{1B}"), "truncated")
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic("left\u{85}\u{7F}\u{0}right"), "leftright")
    }

    func testSanitizeNormalizesCarriageReturnsWhitespaceAndBlankLines() {
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic("one\r\ntwo\rthree"), "one\ntwo\nthree")
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic("a\n\n\n\nb\tc  d "), "a\n\nb c d")
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic("   \n\t \n "), "")
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic(""), "")
    }

    func testSanitizeKeepsNonAsciiTextAndIsIdempotent() {
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic("café ✅ 100% used"), "café ✅ 100% used")
        let messy = "\u{1B}[?2004h\u{1B}]0;gemini\u{7}\u{1B}[2Kquota\t\treset\r\n\r\n\r\n\u{7F}soon\u{1B}[0m"
        let once = CommandRunner.sanitizeDiagnostic(messy)
        XCTAssertEqual(once, "quota reset\n\nsoon")
        XCTAssertEqual(CommandRunner.sanitizeDiagnostic(once), once)
    }

    // MARK: - Helpers

    private func systemBinary(_ name: String) throws -> String {
        let candidates = ["/bin/\(name)", "/usr/bin/\(name)"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("\(name) is not installed at a standard location on this machine")
        }
        return path
    }

    @discardableResult
    private func makeExecutable(named name: String, in directory: URL, executable: Bool = true) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                              ofItemAtPath: url.path)
        return url.path
    }

    private func withPath(_ value: String, _ body: () throws -> Void) rethrows {
        let previous = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", value, 1)
        defer { setenv("PATH", previous, 1) }
        try body()
    }

    /// `find` and `loginShells` read the environment through `ProcessInfo`, and
    /// a Foundation that snapshots it once cannot be driven from a test.
    private func requireLiveEnvironment() throws {
        let name = "QUOTABAR_ENV_PROBE_\(UUID().uuidString.prefix(8))"
        setenv(name, "1", 1)
        defer { unsetenv(name) }
        guard ProcessInfo.processInfo.environment[name] == "1" else {
            throw XCTSkip("ProcessInfo snapshots the environment here, so PATH cannot be staged")
        }
    }

    private func readPid(at path: String) throws -> pid_t {
        XCTAssertTrue(waitUntil(2) { FileManager.default.fileExists(atPath: path) },
                      "the child never recorded its grandchild's pid")
        let text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                             "unreadable pid file: \(text)")
    }

    private func hasExited(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return true }
        guard kill(pid, 0) == 0 else { return errno == ESRCH }
        #if os(Linux)
        // An orphan that has been killed can sit around as an unreaped zombie
        // when the container's pid 1 is not an init that reaps; a zombie is not
        // a surviving process.
        let stat = String(decoding: FileManager.default.contents(atPath: "/proc/\(pid)/stat") ?? Data(),
                          as: UTF8.self)
        if let afterName = stat.split(separator: ")").last,
           let state = afterName.split(separator: " ").first {
            return state == "Z"
        }
        #endif
        return false
    }

    private func fileSize(_ path: String) -> Int {
        (FileManager.default.contents(atPath: path) ?? Data()).count
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
