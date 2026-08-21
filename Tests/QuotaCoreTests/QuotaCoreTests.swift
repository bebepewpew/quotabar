import XCTest
import Foundation
@testable import QuotaCore

final class QuotaCoreTests: XCTestCase {
    func testParsesCodexWindows() throws {
        let result: [String: Any] = ["rateLimits": [
            "planType": "plus",
            "primary": ["usedPercent": NSNumber(value: 23), "resetsAt": NSNumber(value: 2_000_000_000)],
            "secondary": ["usedPercent": NSNumber(value: 71), "resetsAt": NSNumber(value: 2_000_100_000)]
        ]]
        let value = try CodexProbe.parse(result)
        XCTAssertEqual(value.plan, "plus")
        XCTAssertEqual(value.windows.count, 2)
        XCTAssertEqual(value.windows[0].usedPercent, 23)
    }

    /// swift-corelibs-foundation hands back plain `Int`/`Double` rather than
    /// `NSNumber`, which used to collapse every Codex quota to 0% on Linux.
    func testParsesCodexWindowsFromUnbridgedJSONNumbers() throws {
        let result: [String: Any] = ["rateLimits": [
            "planType": "pro",
            "primary": ["usedPercent": 42.5, "resetsAt": 2_000_000_000, "windowDurationMins": 300],
            "secondary": ["usedPercent": 88, "resetsAt": Double(2_000_100_000), "windowDurationMins": 10_080]
        ]]
        let value = try CodexProbe.parse(result)
        XCTAssertEqual(value.plan, "pro")
        XCTAssertEqual(value.windows.map(\.usedPercent), [42.5, 88])
        XCTAssertEqual(value.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(value.windows[0].resetAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testCodexRequestsAreSingleLineJSONRPC() throws {
        let requests = [CodexProbe.initializeRequest, CodexProbe.initializedNotification, CodexProbe.rateLimitsRequest]
        for request in requests {
            XCTAssertFalse(request.contains("\n"), "app-server reads one request per line")
            XCTAssertNotNil(CodexProbe.jsonObject(request), "\(request) is not valid JSON")
        }
        XCTAssertEqual(CodexProbe.identifier(of: CodexProbe.initializeRequest), 1)
        XCTAssertEqual(CodexProbe.identifier(of: CodexProbe.rateLimitsRequest), 2)
        XCTAssertNil(CodexProbe.identifier(of: CodexProbe.initializedNotification), "a notification carries no id")
        let initialize = try XCTUnwrap(CodexProbe.jsonObject(CodexProbe.initializeRequest))
        XCTAssertEqual(initialize["method"] as? String, "initialize")
    }

    /// The Codex probe needs to read a reply before sending the next request.
    /// `cat` echoes lines back, which exercises exactly that interleaving.
    func testProcessLineSessionInterleavesWritesAndReads() throws {
        let session = try ProcessLineSession(executable: "/bin/cat", arguments: [])
        defer { session.close() }
        var transcript: [String] = []

        try session.send(#"{"id":1}"#)
        XCTAssertNotNil(session.waitForLine(matching: { CodexProbe.identifier(of: $0) == 1 },
                                            before: Date().addingTimeInterval(10), transcript: &transcript))
        try session.send(#"{"id":2}"#)
        XCTAssertNotNil(session.waitForLine(matching: { CodexProbe.identifier(of: $0) == 2 },
                                            before: Date().addingTimeInterval(10), transcript: &transcript))
        XCTAssertEqual(transcript.count, 2)
    }

    func testProcessLineSessionGivesUpAtTheDeadline() throws {
        let session = try ProcessLineSession(executable: "/bin/cat", arguments: [])
        defer { session.close() }
        var transcript: [String] = []
        XCTAssertNil(session.waitForLine(matching: { _ in true },
                                         before: Date().addingTimeInterval(0.3), transcript: &transcript))
    }

    func testParsesClaudeResetDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12)))
        let reset = try XCTUnwrap(ClaudePrintProbe.parseReset("Aug 22 at 2am", timeZoneName: "Europe/Warsaw", now: now))
        XCTAssertEqual(calendar.component(.day, from: reset), 22)
        XCTAssertEqual(calendar.component(.hour, from: reset), 2)

        // Current Claude Code builds separate date and time with a comma.
        let comma = try XCTUnwrap(ClaudePrintProbe.parseReset("Aug 22, 8:59am", timeZoneName: "Europe/Warsaw", now: now))
        XCTAssertEqual(calendar.component(.day, from: comma), 22)
        XCTAssertEqual(calendar.component(.hour, from: comma), 8)
        XCTAssertEqual(calendar.component(.minute, from: comma), 59)
    }

    func testParsesClaudeModelWindowsAndDecimalPercentages() throws {
        let output = """
        Current session: 38.5% used · resets Aug 20 at 5:20pm (Europe/Warsaw)
        Current week (all models): 94% used · resets Aug 22 at 2am (Europe/Warsaw)
        Current week (Fable): 100% used · resets Aug 22 at 2am (Europe/Warsaw)
        """
        let snapshot = try ClaudePrintProbe.parse(output, now: Date())
        XCTAssertEqual(snapshot.windows.map(\.label), ["Session", "Weekly", "Weekly Fable"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [38.5, 94, 100])
    }

    func testParsesAllGeminiQuotaRowsIncludingZeroAndFullyUsed() throws {
        let output = """
        Model Usage                 Reqs                  Usage left
        gemini-2.5-flash-lite          1   100.0% (Resets in 23h 22m)
        gemini-3-flash-preview        30    79.9% (Resets in 2h)
        gemini-2.5-flash               -    79.9% (Resets in 2h)
        gemini-2.5-pro                 -     0.0%
        """
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try GeminiTerminalProbe.parse(output, now: now)
        XCTAssertEqual(snapshot.windows.count, 4)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 0)
        XCTAssertEqual(snapshot.windows[3].usedPercent, 100)
        XCTAssertNil(snapshot.windows[3].resetAt)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[1].resetAt).timeIntervalSince(now), 7_200, accuracy: 0.1)
        XCTAssertEqual(snapshot.windows[1].key, "gemini-3-flash-preview")
    }

    func testNormalizesAnsiRedrawsAndScreenReaderWrapping() throws {
        let ansi = "\u{1B}[2K\rgemini-2.5-pro  -  94.9% (Resets in 1h)\r\n"
        XCTAssertEqual(try XCTUnwrap(GeminiTerminalProbe.parse(ansi, now: .init()).windows.first).usedPercent, 5.1, accuracy: 0.01)
        let wrapped = "g\ne\nm\ni\nn\ni\n-\n2\n.\n5\n-\np\nr\no\n \n-\n \n1\n0\n0\n.\n0\n%"
        XCTAssertEqual(try GeminiTerminalProbe.parse(wrapped, now: .init()).windows.first?.usedPercent, 0)
    }

    func testSanitizesTerminalControlsFromDiagnostics() {
        let raw = "\u{1B}[?2004h\u{1B}[2K\u{1B}[1Aworkspace (/directory)\r\n~/tmp sandbox\u{7}"
        let diagnostic = CommandRunner.sanitizeDiagnostic(raw)
        XCTAssertEqual(diagnostic, "workspace (/directory)\n~/tmp sandbox")
        XCTAssertFalse(diagnostic.contains("[?2004h"))
        XCTAssertFalse(diagnostic.unicodeScalars.contains(where: { $0.value == 0x1b || $0.value == 0x07 }))
    }

    func testGeminiProbeUsesFullStatsAndBoundedTerminal() throws {
        let script = GeminiTerminalProbe.expectScript(binary: "/tmp/gemini")
        let refresh = try XCTUnwrap(script.range(of: "run_command \"/stats\""))
        let modelView = try XCTUnwrap(script.range(of: "run_command \"/model\""))
        XCTAssertLessThan(refresh.lowerBound, modelView.lowerBound)
        XCTAssertTrue(script.contains("rows 40 columns 160"))
        XCTAssertTrue(script.contains("--screen-reader"))
        XCTAssertTrue(script.contains("--skip-trust"))
        XCTAssertTrue(script.contains("wait -nowait"))
        XCTAssertFalse(script.containsCaseInsensitive("waiting for authentication"))
        XCTAssertTrue(script.contains("Type your message or @path/to/file"))
        XCTAssertTrue(script.contains("set timeout 30"))
        XCTAssertTrue(script.contains("set timeout 45"))
        XCTAssertTrue(script.contains("Session Stats"))
        XCTAssertTrue(script.contains("set timeout 15"))
    }

    func testParsesGeminiModelPickerUsage() throws {
        let output = """
        Model usage
        Flash ▬▬▬▬▬▬▬▬▬ 0% Resets: 10:05 AM (16h 18m)
        Flash Lite ▬▬▬▬▬ 0.2% Resets: 9:58 AM (16h 11m)
        Pro ▬▬▬▬▬▬▬▬▬▬▬ 1% Resets: 10:01 AM (16h 14m)
        gemini-3.5-flash ▬▬▬ 4.5% Resets: 10:05 AM (16h
        18m)
        (Press Esc to close)
        """
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try GeminiTerminalProbe.parse(output, now: now)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Flash", "Flash Lite", "Pro", "3.5 Flash"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 0.2, 1, 4.5])
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[3].resetAt).timeIntervalSince(now), 58_680)
    }

    func testGeminiProbeDetectsTierRejectionAndFolderTrust() {
        let script = GeminiTerminalProbe.expectScript(binary: "/tmp/gemini")
        XCTAssertTrue(script.contains("QUOTABAR_INELIGIBLE"))
        XCTAssertTrue(script.contains("QUOTABAR_TRUST"))
        XCTAssertTrue(script.containsCaseInsensitive("no longer supported"))
        XCTAssertTrue(script.containsCaseInsensitive("migrate to the antigravity"))
        XCTAssertTrue(script.containsCaseInsensitive("do you trust the files in this folder"))
        // The sign-in menu defers to classify_auth rather than reporting straight
        // away, so a tier rejection arriving a moment later still wins.
        // Killing only the spawned pid leaves Gemini's children holding the
        // output pipe; the group is what has to go.
        XCTAssertTrue(script.contains("set child [exp_pid]"))
        XCTAssertTrue(script.contains("kill -TERM -$child"))
        XCTAssertTrue(script.contains("kill -KILL -$child"))
        XCTAssertTrue(script.contains("proc classify_auth"))
        XCTAssertTrue(script.contains("{classify_auth}"))
        XCTAssertFalse(script.contains("select.*auth)} {puts \"QUOTABAR_AUTH\""))
        // Every branch that gives up still tears the child down, the `eof`
        // ones included: end of file means the pty slave was closed, not that
        // the group Gemini spawned has exited, and `CommandRunner` signals
        // expect's own group rather than the spawned session. Exempting a
        // branch here because it mentions `eof` is how four of them shipped
        // with no teardown at all.
        let exitPaths = script.components(separatedBy: "exit 0").dropLast()
        XCTAssertGreaterThanOrEqual(exitPaths.count, 8, "the exit paths stopped being enumerated")
        XCTAssertGreaterThanOrEqual(exitPaths.filter { $0.contains("eof {") }.count, 4,
                                    "the eof branches stopped being enumerated")
        for path in exitPaths {
            let branch = (path.split(separator: "\n").last.map(String.init) ?? path)
                .trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(path.contains("stop_child"), "an exit path leaves the child running: \(branch)")
        }
    }

    /// Typing a slash command is not running one. Gemini's `handleSlashCommand`
    /// returns early while the command registry is still loading, and the text
    /// then goes to the model as an ordinary, billed prompt — against the quota
    /// the probe exists to read, and silently, because the transcript never
    /// matches and the user only ever sees a timeout. Enter may therefore be
    /// pressed from one place only: after the suggestion row that proves the
    /// registry is live.
    func testGeminiProbeProvesTheRegistryIsLoadedBeforePressingEnter() throws {
        let script = GeminiTerminalProbe.expectScript(binary: "/tmp/gemini")
        let body = try XCTUnwrap(tclProcBody("run_command", in: script), "the handshake proc is missing")

        // `expectScript` is a non-raw literal, so `\\r` in it is a backslash and
        // an `r` for Tcl to read as a carriage return, not a control character.
        let submit = #"send -- "\r""#
        XCTAssertEqual(script.components(separatedBy: submit).count - 1, 1,
                       "Enter is sent from somewhere other than the handshake")
        let typed = try XCTUnwrap(body.range(of: "send -- $text"))
        let proof = try XCTUnwrap(body.range(of: "-re $description"))
        let pressed = try XCTUnwrap(body.range(of: submit))
        XCTAssertLessThan(typed.lowerBound, proof.lowerBound, "the proof is awaited before the command is typed")
        XCTAssertLessThan(proof.lowerBound, pressed.lowerBound, "Enter is pressed before the proof arrives")

        // Both give-up branches name the cause, tear the child down and leave
        // through `exit 0`, so neither can fall through to Enter: a reported
        // failure costs the user nothing and a model turn costs them the quota
        // being measured. End of file is no exemption from the teardown —
        // `testGeminiProbeDetectsTierRejectionAndFolderTrust` covers why.
        XCTAssertTrue(body.contains(#"timeout {puts "QUOTABAR_NOT_READY"; stop_child; exit 0}"#))
        XCTAssertTrue(body.contains(#"eof {puts "QUOTABAR_NOT_READY"; stop_child; exit 0}"#))

        // Both commands go through it; neither is typed blind.
        XCTAssertEqual(script.components(separatedBy: "run_command \"").count - 1, 2)
        XCTAssertFalse(script.contains("send -- \"/stats\""))
        XCTAssertFalse(script.contains("send -- \"/model\""))
    }

    /// The proof is a vendor string, so it is worth pinning against the ones
    /// Gemini CLI 0.43.0 actually ships — and against the screen it draws
    /// *before* the registry loads, which must not satisfy it.
    func testGeminiHandshakeMatchesTheSuggestionRowAndNotTheBareComposer() throws {
        let script = GeminiTerminalProbe.expectScript(binary: "/tmp/gemini")
        let patterns = handshakePatterns(in: script)
        XCTAssertEqual(Set(patterns.keys), Set(["/stats", "/model"]))

        let rows = [
            "/stats": "/stats   Check session stats. Usage: /stats [session|model|tools]",
            "/model": "/model   Manage model configuration"
        ]
        // Everything on screen before the registry has rendered a row: the
        // banner, the composer placeholder, and the echo of what was typed.
        let beforeTheRegistryLoads = """
        Gemini CLI 0.43.0
        Type your message or @path/to/file
        > /stats
        > /model
        """
        for (command, pattern) in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            func matches(_ text: String) -> Bool {
                regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
            XCTAssertTrue(matches(try XCTUnwrap(rows[command])), "\(command) does not match the row Gemini renders")
            XCTAssertFalse(matches(beforeTheRegistryLoads), "\(command) is satisfied before the registry has rendered anything")
            XCTAssertFalse(matches(command), "\(command) is satisfied by the echo of the command itself")
        }
    }

    /// The script's own stage timeouts have to fit inside the deadline the probe
    /// gives the whole run. If they do not, the deadline kills the child
    /// mid-stage and the transcript comes back without the marker that says what
    /// went wrong, so every diagnosis collapses into one bare timeout.
    func testGeminiScriptTimeoutBudgetFitsInsideTheOuterDeadline() throws {
        let script = GeminiTerminalProbe.expectScript(binary: "/tmp/gemini")
        let regex = try NSRegularExpression(pattern: #"set timeout (\d+)"#)
        func seconds(in text: String, of match: NSTextCheckingResult) -> Double? {
            Range(match.range(at: 1), in: text).flatMap { Double(text[$0]) }
        }
        let stages = regex.matches(in: script, range: NSRange(script.startIndex..., in: script))
            .compactMap { seconds(in: script, of: $0) }
        XCTAssertGreaterThan(stages.count, 3, "the stage timeouts are no longer written as literals")

        // The handshake's window lives inside a proc, so it is spent once per
        // call rather than once per script. Counting `classify_auth`'s window
        // too over-estimates — it only runs on a branch that then exits — which
        // is the safe direction for a budget.
        let body = try XCTUnwrap(tclProcBody("run_command", in: script))
        let match = try XCTUnwrap(regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)))
        let handshake = try XCTUnwrap(seconds(in: body, of: match))
        let calls = Double(script.components(separatedBy: "run_command \"").count - 1)
        let budget = stages.reduce(0, +) + handshake * (calls - 1)

        XCTAssertLessThan(budget, GeminiTerminalProbe.Budget.deadline,
                          "the script's own stages add up to \(budget)s, which the deadline cuts short")
    }

    /// The body of a Tcl proc, brace-matched from its header line.
    private func tclProcBody(_ name: String, in script: String) -> String? {
        guard let header = script.range(of: "proc \(name) "),
              let lineEnd = script[header.upperBound...].firstIndex(of: "\n"),
              let open = script[header.upperBound..<lineEnd].lastIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < script.endIndex {
            if script[index] == "{" { depth += 1 }
            if script[index] == "}" {
                depth -= 1
                if depth == 0 { return String(script[script.index(after: open)..<index]) }
            }
            index = script.index(after: index)
        }
        return nil
    }

    /// The `run_command "/stats" {pattern}` call sites, as command to pattern.
    private func handshakePatterns(in script: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"run_command "(/[a-z]+)" \{(.+)\}"#) else { return [:] }
        var found: [String: String] = [:]
        for match in regex.matches(in: script, range: NSRange(script.startIndex..., in: script)) {
            guard let command = Range(match.range(at: 1), in: script),
                  let pattern = Range(match.range(at: 2), in: script) else { continue }
            found[String(script[command])] = String(script[pattern])
        }
        return found
    }

    /// Gemini shows the same sign-in menu whether nobody is signed in or Google
    /// has withdrawn the tier, so the decisive marker has to win.
    func testGeminiFailurePrecedencePrefersTheDecisiveMarker() throws {
        func message(_ output: String) throws -> String {
            try XCTUnwrap(XCTUnwrap(GeminiTerminalProbe.failure(in: output)).errorDescription)
        }
        XCTAssertTrue(try message("QUOTABAR_AUTH\nQUOTABAR_INELIGIBLE\n").contains("no longer supports"))
        XCTAssertTrue(try message("QUOTABAR_AUTH\nQUOTABAR_TRUST\n").contains("folder-trust"))
        XCTAssertTrue(try message("QUOTABAR_AUTH\n").contains("sign in"))
        XCTAssertTrue(try message("QUOTABAR_STARTUP_TIMEOUT\n").contains("input prompt"))
        XCTAssertTrue(try message("QUOTABAR_STATS_TIMEOUT\n").contains("/stats"))
        XCTAssertTrue(try message("QUOTABAR_NOT_READY\n").contains("slash commands"))
        XCTAssertNil(GeminiTerminalProbe.failure(in: "gemini-2.5-pro   -   10.0% (Resets in 1h)"))
    }

    /// The real screen-reader transcript: the menu and the rejection arrive
    /// together, which is exactly the case that used to be misreported.
    func testGeminiTierRejectionTranscriptIsNotReportedAsSignIn() throws {
        let transcript = """
        How would you like to authenticate for this project?
        (checked) 1. Sign in with Google 2. Use Gemini API Key 3. Vertex AI
        Failed to sign in. Message: This client is no longer supported for Gemini
        Code Assist for individuals. To continue using Gemini, please migrate to
        the Antigravity suite of products: https://antigravity.google
        QUOTABAR_INELIGIBLE
        """
        let message = try XCTUnwrap(GeminiTerminalProbe.failure(in: transcript)?.errorDescription)
        XCTAssertTrue(message.contains("no longer supports"))
        XCTAssertFalse(message.contains("Open Gemini CLI and sign in"))
    }

    /// Screen-reader mode emits one character per line, which is how the phrase
    /// actually arrives — `W\na\ni\nt…`.
    private func screenReaderWrapped(_ text: String) -> String {
        text.map(String.init).joined(separator: "\n")
    }

    func testDetectsSignInWaitThroughScreenReaderWrapping() {
        let phrase = "waiting for authentication"
        XCTAssertTrue(GeminiTerminalProbe.mentions(phrase, in: "⠋ Waiting for authentication... (Press Esc to cancel)"))
        XCTAssertTrue(GeminiTerminalProbe.mentions(phrase, in: screenReaderWrapped("Waiting for authentication...")))
        XCTAssertFalse(GeminiTerminalProbe.mentions(phrase, in: "gemini-2.5-pro   -   10.0% (Resets in 1h)"))
        XCTAssertFalse(GeminiTerminalProbe.mentions(phrase, in: screenReaderWrapped("Model Usage")))
    }

    /// A brand-new install with no account never reaches the sign-in menu:
    /// Gemini opens a browser OAuth flow and asks about folder trust on top of
    /// it. Reporting only the trust prompt would hide the real blocker.
    func testFreshInstallWithNoAccountIsReportedAsUnfinishedSignIn() throws {
        let transcript = """
        Warning you are running Gemini CLI in your home directory.
        \(screenReaderWrapped("Waiting for authentication... (Press Esc or Ctrl+C to cancel)"))
        Do you trust the files in this folder?
        (checked) 1. Trust folder 2. Trust parent folder 3. Don't trust
        QUOTABAR_TRUST
        """
        let message = try XCTUnwrap(GeminiTerminalProbe.failure(in: transcript)?.errorDescription)
        XCTAssertTrue(message.contains("has not finished signing in"))
        XCTAssertTrue(message.contains("`gemini`"), "the message must name the command to run")
        XCTAssertFalse(message.hasPrefix("Gemini is waiting for a folder-trust decision"))
    }

    func testSignInWaitThatEndsInAStartupTimeoutIsAlsoUnfinishedSignIn() throws {
        let transcript = screenReaderWrapped("Waiting for authentication...") + "\nQUOTABAR_STARTUP_TIMEOUT\n"
        let message = try XCTUnwrap(GeminiTerminalProbe.failure(in: transcript)?.errorDescription)
        XCTAssertTrue(message.contains("has not finished signing in"))
        XCTAssertFalse(message.contains("did not reach its input prompt"))
    }

    func testFolderTrustAloneStillReportsFolderTrust() throws {
        let transcript = "Do you trust the files in this folder?\nQUOTABAR_TRUST\n"
        let message = try XCTUnwrap(GeminiTerminalProbe.failure(in: transcript)?.errorDescription)
        XCTAssertTrue(message.contains("folder-trust"))
        XCTAssertFalse(message.contains("has not finished signing in"))
    }

    func testTierRejectionOutranksAnUnfinishedSignIn() throws {
        let transcript = screenReaderWrapped("Waiting for authentication...")
            + "\nQUOTABAR_TRUST\nQUOTABAR_INELIGIBLE\n"
        let message = try XCTUnwrap(GeminiTerminalProbe.failure(in: transcript)?.errorDescription)
        XCTAssertTrue(message.contains("no longer supports"))
    }

    /// A signed-in client shows the same spinner briefly while refreshing a
    /// token. If it then reaches its prompt and reports quota, nothing failed.
    func testSignInWaitDoesNotFailAProbeThatStillReturnedQuota() throws {
        let transcript = """
        \(screenReaderWrapped("Waiting for authentication..."))
        Model Usage                 Reqs                  Usage left
        gemini-2.5-pro                 -    40.0% (Resets in 2h)
        QUOTABAR_STATS_COMPLETE
        """
        XCTAssertNil(GeminiTerminalProbe.failure(in: transcript))
        let snapshot = try GeminiTerminalProbe.parse(transcript, now: Date())
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 60)
    }

    func testOldSelectionAndWindowPayloadsMigrateToStableKeys() throws {
        let selection = try JSONDecoder().decode(QuotaSelection.self, from: Data(#"{"provider":"Codex","windowLabel":"Weekly"}"#.utf8))
        XCTAssertEqual(selection.windowKey, "weekly")
        let window = try JSONDecoder().decode(QuotaWindow.self, from: Data(#"{"label":"Weekly","usedPercent":20,"resetAt":null}"#.utf8))
        XCTAssertEqual(window.key, "weekly")
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(#"{"provider":"Gemini CLI","windows":[]}"#.utf8))
        XCTAssertTrue(snapshot.probeSucceeded)
    }

    func testBadgesPickProviderAndModelInitials() {
        XCTAssertEqual(QuotaBadge.preferred(for: .init(provider: .codex, windowLabel: "Session")), "S")
        XCTAssertEqual(QuotaBadge.preferred(for: .init(provider: .claude, windowLabel: "Weekly")), "W")
        XCTAssertEqual(QuotaBadge.preferred(for: .init(provider: .gemini, windowKey: "gemini-2.5-flash-lite", windowLabel: "2.5 Flash Lite")), "L")
        XCTAssertEqual(QuotaBadge.preferred(for: .init(provider: .gemini, windowKey: "gemini-2.5-pro", windowLabel: "2.5 Pro")), "P")
    }

    func testUrgencyThresholds() {
        XCTAssertEqual(QuotaUrgency(usedPercent: 79.9), .normal)
        XCTAssertEqual(QuotaUrgency(usedPercent: 80), .warning)
        XCTAssertEqual(QuotaUrgency(usedPercent: 94.9), .warning)
        XCTAssertEqual(QuotaUrgency(usedPercent: 95), .critical)
    }

    /// `RelativeDateTimeFormatter` is unavailable on Linux, so this wording is ours.
    func testRelativeResetFormatsCompactly() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(QuotaFormatting.relativeReset(now.addingTimeInterval(-5), from: now), "now")
        XCTAssertEqual(QuotaFormatting.relativeReset(now.addingTimeInterval(30), from: now), "in under a minute")
        XCTAssertEqual(QuotaFormatting.relativeReset(now.addingTimeInterval(45 * 60), from: now), "in 45m")
        XCTAssertEqual(QuotaFormatting.relativeReset(now.addingTimeInterval(2 * 3_600), from: now), "in 2h")
        XCTAssertEqual(QuotaFormatting.relativeReset(now.addingTimeInterval(3 * 3_600 + 12 * 60), from: now), "in 3h 12m")
        XCTAssertEqual(QuotaFormatting.relativeReset(now.addingTimeInterval(2 * 86_400 + 4 * 3_600), from: now), "in 2d 4h")
    }

    func testRowsKeepFailedProvidersVisible() {
        let now = Date(timeIntervalSince1970: 0)
        let rows = QuotaFormatting.rows(for: [
            .init(provider: .claude, windows: [.init(label: "Session", usedPercent: 96, resetAt: now.addingTimeInterval(3_600))]),
            .init(provider: .codex, error: "Codex is not installed", probeSucceeded: false)
        ], now: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].urgency, .critical)
        XCTAssertEqual(rows[0].resetText, "resets in 1h")
        XCTAssertNil(rows[1].usedPercent)
        XCTAssertEqual(rows[1].error, "Codex is not installed")
    }

    func testWaybarPayloadLeadsWithMostUrgentRow() {
        let now = Date(timeIntervalSince1970: 0)
        let payload = WaybarPayload(rows: QuotaFormatting.rows(for: [
            .init(provider: .claude, windows: [
                .init(label: "Session", usedPercent: 12, resetAt: nil),
                .init(label: "Weekly", usedPercent: 97, resetAt: nil)
            ])
        ], now: now))
        XCTAssertEqual(payload.text, "W 97%")
        XCTAssertEqual(payload.class, "critical")
        XCTAssertEqual(payload.percentage, 97)
        XCTAssertTrue(payload.tooltip.contains("Claude Code Session: 12%"))
    }

    func testWaybarTooltipNamesProvidersWithNoDataPlainly() {
        let payload = WaybarPayload(rows: QuotaFormatting.rows(for: [
            .init(provider: .gemini, error: "expect is not installed.", probeSucceeded: false)
        ], now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(payload.tooltip, "Gemini CLI: expect is not installed.")
        XCTAssertEqual(payload.text, "n/a")
    }

    func testRetainingLastGoodKeepsPreviousWindowsAndFlagsTheFailure() {
        let previous: [QuotaSnapshot] = [
            .init(provider: .gemini, windows: [.init(label: "Pro", usedPercent: 40, resetAt: nil)])
        ]
        let fresh: [QuotaSnapshot] = [
            .init(provider: .gemini, error: "Gemini did not respond", probeSucceeded: false)
        ]
        let merged = QuotaEngine.retainingLastGood(fresh: fresh, previous: previous)
        XCTAssertEqual(merged.first?.windows.first?.usedPercent, 40)
        XCTAssertEqual(merged.first?.error, "Refresh failed: Gemini did not respond")
        XCTAssertEqual(merged.first?.probeSucceeded, false)
    }

    func testJSONFileStateStoreRoundTripsAcrossInstances() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-test-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = JSONFileStateStore(url: url)
        writer.setData(Data("cached".utf8), forKey: "snapshot")
        writer.setInteger(30, forKey: "interval")

        let reader = JSONFileStateStore(url: url)
        XCTAssertEqual(reader.data(forKey: "snapshot"), Data("cached".utf8))
        XCTAssertEqual(reader.integer(forKey: "interval"), 30)
        XCTAssertNil(reader.data(forKey: "absent"))
    }

    /// A --watch process and a one-shot run share this file. Writes must not push
    /// a start-of-process snapshot over keys another process has since written.
    func testJSONFileStateStoreDoesNotClobberOtherWriters() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-test-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let watcher = JSONFileStateStore(url: url)
        watcher.setInteger(1, forKey: "watcher")

        let oneShot = JSONFileStateStore(url: url)
        oneShot.setData(Data("dedup".utf8), forKey: "delivered")

        // The watcher still holds its own pre-existing snapshot; writing again
        // must merge rather than drop the one-shot's key.
        watcher.setInteger(2, forKey: "watcher")

        let fresh = JSONFileStateStore(url: url)
        XCTAssertEqual(fresh.integer(forKey: "watcher"), 2)
        XCTAssertEqual(fresh.data(forKey: "delivered"), Data("dedup".utf8))
    }

    func testAlertEvaluatorDedupesPerWindowPeriodAndLevel() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-test-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshots: [QuotaSnapshot] = [
            .init(provider: .claude, windows: [
                .init(label: "Session", usedPercent: 82, resetAt: reset),
                .init(label: "Weekly", usedPercent: 96, resetAt: reset),
                .init(label: "Spare", usedPercent: 10, resetAt: reset)
            ])
        ]
        let evaluator = AlertEvaluator(store: JSONFileStateStore(url: url))
        let first = await evaluator.pending(for: snapshots)
        XCTAssertEqual(first.map(\.level), [.warning, .critical])

        for alert in first { await evaluator.markDelivered(alert) }
        let second = await evaluator.pending(for: snapshots)
        XCTAssertTrue(second.isEmpty)

        // A new reset period is a new alert even at the same threshold.
        let nextPeriod: [QuotaSnapshot] = [
            .init(provider: .claude, windows: [.init(label: "Session", usedPercent: 82, resetAt: reset.addingTimeInterval(3_600))])
        ]
        let third = await evaluator.pending(for: nextPeriod)
        XCTAssertEqual(third.count, 1)
    }

    func testAlertEvaluatorIgnoresSnapshotsCarryingAnError() {
        let snapshots: [QuotaSnapshot] = [
            .init(provider: .gemini,
                  windows: [.init(label: "Pro", usedPercent: 99, resetAt: nil)],
                  error: "Refresh failed: stale", probeSucceeded: false)
        ]
        XCTAssertTrue(AlertEvaluator.alerts(for: snapshots).isEmpty)
    }
}
