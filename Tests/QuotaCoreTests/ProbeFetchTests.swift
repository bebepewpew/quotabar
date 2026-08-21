import XCTest
import Foundation
@testable import QuotaCore

/// Everything a probe does *around* its parser: locating the binary, bounding
/// the child process, classifying what came back, and tearing the child down.
/// The parsers had fixtures from the start; these paths shelled out, so they
/// only ran on a machine with Codex, Claude Code and Gemini installed and signed
/// in. They are driven through the injected `ProbeRunner` instead, so every
/// branch of `fetch()` runs on any machine, CI included.
final class ProbeFetchTests: XCTestCase {

    // MARK: - Codex

    func testCodexFetchReportsAMissingBinaryWithoutStartingAServer() {
        let runner = FakeProbeRunner()
        XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }), "Codex is not installed")
        XCTAssertTrue(runner.sessionCommands.isEmpty, "a missing binary must not spawn anything")
    }

    func testCodexFetchSequencesInitializeBeforeRateLimitsAndParsesTheReply() throws {
        // The fake mirrors app-server: it drops `account/rateLimits/read` unless
        // the initialize exchange completed, so a snapshot here is proof the
        // probe sequenced rather than firing both requests at once.
        let server = FakeCodexServer()
        server.rateLimitsReply = """
        {"id":2,"result":{"rateLimits":{"planType":"plus",\
        "primary":{"usedPercent":23.5,"resetsAt":2000000000,"windowDurationMins":300},\
        "secondary":{"usedPercent":71,"resetsAt":2000100000,"windowDurationMins":10080}}}}
        """
        let runner = FakeProbeRunner(executables: ["codex": "/opt/quotabar test/codex"], session: server)

        let snapshot = try CodexProbe(runner: runner).fetch()

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [23.5, 71])
        XCTAssertEqual(snapshot.windows[0].resetAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(snapshot.error)

        XCTAssertEqual(runner.sessionCommands.map(\.executable), ["/opt/quotabar test/codex"])
        XCTAssertEqual(runner.sessionCommands.first?.arguments, ["app-server", "--stdio"])
        XCTAssertNotNil(runner.sessionCommands.first?.currentDirectory, "the child needs a working directory")
        XCTAssertEqual(server.sent, [CodexProbe.initializeRequest,
                                     CodexProbe.initializedNotification,
                                     CodexProbe.rateLimitsRequest])
        XCTAssertEqual(server.closeCount, 1, "the session is closed even on the happy path")
    }

    func testCodexFetchGivesUpOnAServerThatNeverAnswersInitialize() throws {
        let server = FakeCodexServer()
        server.initializeReply = nil
        let runner = FakeProbeRunner(executables: ["codex": "/usr/bin/codex"], session: server)
        let start = Date()

        XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }),
                       "Codex did not answer the initialize request.")
        XCTAssertEqual(server.sent, [CodexProbe.initializeRequest], "nothing follows an unanswered initialize")
        XCTAssertEqual(server.closeCount, 1, "a silent server still has its process group torn down")
        let waited = try XCTUnwrap(server.deadlines.first).timeIntervalSince(start)
        XCTAssertGreaterThan(waited, 0)
        XCTAssertLessThanOrEqual(waited, 31, "the wait must be bounded by a deadline")
    }

    func testCodexFetchGivesUpWhenRateLimitsIsNeverAnswered() {
        let server = FakeCodexServer()
        server.rateLimitsReply = nil
        let runner = FakeProbeRunner(executables: ["codex": "/usr/bin/codex"], session: server)

        XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }),
                       "Codex returned an unreadable quota response. Refresh after updating Codex.")
        XCTAssertEqual(server.sent.count, 3, "the probe still completed the handshake")
        XCTAssertEqual(server.closeCount, 1)
        // Both waits share one deadline, so a stalled second request cannot
        // double the time the probe blocks for.
        XCTAssertEqual(Set(server.deadlines).count, 1)
    }

    func testCodexFetchReportsAuthenticationFromTheJSONRPCError() {
        let server = FakeCodexServer()
        server.rateLimitsReply = #"{"id":2,"error":{"code":401,"message":"not logged in — run `codex login`"}}"#
        let runner = FakeProbeRunner(executables: ["codex": "/usr/bin/codex"], session: server)

        XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }),
                       "Codex authentication is required. Open Codex once and sign in.")
        XCTAssertEqual(server.closeCount, 1)
    }

    func testCodexFetchReportsAuthenticationAnnouncedBeforeTheInitializeReply() {
        let server = FakeCodexServer()
        server.chatter = [#"{"method":"session/notice","params":{"message":"Authentication expired."}}"#]
        server.rateLimitsReply = nil
        let runner = FakeProbeRunner(executables: ["codex": "/usr/bin/codex"], session: server)

        XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }),
                       "Codex authentication is required. Open Codex once and sign in.")
    }

    func testCodexFetchRejectsAnUnreadableRateLimitsReply() {
        for garbage in [#"{"id":2,"result":"soon"}"#, #"{"id":2,"result":[1,2,3]}"#, "id 2: <html>502</html>{}"] {
            let server = FakeCodexServer()
            server.rateLimitsReply = garbage
            let runner = FakeProbeRunner(executables: ["codex": "/usr/bin/codex"], session: server)
            XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }),
                           "Codex returned an unreadable quota response. Refresh after updating Codex.",
                           "\(garbage) must not be reported as quota")
            XCTAssertEqual(server.closeCount, 1)
        }
    }

    /// A reply that is shaped right but carries a window without a percentage is
    /// the same failure as an unreadable one: `fetch()` refuses it instead of
    /// handing back an invented 0%, and the child is still torn down.
    func testCodexFetchRejectsAWindowWithoutAPercent() {
        let server = FakeCodexServer()
        server.rateLimitsReply = """
        {"id":2,"result":{"rateLimits":{"planType":"plus",\
        "primary":{"resetsAt":2000000000,"windowDurationMins":300},\
        "secondary":{"usedPercent":71,"windowDurationMins":10080}}}}
        """
        let runner = FakeProbeRunner(executables: ["codex": "/usr/bin/codex"], session: server)

        XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }),
                       "Codex returned an unreadable quota response. Refresh after updating Codex.")
        XCTAssertEqual(server.closeCount, 1, "a malformed payload must not orphan the child")
    }

    func testCodexFetchRejectsAReplyHoldingNoQuotaWindows() {
        let server = FakeCodexServer()
        server.rateLimitsReply = #"{"id":2,"result":{"rateLimits":{"planType":"plus"}}}"#
        let runner = FakeProbeRunner(executables: ["codex": "/usr/bin/codex"], session: server)

        XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }), "No active quota windows")
        XCTAssertEqual(server.closeCount, 1)
    }

    func testCodexFetchClosesTheSessionWhenSendingFails() {
        let server = FakeCodexServer()
        server.sendError = ProbeError.message("broken pipe")
        let runner = FakeProbeRunner(executables: ["codex": "/usr/bin/codex"], session: server)

        XCTAssertEqual(message(from: { try CodexProbe(runner: runner).fetch() }), "broken pipe")
        XCTAssertEqual(server.closeCount, 1, "a write failure must not orphan the child")
    }

    // MARK: - Claude Code

    func testClaudeFetchReportsAMissingBinaryWithoutRunningAnything() {
        let runner = FakeProbeRunner()
        XCTAssertEqual(message(from: { try ClaudePrintProbe(runner: runner).fetch() }), "Claude Code is not installed")
        XCTAssertTrue(runner.runCommands.isEmpty)
    }

    func testClaudeFetchParsesUsageEndToEndThroughABoundedCommand() throws {
        let output = """
        Current session: 38.5% used · resets Aug 20 at 5:20pm (Europe/Warsaw)
        Current week (all models): 94% used · resets Aug 22 at 2am (Europe/Warsaw)
        """
        let runner = FakeProbeRunner(executables: ["claude": "/opt/quotabar test/claude"],
                                     runResult: .success(Data(output.utf8)))

        let snapshot = try ClaudePrintProbe(runner: runner).fetch()

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [38.5, 94])
        let command = try XCTUnwrap(runner.runCommands.first)
        XCTAssertEqual(command.executable, "/opt/quotabar test/claude")
        XCTAssertEqual(command.arguments, ["-p", "/usage"], "the probe must stay on the documented print interface")
        XCTAssertGreaterThan(command.timeout, 0)
        XCTAssertLessThanOrEqual(command.timeout, 60, "the child has to be bounded by a deadline")
        XCTAssertNotNil(command.currentDirectory)
    }

    func testClaudeFetchReportsAuthenticationFromAZeroExitPrompt() {
        let runner = FakeProbeRunner(executables: ["claude": "/usr/bin/claude"],
                                     runResult: .success(Data("Invalid API key · Please run /login".utf8)))
        XCTAssertEqual(message(from: { try ClaudePrintProbe(runner: runner).fetch() }),
                       "Claude authentication is required. Open Claude Code once and sign in.")
    }

    /// A signed-out `claude -p /usage` exits non-zero, so the sign-in prompt
    /// arrives as a thrown command failure. That branch used to reach the UI as
    /// raw CLI text, with no mention of what to do about it.
    ///
    /// The prompt is in the failure's detail rather than in its message, so this
    /// also pins down that the probe classifies from the detail: matching the
    /// message would quietly stop recognising a signed-out CLI.
    func testClaudeFetchReportsAuthenticationFromANonZeroExit() {
        for diagnostic in ["Invalid API key · Please run /login",
                           "Error: authentication required, run `claude login`"] {
            let runner = FakeProbeRunner(
                executables: ["claude": "/usr/bin/claude"],
                runResult: .failure(ProbeError.commandFailed(.init(command: "claude", status: 1, detail: diagnostic))))
            XCTAssertEqual(message(from: { try ClaudePrintProbe(runner: runner).fetch() }),
                           "Claude authentication is required. Open Claude Code once and sign in.",
                           "\(diagnostic) must become an actionable error")
        }
    }

    /// Only sign-in failures are reworded; every other failure keeps the message
    /// that says what actually went wrong — and for a command failure that
    /// message is the exit status, never the text the CLI printed.
    func testClaudeFetchKeepsUnrelatedCommandFailuresIntact() {
        for failure: ProbeError in [.message("The CLI did not respond in time"),
                                    .message("The CLI exited but left its output stream open")] {
            let runner = FakeProbeRunner(executables: ["claude": "/usr/bin/claude"], runResult: .failure(failure))
            XCTAssertEqual(message(from: { try ClaudePrintProbe(runner: runner).fetch() }), failure.errorDescription)
        }

        let secret = "sk-ant-QUOTABARNOTAREALKEY"
        let unclassified = ProbeError.commandFailed(
            .init(command: "claude", status: 127, detail: "panic: config \(secret) is corrupt"))
        let runner = FakeProbeRunner(executables: ["claude": "/usr/bin/claude"], runResult: .failure(unclassified))
        let reported = message(from: { try ClaudePrintProbe(runner: runner).fetch() })
        XCTAssertEqual(reported, "claude exited with status 127. Run it in a terminal to see what it reported.")
        XCTAssertFalse(reported?.contains(secret) ?? true, "an unclassified failure must not quote the CLI")
    }

    func testClaudeFetchRejectsAnUnreadableResponse() {
        for garbage in ["", "\u{1B}[2K\r??? nothing to see here", "{\"type\":\"result\",\"subtype\":\"success\"}"] {
            let runner = FakeProbeRunner(executables: ["claude": "/usr/bin/claude"],
                                         runResult: .success(Data(garbage.utf8)))
            XCTAssertEqual(message(from: { try ClaudePrintProbe(runner: runner).fetch() }),
                           "Claude returned an unreadable /usage response.")
        }
    }

    // MARK: - Gemini

    func testGeminiFetchReportsAMissingBinaryWithoutSpawningExpect() {
        let runner = FakeProbeRunner()
        XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: runner).fetch() }), "Gemini CLI is not installed")
        XCTAssertTrue(runner.expectScripts.isEmpty)
    }

    func testGeminiFetchSurfacesAMissingExpectInterpreter() {
        let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"],
                                     expectResult: .failure(ProbeError.unsupported(CommandRunner.expectInstallHint)))
        XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: runner).fetch() }), CommandRunner.expectInstallHint)
    }

    func testGeminiFetchParsesTheModelViewEndToEndThroughABoundedScript() throws {
        let transcript = """
        \u{1B}[2K\rModel usage
        Flash ▬▬▬▬▬▬▬▬▬ 0% Resets: 10:05 AM (16h 18m)
        Flash Lite ▬▬▬▬▬ 0.2% Resets: 9:58 AM (16h 11m)
        Pro ▬▬▬▬▬▬▬▬▬▬▬ 1% Resets: 10:01 AM (16h 14m)
        (Press Esc to close)
        QUOTABAR_STATS_COMPLETE
        """
        let runner = FakeProbeRunner(executables: ["gemini": "/opt/quotabar test/gemini"],
                                     expectResult: .success(transcript))

        let snapshot = try GeminiTerminalProbe(runner: runner).fetch()

        XCTAssertEqual(snapshot.provider, .gemini)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Flash", "Flash Lite", "Pro"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 0.2, 1])

        let script = try XCTUnwrap(runner.expectScripts.first)
        XCTAssertTrue(script.contains(CommandRunner.tclQuoted("/opt/quotabar test/gemini")),
                      "the discovered path must reach the script quoted, not interpolated raw")
        let timeout = try XCTUnwrap(runner.expectTimeouts.first)
        XCTAssertGreaterThan(timeout, 0)
        XCTAssertLessThanOrEqual(timeout, 180, "the expect child has to be bounded by a deadline")
        XCTAssertEqual(runner.expectDirectories.compactMap { $0 }.count, 1, "the expect child needs a working directory")
    }

    /// The outer deadline and the script's own waits used to be picked
    /// independently — a literal 125 beside a script that may legitimately spend
    /// 120.8 — so raising any `set timeout` silently ate the margin the teardown
    /// needs, and the deadline started winning a race it should always lose.
    /// The relation is checked against what the generated script actually asks
    /// for, so a wait raised without the deadline following fails here.
    func testGeminiDeadlineCoversEveryScriptTimeoutAndTheTeardownBudget() throws {
        let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"],
                                     expectResult: .success("Model Usage\ngemini-2.5-pro   -   0.0%\n"))
        _ = try GeminiTerminalProbe(runner: runner).fetch()
        let script = try XCTUnwrap(runner.expectScripts.first)
        let deadline = try XCTUnwrap(runner.expectTimeouts.first)

        // Every wait the script can perform, whichever branch it takes, plus the
        // pauses it spends between typing a command and pressing Return.
        let waits = try seconds(matching: #"(?m)^ *set timeout (\d+) *$"#, in: script)
        let pauses = try seconds(matching: #"(?m)^ *after (\d+) *$"#, in: script).map { $0 / 1_000 }
        let budget = GeminiTerminalProbe.Budget.self
        XCTAssertEqual(waits.sorted(), [budget.startup, budget.authClassification, budget.statsView,
                                        budget.promptReturn, budget.modelView].map { TimeInterval($0) }.sorted(),
                       "the script has a `set timeout` the budget does not know about")
        XCTAssertEqual(budget.scriptTimeouts, waits.reduce(0, +), accuracy: 0.001)
        XCTAssertEqual(budget.sendPauses, pauses.reduce(0, +), accuracy: 0.001)
        XCTAssertGreaterThan(budget.teardown, 0, "tearing the child down needs a budget of its own")
        XCTAssertEqual(deadline, budget.deadline, "fetch must use the derived deadline")
        XCTAssertGreaterThanOrEqual(deadline, waits.reduce(0, +) + pauses.reduce(0, +) + budget.teardown,
                                    "the deadline no longer covers what the script may spend")
    }

    /// The script prints its verdict and only then tears the child down, so a
    /// teardown that outruns the deadline used to replace an actionable message
    /// with a bare timeout. Whatever reached the caller first still says why.
    func testGeminiFetchKeepsTheScriptVerdictWhenTheDeadlineWinsTheRace() {
        let cases: [(partial: String, expected: String)] = [
            ("Do you trust the files in this folder?\nQUOTABAR_TRUST\n",
             "Gemini is waiting for a folder-trust decision. Start Gemini CLI once in your home directory and trust the folder."),
            ("How would you like to authenticate for this project?\nQUOTABAR_AUTH\n",
             "Gemini authentication is required. Open Gemini CLI and sign in."),
            ("QUOTABAR_STATS_TIMEOUT\n", "Gemini did not finish refreshing /stats in time."),
            ("QUOTABAR_STARTUP_TIMEOUT\n", "Gemini did not reach its input prompt in time.")
        ]
        for expectation in cases {
            let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"],
                                         expectResult: .failure(ProbeError.timeout(partialOutput: expectation.partial)))
            XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: runner).fetch() }), expectation.expected,
                           "the marker in \(expectation.partial.debugDescription) was thrown away")
        }
    }

    /// A deadline with nothing to classify keeps the timeout it came with, and
    /// so does a failure that is not a timeout at all. A transcript that only
    /// completed is not a verdict either: half a `/model` view is not reported
    /// as quota.
    func testGeminiFetchStillReportsFailuresItCannotClassify() {
        for failure: ProbeError in [.timeout(partialOutput: ""),
                                    .timeout(partialOutput: "\u{1B}[2Kloading Gemini…"),
                                    .timeout(partialOutput: "QUOTABAR_STATS_COMPLETE\n"),
                                    .message("The CLI exited but left its output stream open")] {
            let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"], expectResult: .failure(failure))
            XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: runner).fetch() }), failure.errorDescription)
        }
    }

    func testGeminiFetchParsesTheStatsTableEndToEnd() throws {
        let transcript = """
        Model Usage                 Reqs                  Usage left
        gemini-2.5-flash-lite          1   100.0% (Resets in 23h 22m)
        gemini-2.5-pro                 -     0.0%
        QUOTABAR_STATS_COMPLETE
        """
        let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"], expectResult: .success(transcript))
        let snapshot = try GeminiTerminalProbe(runner: runner).fetch()
        XCTAssertEqual(snapshot.windows.map(\.key), ["gemini-2.5-flash-lite", "gemini-2.5-pro"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 100])
    }

    /// The markers the expect script prints are the probe's only channel for
    /// *why* it came back empty, so each one has to survive the trip through
    /// `fetch()` — not merely through `failure(in:)` in isolation.
    func testGeminiFetchClassifiesEveryScriptMarker() {
        let cases: [(transcript: String, expected: String)] = [
            ("How would you like to authenticate for this project?\nQUOTABAR_AUTH\n",
             "Gemini authentication is required. Open Gemini CLI and sign in."),
            ("""
             Failed to sign in. Message: This client is no longer supported for Gemini
             Code Assist for individuals.
             QUOTABAR_INELIGIBLE
             """,
             "Gemini rejected this client: Google no longer supports Gemini Code Assist for individual accounts here. Signing in again will not help — see https://antigravity.google."),
            ("Do you trust the files in this folder?\nQUOTABAR_TRUST\n",
             "Gemini is waiting for a folder-trust decision. Start Gemini CLI once in your home directory and trust the folder."),
            ("QUOTABAR_STARTUP_TIMEOUT\n", "Gemini did not reach its input prompt in time."),
            ("QUOTABAR_STATS_TIMEOUT\n", "Gemini did not finish refreshing /stats in time.")
        ]
        for expectation in cases {
            let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"],
                                         expectResult: .success(expectation.transcript))
            XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: runner).fetch() }), expectation.expected)
        }
    }

    /// Screen-reader mode wraps one character per line, and a never-signed-in
    /// client shows the trust prompt on top of an unfinished browser OAuth flow.
    /// Both have to hold together all the way through `fetch()`.
    func testGeminiFetchReportsAnUnfinishedSignInAheadOfTheTrustPrompt() {
        let wrapped = "Waiting for authentication...".map(String.init).joined(separator: "\n")
        let transcript = """
        Warning you are running Gemini CLI in your home directory.
        \(wrapped)
        Do you trust the files in this folder?
        QUOTABAR_TRUST
        """
        let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"], expectResult: .success(transcript))
        let reported = message(from: { try GeminiTerminalProbe(runner: runner).fetch() })
        XCTAssertEqual(reported, "Gemini has not finished signing in. Run `gemini` once and complete the prompts it shows — folder trust, then sign-in — before refreshing.")
    }

    func testGeminiFetchLetsATierRejectionOutrankTheSignInMenu() throws {
        let transcript = """
        (checked) 1. Sign in with Google 2. Use Gemini API Key 3. Vertex AI
        QUOTABAR_AUTH
        QUOTABAR_INELIGIBLE
        """
        let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"], expectResult: .success(transcript))
        let reported = try XCTUnwrap(message(from: { try GeminiTerminalProbe(runner: runner).fetch() }))
        XCTAssertTrue(reported.contains("no longer supports"), "reported: \(reported)")
        XCTAssertFalse(reported.contains("Open Gemini CLI and sign in"))
    }

    func testGeminiFetchRejectsUnreadableTranscripts() {
        let runner = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"],
                                     expectResult: .success("\u{1B}[?2004h\u{1B}[2Kwelcome, nothing here\u{7}"))
        XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: runner).fetch() }),
                       "Gemini returned an unsupported /stats response.")

        // A redraw that truncated the row mid-flight is a different complaint.
        let partial = FakeProbeRunner(executables: ["gemini": "/usr/bin/gemini"],
                                      expectResult: .success("Model Usage\ngemini-2.5-pro   1   \nQUOTABAR_STATS_COMPLETE"))
        XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: partial).fetch() }),
                       "Gemini returned incomplete quota rows.")
    }

    // MARK: - Untrusted provider output

    /// The whole path the fix is about, with a real child process at one end and
    /// the machine-readable output at the other: a provider CLI fails for a
    /// reason no probe recognises, and nothing it printed may reach the
    /// snapshot, the display rows or `--json`.
    func testAFailedProviderNeverLeaksItsOutputIntoTheSnapshotOrTheJSON() throws {
        let secret = "sk-ant-QUOTABARNOTAREALKEY"
        let runner = try ShellProbeRunner(script: "echo 'Error: credential \(secret) rejected' >&2; exit 3")

        let snapshot = QuotaEngine.load(.claude) { _ in try ClaudePrintProbe(runner: runner).fetch() }

        XCTAssertFalse(snapshot.probeSucceeded)
        let reported = try XCTUnwrap(snapshot.error)
        XCTAssertFalse(reported.contains(secret), "the CLI's stderr reached the snapshot: \(reported)")
        XCTAssertTrue(reported.contains("exited with status 3"), reported)

        let json = String(decoding: try JSONEncoder().encode([snapshot]), as: UTF8.self)
        XCTAssertFalse(json.contains(secret), "--json carried the CLI's stderr")
        let rows = QuotaFormatting.rows(for: [snapshot])
        XCTAssertFalse(rows.compactMap(\.error).joined().contains(secret),
                       "the text table carried the CLI's stderr")
    }

    /// …while a sign-in prompt arriving the same way is still recognised, out of
    /// the detail the failure carries rather than out of its message.
    func testAFailedProviderStillClassifiesASignInPromptItPrinted() throws {
        let runner = try ShellProbeRunner(script: "echo 'Invalid API key · Please run /login' >&2; exit 1")
        XCTAssertEqual(message(from: { try ClaudePrintProbe(runner: runner).fetch() }),
                       "Claude authentication is required. Open Claude Code once and sign in.")
    }

    /// `expect` writes the pseudo-terminal transcript to its stdout, so a
    /// non-zero exit hands the whole Gemini session over as the failure detail.
    /// A marker in it still has to be classified — and the transcript around it
    /// still must not be shown.
    func testGeminiClassifiesItsMarkersWhenTheExpectRunItselfFails() throws {
        let signedOut = try ShellProbeRunner(script: "echo QUOTABAR_AUTH; exit 1")
        XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: signedOut).fetch() }),
                       "Gemini authentication is required. Open Gemini CLI and sign in.")

        let secret = "sk-live-GEMINITRANSCRIPTKEY"
        let noise = try ShellProbeRunner(script: "echo 'pasted \(secret) into the prompt'; exit 1")
        let reported = message(from: { try GeminiTerminalProbe(runner: noise).fetch() }) ?? ""
        XCTAssertFalse(reported.contains(secret), "the transcript reached the UI: \(reported)")
        // Asserted whole, not by substring: the command `run` was given here is
        // the runner's `sh`, and in production it is `expect`. Either name would
        // satisfy "exited with status 1" while telling the user to go and run a
        // helper they never invoked, so the unclassified message must be the
        // fixed Gemini one with no command name in it at all.
        XCTAssertEqual(reported, "Gemini CLI did not finish. Run `gemini` in a terminal to see what it reports.")
    }

    /// The same when the run left nothing to classify at all. A failing `expect`
    /// usually died on a Tcl error rather than on a marker branch, so the detail
    /// is that error or is empty — and neither may be reported against `expect`.
    func testGeminiNamesItselfWhenAFailedExpectRunLeftNothingToClassify() throws {
        for script in ["exit 1", "echo 'invalid spawn id id4: spawn failed' >&2; exit 1"] {
            let runner = try ShellProbeRunner(script: script)
            XCTAssertEqual(message(from: { try GeminiTerminalProbe(runner: runner).fetch() }),
                           "Gemini CLI did not finish. Run `gemini` in a terminal to see what it reports.",
                           "`\(script)` must not be reported against the expect helper")
        }
    }

    // MARK: - The default seam

    /// A seam is only worth having if its default really is the old behaviour,
    /// so the forwarding is exercised against small system binaries: a dropped
    /// argument or an ignored timeout would otherwise only show up in
    /// production, where the stub never runs.
    func testSystemProbeRunnerForwardsToTheRealCommandRunner() throws {
        let runner = SystemProbeRunner()
        XCTAssertNil(runner.find("no/such/tool"), "a path-shaped name is never looked up")
        let shell = try XCTUnwrap(runner.find("sh"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))

        let data = try runner.run(shell, ["-c", "printf hello"], timeout: 10, currentDirectory: nil)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")

        // The timeout has to reach the process, not fall back to the default.
        let started = Date()
        XCTAssertThrowsError(try runner.run(shell, ["-c", "sleep 30"], timeout: 0.5, currentDirectory: nil)) { error in
            XCTAssertEqual((error as? ProbeError)?.errorDescription, "The CLI did not respond in time")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the child was not bounded by the timeout passed in")
    }

    func testSystemProbeRunnerHandsBackARealLineSession() throws {
        let session = try SystemProbeRunner().lineSession(executable: "/bin/cat", arguments: [], currentDirectory: nil)
        defer { session.close() }
        var transcript: [String] = []
        try session.send(#"{"id":2,"result":{}}"#)
        XCTAssertNotNil(session.waitForLine(matching: { CodexProbe.identifier(of: $0) == 2 },
                                            before: Date().addingTimeInterval(10), transcript: &transcript))
    }

    /// `runExpect` resolves the binary itself, so a machine without `expect`
    /// lets the search fall through to the login shells. `ShellStartupFiles`
    /// keeps those out of the developer's startup files, and covers the guard
    /// as well so it resolves the same way `runExpect` will.
    func testSystemProbeRunnerRunsExpectOrExplainsItIsMissing() throws {
        let runner = SystemProbeRunner()
        try ShellStartupFiles.suppressed {
            guard CommandRunner.find("expect") != nil else {
                XCTAssertThrowsError(try runner.runExpect("puts QUOTABAR_OK", timeout: 5, currentDirectory: nil)) { error in
                    XCTAssertEqual((error as? ProbeError)?.errorDescription, CommandRunner.expectInstallHint)
                }
                return
            }
            let output = try runner.runExpect("puts QUOTABAR_OK", timeout: 10, currentDirectory: nil)
            XCTAssertTrue(output.contains("QUOTABAR_OK"))
        }
    }

    // MARK: - Helpers

    /// Every number the pattern's first group captures, read out of the script
    /// itself rather than restated here — a test that repeated the values would
    /// pass however far the script and its deadline had drifted apart.
    private func seconds(matching pattern: String, in script: String) throws -> [TimeInterval] {
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: script, range: NSRange(script.startIndex..., in: script))
        XCTAssertFalse(matches.isEmpty, "no `\(pattern)` in the script")
        return matches.compactMap { match in
            Range(match.range(at: 1), in: script).flatMap { TimeInterval(script[$0]) }
        }
    }

    private func message(from body: () throws -> QuotaSnapshot) -> String? {
        do {
            let snapshot = try body()
            XCTFail("expected a failure, got \(snapshot)")
            return nil
        } catch let error as ProbeError {
            return error.errorDescription
        } catch {
            XCTFail("expected a ProbeError, got \(error)")
            return nil
        }
    }
}

/// A runner whose commands are a real `/bin/sh` script, so a failing provider
/// is simulated all the way down to the pipes: the error a probe catches is the
/// one `CommandRunner` built from what the child actually wrote.
private struct ShellProbeRunner: ProbeRunner {
    let shell: String
    let script: String

    init(script: String) throws {
        guard let shell = ["/bin/sh", "/usr/bin/sh"].first(where: FileManager.default.isExecutableFile) else {
            throw XCTSkip("sh is not installed at a standard location on this machine")
        }
        self.shell = shell
        self.script = script
    }

    func find(_ executable: String) -> String? { shell }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, currentDirectory: URL?) throws -> Data {
        try CommandRunner.run(shell, ["-c", script], timeout: timeout)
    }

    func runExpect(_ script: String, timeout: TimeInterval, currentDirectory: URL?) throws -> String {
        String(decoding: try CommandRunner.run(shell, ["-c", self.script], timeout: timeout), as: UTF8.self)
    }

    func lineSession(executable: String, arguments: [String], currentDirectory: URL?) throws -> any LineSession {
        throw ProbeError.message("no scripted session")
    }
}

/// Stands in for `CommandRunner`/`ProcessLineSession`, recording what each probe
/// asked for so the deadlines, arguments and working directory can be asserted.
private final class FakeProbeRunner: ProbeRunner, @unchecked Sendable {
    struct Command {
        let executable: String, arguments: [String], timeout: TimeInterval, currentDirectory: URL?
    }

    private let executables: [String: String]
    private let runResult: Result<Data, Error>
    private let expectResult: Result<String, Error>
    private let session: (any LineSession)?

    private(set) var runCommands: [Command] = []
    private(set) var expectScripts: [String] = []
    private(set) var expectTimeouts: [TimeInterval] = []
    private(set) var expectDirectories: [URL?] = []
    private(set) var sessionCommands: [Command] = []

    init(executables: [String: String] = [:],
         runResult: Result<Data, Error> = .success(Data()),
         expectResult: Result<String, Error> = .success(""),
         session: (any LineSession)? = nil) {
        self.executables = executables
        self.runResult = runResult
        self.expectResult = expectResult
        self.session = session
    }

    func find(_ executable: String) -> String? { executables[executable] }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, currentDirectory: URL?) throws -> Data {
        runCommands.append(.init(executable: executable, arguments: arguments,
                                 timeout: timeout, currentDirectory: currentDirectory))
        return try runResult.get()
    }

    func runExpect(_ script: String, timeout: TimeInterval, currentDirectory: URL?) throws -> String {
        expectScripts.append(script)
        expectTimeouts.append(timeout)
        expectDirectories.append(currentDirectory)
        return try expectResult.get()
    }

    func lineSession(executable: String, arguments: [String], currentDirectory: URL?) throws -> any LineSession {
        sessionCommands.append(.init(executable: executable, arguments: arguments,
                                     timeout: 0, currentDirectory: currentDirectory))
        guard let session else { throw ProbeError.message("no scripted session") }
        return session
    }
}

/// A scripted `codex app-server`. Like the real one it ignores
/// `account/rateLimits/read` until the initialize exchange has completed, so a
/// probe that fired both requests at once would come back empty here.
private final class FakeCodexServer: LineSession, @unchecked Sendable {
    /// Reply to `initialize`, or nil for a server that never answers.
    var initializeReply: String? = #"{"id":1,"result":{"userAgent":"codex/0.0.0"}}"#
    /// Reply to `account/rateLimits/read`, or nil for a server that stalls there.
    var rateLimitsReply: String?
    /// Unsolicited notifications delivered ahead of the initialize reply.
    var chatter: [String] = []
    /// Set to simulate a child that closed its stdin under us.
    var sendError: Error?

    private var initialized = false
    private var acknowledged = false
    private var pending: [String] = []

    private(set) var sent: [String] = []
    private(set) var deadlines: [Date] = []
    private(set) var closeCount = 0

    func send(_ line: String) throws {
        if let sendError { throw sendError }
        sent.append(line)
        switch CodexProbe.jsonObject(line)?["method"] as? String {
        case "initialize":
            initialized = true
            pending.append(contentsOf: chatter)
            if let initializeReply { pending.append(initializeReply) }
        case "initialized":
            acknowledged = true
        case "account/rateLimits/read":
            guard initialized, acknowledged else { return }
            if let rateLimitsReply { pending.append(rateLimitsReply) }
        default:
            break
        }
    }

    /// Exhausting `pending` stands in for reaching the deadline: the real
    /// session returns nil either way, and waiting out 30 seconds of wall clock
    /// would only make the suite slower.
    func waitForLine(matching matches: (String) -> Bool, before deadline: Date, transcript: inout [String]) -> String? {
        deadlines.append(deadline)
        while !pending.isEmpty {
            let line = pending.removeFirst()
            transcript.append(line)
            if matches(line) { return line }
        }
        return nil
    }

    func close() { closeCount += 1 }
}
