import Foundation

protocol QuotaProbe: Sendable { func fetch() throws -> QuotaSnapshot }

/// The command execution every `fetch()` depends on, gathered behind one seam.
///
/// The parsers were always testable; the half of each probe that shells out was
/// not, because it needed a real Codex, Claude Code or Gemini install. The
/// default implementation forwards to `CommandRunner`/`ProcessLineSession`, so
/// production behaviour is unchanged, while tests substitute a stub and drive
/// the not-installed, authentication, unreadable-response and success branches.
protocol ProbeRunner: Sendable {
    func find(_ executable: String) -> String?
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, currentDirectory: URL?) throws -> Data
    func runExpect(_ script: String, timeout: TimeInterval, currentDirectory: URL?) throws -> String
    func lineSession(executable: String, arguments: [String], currentDirectory: URL?) throws -> any LineSession
}

/// The line-delimited conversation `CodexProbe` sequences its JSON-RPC exchange
/// over. `ProcessLineSession` is the process-backed implementation; a test can
/// script the replies instead, including a server that never answers.
protocol LineSession: AnyObject, Sendable {
    func send(_ line: String) throws
    func waitForLine(matching matches: (String) -> Bool, before deadline: Date, transcript: inout [String]) -> String?
    func close()
}

extension ProcessLineSession: LineSession {}

/// The real toolchain: child processes with the deadlines and process-group
/// teardown `CommandRunner` and `ProcessLineSession` already implement.
struct SystemProbeRunner: ProbeRunner {
    func find(_ executable: String) -> String? { CommandRunner.find(executable) }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, currentDirectory: URL?) throws -> Data {
        try CommandRunner.run(executable, arguments, timeout: timeout, currentDirectory: currentDirectory)
    }

    func runExpect(_ script: String, timeout: TimeInterval, currentDirectory: URL?) throws -> String {
        try CommandRunner.runExpect(script, timeout: timeout, currentDirectory: currentDirectory)
    }

    func lineSession(executable: String, arguments: [String], currentDirectory: URL?) throws -> any LineSession {
        try ProcessLineSession(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
    }
}

/// `JSONSerialization` bridges numbers to `NSNumber` on Darwin, but on
/// swift-corelibs-foundation they arrive as plain `Int`/`Double`, so an
/// `as? NSNumber` cast silently yields zero for every Codex quota on Linux.
func jsonNumber(_ value: Any?) -> Double? {
    let number: Double?
    switch value {
    case let value as NSNumber: number = value.doubleValue
    case let value as Double: number = value
    case let value as Int: number = Double(value)
    case let value as String: number = Double(value)
    default: number = nil
    }
    // Untrusted CLI output can carry `"NaN"` or `1e400`, and `Double(_:)` parses
    // both. NaN then survives `min(max(used, 0), 100)` unclamped — comparing it
    // against anything is false, so neither bound applies — and a NaN percent
    // makes `JSONEncoder` reject the whole cached snapshot. Neither is a number
    // a quota or a reset timestamp can be built from.
    guard let number, number.isFinite else { return nil }
    return number
}

extension StringProtocol {
    /// `localizedCaseInsensitiveContains` depends on ICU collation that
    /// swift-corelibs-foundation does not always provide; plain case-insensitive
    /// search is enough for matching CLI error text.
    func containsCaseInsensitive(_ other: String) -> Bool {
        range(of: other, options: [.caseInsensitive]) != nil
    }
}

private func probeWorkingDirectory() -> URL {
    let candidate = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tmp", isDirectory: true)
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && isDirectory.boolValue
        ? candidate : FileManager.default.homeDirectoryForCurrentUser
}


struct GeminiTerminalProbe: QuotaProbe {
    /// The time the expect script may spend, named once and read twice: the
    /// script interpolates these values, and `deadline` — the bound `fetch()`
    /// puts on the child — is derived from the same numbers.
    ///
    /// They used to be chosen independently, a literal 125 beside a script whose
    /// own waits summed to 120.8, and raising any `set timeout` silently ate the
    /// margin the teardown needs. When the outer deadline wins that race the
    /// script is killed mid-`stop_child`, so "Gemini is waiting for a
    /// folder-trust decision" degrades to "The CLI did not respond in time".
    ///
    /// `scriptTimeouts` sums *every* wait, including branches that cannot both
    /// run. Each `set timeout` bounds at most one `expect`, so their sum bounds
    /// any path through the script, and a branch added later cannot quietly
    /// break the relation.
    enum Budget {
        /// Reaching the trust prompt, the sign-in menu, or the input prompt.
        static let startup = 30
        /// The tier rejection that arrives a moment after the sign-in menu.
        static let authClassification = 6
        /// `/stats` rendering its session view, which is what refreshes quota.
        static let statsView = 45
        /// Returning to the input prompt once `/stats` has finished.
        static let promptReturn = 15
        /// `/model` rendering the account-wide buckets.
        static let modelView = 30
        /// Milliseconds to let a view settle before typing into it.
        static let viewSettleMilliseconds = 300
        /// Milliseconds between a typed command and its Return.
        static let keyPressMilliseconds = 100
        /// `stop_child`: a Ctrl-C, two signals to the process group, a close and
        /// a wait, plus the interpreter exiting and its pipes draining. The
        /// script has to fit all of that inside the deadline, because a caller
        /// that kills it mid-teardown loses the verdict it already printed.
        static let teardown: TimeInterval = 5

        /// What the script's own `expect` waits can add up to.
        static var scriptTimeouts: TimeInterval {
            TimeInterval(startup + authClassification + statsView + promptReturn + modelView)
        }
        /// The pauses around the two commands the script types.
        static var sendPauses: TimeInterval {
            2 * TimeInterval(viewSettleMilliseconds + keyPressMilliseconds) / 1_000
        }
        /// The bound `fetch()` puts on the child: never less than the script can
        /// legitimately spend, so the script's own diagnostic wins the race.
        static var deadline: TimeInterval { scriptTimeouts + sendPauses + teardown }
    }

    let runner: any ProbeRunner

    init(runner: any ProbeRunner = SystemProbeRunner()) { self.runner = runner }

    func fetch() throws -> QuotaSnapshot {
        guard let binary = runner.find("gemini") else { throw ProbeError.missing("Gemini CLI") }
        let output: String
        do {
            output = try runner.runExpect(Self.expectScript(binary: binary),
                                          timeout: Budget.deadline, currentDirectory: probeWorkingDirectory())
        } catch {
            // `expect` writes the whole pseudo-terminal transcript to its stdout,
            // so a non-zero exit carries the session — markers and all — as the
            // command failure's detail, and an expired deadline carries whatever
            // reached us before it. The markers still say what blocked the probe;
            // the transcript itself must never reach the UI.
            //
            // Neither may the failure's own message. The executable handed to
            // `run` is the `expect` helper, so the message names *that* —
            // "expect exited with status 1" points at a binary the user never
            // invoked and cannot usefully run. Anything this probe cannot
            // classify is reported against the CLI it is actually for.
            guard let probeError = error as? ProbeError else { throw error }
            switch probeError {
            case .commandFailed(let commandFailure):
                throw Self.failure(in: commandFailure.detail)
                    ?? .unsupported("Gemini CLI did not finish. Run `gemini` in a terminal to see what it reports.")
            case .timeout(let partial):
                // The script prints its marker and only then tears the child
                // down, so a teardown that outlives the deadline used to throw
                // away an actionable message. What arrived before the deadline
                // still says why; anything else keeps the error it came with.
                guard let failure = Self.failure(in: partial) else { throw error }
                throw failure
            default:
                throw error
            }
        }
        if let failure = Self.failure(in: output) { throw failure }
        return try Self.parse(output, now: Date())
    }

    /// Maps the markers the expect script prints to an error, most specific first.
    ///
    /// Order matters. Gemini shows its "Sign in with Google / Use Gemini API Key /
    /// Vertex AI" menu both when nobody is signed in *and* when Google has
    /// withdrawn the account's tier — in the second case the next line reads
    /// "Failed to sign in … no longer supported". Reporting "sign in" there sends
    /// the user on an errand that cannot succeed.
    /// Screen-reader mode can wrap one character per line, so the transcript
    /// holds `W\na\ni\nt…` rather than the phrase. A plain substring search
    /// silently never matches; comparing with whitespace removed does.
    static func mentions(_ phrase: String, in output: String) -> Bool {
        func squashed(_ value: String) -> String {
            value.lowercased().filter { !$0.isWhitespace }
        }
        return squashed(normalize(output)).contains(squashed(phrase))
    }

    static func failure(in output: String) -> ProbeError? {
        if output.contains("QUOTABAR_INELIGIBLE") {
            return .unsupported("Gemini rejected this client: Google no longer supports Gemini Code Assist for individual accounts here. Signing in again will not help — see https://antigravity.google.")
        }
        // An account that has never been signed in never reaches the sign-in
        // menu: Gemini opens a browser OAuth flow, shows "Waiting for
        // authentication…", and asks about folder trust on top of it. Whichever
        // prompt we stopped on, the blocker is the unfinished sign-in, so it
        // outranks them. The phrase alone is not a verdict — a signed-in client
        // shows it briefly while refreshing a token and then reaches its prompt.
        if Self.mentions("waiting for authentication", in: output),
           output.contains("QUOTABAR_TRUST") || output.contains("QUOTABAR_STARTUP_TIMEOUT") {
            return .unsupported("Gemini has not finished signing in. Run `gemini` once and complete the prompts it shows — folder trust, then sign-in — before refreshing.")
        }
        if output.contains("QUOTABAR_TRUST") {
            return .unsupported("Gemini is waiting for a folder-trust decision. Start Gemini CLI once in your home directory and trust the folder.")
        }
        if output.contains("QUOTABAR_AUTH") {
            return .unsupported("Gemini authentication is required. Open Gemini CLI and sign in.")
        }
        if output.contains("QUOTABAR_STARTUP_TIMEOUT") {
            return .unsupported("Gemini did not reach its input prompt in time.")
        }
        if output.contains("QUOTABAR_STATS_TIMEOUT") {
            return .unsupported("Gemini did not finish refreshing /stats in time.")
        }
        return nil
    }

    static func expectScript(binary: String) -> String {
        """
        proc stop_child {} {
            # Ctrl-C and close leave Gemini's own children running: they keep the
            # output pipe open long after expect exits, so the transcript never
            # comes back and the probe reports a bare timeout instead of the
            # reason. Signal the spawned process *group*, which is what
            # AGENTS.md requires and what actually releases the pipe.
            # End of file says the slave side of the pty was closed, not that
            # everything Gemini spawned has exited, so the eof branches call
            # this too. Every step is caught: on eof the spawn id is already
            # closed, and the send and the close then fail harmlessly.
            set child [exp_pid]
            catch {send -- "\\003"}
            catch {exec kill -TERM -$child}
            catch {close}
            catch {exec kill -KILL -$child}
            catch {wait -nowait}
        }
        proc classify_auth {} {
            # The sign-in menu is also what Gemini shows when Google has withdrawn
            # the account's tier, and the rejection arrives a moment later. Wait for
            # it rather than reporting a sign-in that cannot succeed.
            set timeout \(Budget.authClassification)
            expect {
                -re {(?i)(no longer supported|migrate to the antigravity|ineligible)} {puts "QUOTABAR_INELIGIBLE"}
                timeout {puts "QUOTABAR_AUTH"}
                eof {puts "QUOTABAR_AUTH"}
            }
            stop_child
            exit 0
        }
        set timeout \(Budget.startup)
        set env(TERM) xterm-256color
        set env(NO_COLOR) 1
        spawn -noecho \(CommandRunner.tclQuoted(binary)) --screen-reader --skip-trust
        stty rows 40 columns 160 < $spawn_out(slave,name)
        expect {
            -re {(?i)(no longer supported|migrate to the antigravity)} {puts "QUOTABAR_INELIGIBLE"; stop_child; exit 0}
            -re {(?i)do you trust the files in this folder} {puts "QUOTABAR_TRUST"; stop_child; exit 0}
            -re {(?i)(sign in|log in|authentication required|select.*auth)} {classify_auth}
            -re {Type your message or @path/to/file} {}
            timeout {puts "QUOTABAR_STARTUP_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STARTUP_TIMEOUT"; stop_child; exit 0}
        }
        # Full /stats performs the quota refresh in Gemini 0.56, but its default
        # view contains session data only. Wait for it to finish before opening
        # /model, which renders the freshly updated account-wide quota buckets.
        after \(Budget.viewSettleMilliseconds)
        send -- "/stats"
        after \(Budget.keyPressMilliseconds)
        send -- "\\r"
        set timeout \(Budget.statsView)
        expect {
            -re {(?i)Session Stats} {}
            -re {(?i)(no longer supported|migrate to the antigravity)} {puts "QUOTABAR_INELIGIBLE"; stop_child; exit 0}
            -re {(?i)do you trust the files in this folder} {puts "QUOTABAR_TRUST"; stop_child; exit 0}
            -re {(?i)(sign in|log in|authentication required|select.*auth)} {classify_auth}
            timeout {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
        }
        set timeout \(Budget.promptReturn)
        expect {
            -re {Type your message or @path/to/file} {}
            timeout {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
        }
        after \(Budget.viewSettleMilliseconds)
        send -- "/model"
        after \(Budget.keyPressMilliseconds)
        send -- "\\r"
        set timeout \(Budget.modelView)
        expect {
            -re {(?i)\\(Press Esc to close\\)} {puts "QUOTABAR_STATS_COMPLETE"}
            timeout {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
        }
        stop_child
        """
    }

    static func parse(_ raw: String, now: Date) throws -> QuotaSnapshot {
        let output = normalize(raw)
        // Every run here is confined to one line, and the parenthetical to two.
        // A dotall `.*?` between the model name and the percent let a row
        // without a `Resets:` clause reach into the row below and report the
        // neighbour's percentage under its own name, and made a transcript of
        // rows that never complete cost quadratic time to reject. `[^\S\n]` is
        // `\s` minus the newline; the reset parenthetical may still wrap once,
        // which is how a narrow terminal breaks `(16h 18m)`.
        let modelPattern = #"(?im)^[^\S\n]*(Flash Lite|Flash|Pro|gemini-[a-z0-9._-]+)[^\S\n]+[^\n]*?(\d{1,3}(?:\.\d+)?)%[^\S\n]+Resets:[^\S\n]+[^\n]*?\(([^)\n]*(?:\n[^)\n]*)?)\)"#
        let modelRegex = try NSRegularExpression(pattern: modelPattern)
        var windows: [QuotaWindow] = []
        var seen = Set<String>()
        for match in modelRegex.matches(in: output, range: NSRange(output.startIndex..., in: output)) {
            guard let nameRange = Range(match.range(at: 1), in: output),
                  let percentRange = Range(match.range(at: 2), in: output),
                  let used = Double(output[percentRange]) else { continue }
            let name = String(output[nameRange])
            let key = name.hasPrefix("gemini-") ? name : QuotaWindow.key(for: name)
            guard seen.insert(key).inserted else { continue }
            let reset = Range(match.range(at: 3), in: output).map { String(output[$0]) }
            let label = name.hasPrefix("gemini-") ? modelLabel(name) : name
            windows.append(.init(key: key, label: label, usedPercent: min(max(used, 0), 100), resetAt: reset.flatMap { parseReset($0, now: now) }))
        }
        if !windows.isEmpty { return .init(provider: .gemini, windows: windows) }

        let regex = try NSRegularExpression(pattern: #"(?im)^\s*(gemini-[a-z0-9._-]+)\s+(?:-|[\d,]+)\s+(\d{1,3}(?:\.\d+)?)%\s*(?:\((?:resets?\s+)?([^\r\n)]*)\))?\s*$"#)
        seen.removeAll()
        for match in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)) {
            guard let modelRange = Range(match.range(at: 1), in: output), let percentRange = Range(match.range(at: 2), in: output),
                  let remaining = Double(output[percentRange]) else { continue }
            let model = String(output[modelRange])
            guard seen.insert(model).inserted else { continue }
            let reset = Range(match.range(at: 3), in: output).map { String(output[$0]) }
            windows.append(.init(key: model, label: modelLabel(model), usedPercent: min(max(100 - remaining, 0), 100), resetAt: reset.flatMap { parseReset($0, now: now) }))
        }
        guard !windows.isEmpty else {
            let incomplete = output.range(of: #"gemini-[a-z0-9._-]+"#, options: [.regularExpression, .caseInsensitive]) != nil
            throw ProbeError.unsupported(incomplete ? "Gemini returned incomplete quota rows." : "Gemini returned an unsupported /stats response.")
        }
        return .init(provider: .gemini, windows: windows)
    }

    static func normalize(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: #"\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\u001B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        value = value.replacingOccurrences(of: #"(?m)^[|│╭╰╮╯─┌┐└┘ ]+|[|│╭╰╮╯─┌┐└┘ ]+$"#, with: "", options: .regularExpression)
        let lines = value.components(separatedBy: "\n")
        var rebuilt: [String] = [], characters = ""
        for line in lines {
            if line.count == 1 { characters += line }
            else { if !characters.isEmpty { rebuilt.append(characters); characters = "" }; rebuilt.append(line) }
        }
        if !characters.isEmpty { rebuilt.append(characters) }
        return rebuilt.joined(separator: "\n")
    }

    static func modelLabel(_ model: String) -> String {
        model.replacingOccurrences(of: "gemini-", with: "").split(separator: "-").map { part in
            part == "pro" ? "Pro" : part == "flash" ? "Flash" : part == "lite" ? "Lite" : String(part)
        }.joined(separator: " ")
    }

    static func parseReset(_ text: String, now: Date) -> Date? {
        let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(d(?:ays?)?|h(?:ours?)?|m(?:inutes?)?|s(?:econds?)?)\b"#, options: .caseInsensitive)
        var interval: TimeInterval = 0
        for match in regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[numberRange]) else { continue }
            let multiplier: TimeInterval = ["d": 86_400, "h": 3_600, "m": 60, "s": 1][String(text[unitRange].lowercased().prefix(1))] ?? 0
            interval += number * multiplier
        }
        return interval > 0 ? now.addingTimeInterval(interval) : nil
    }
}

struct ClaudePrintProbe: QuotaProbe {
    let runner: any ProbeRunner

    init(runner: any ProbeRunner = SystemProbeRunner()) { self.runner = runner }

    func fetch() throws -> QuotaSnapshot {
        guard let binary = runner.find("claude") else { throw ProbeError.missing("Claude Code") }
        let data: Data
        do {
            data = try runner.run(binary, ["-p", "/usage"], timeout: 45, currentDirectory: probeWorkingDirectory())
        } catch {
            // A signed-out `claude -p /usage` exits non-zero, so its "Please run
            // /login" arrives as a thrown command failure rather than as output
            // to parse. Only the zero-exit branch used to be classified, which
            // left the actionable step buried under raw CLI text.
            throw Self.authenticationFailure(in: Self.classifiableText(of: error)) ?? error
        }
        let output = String(decoding: data, as: UTF8.self)
        return try Self.parse(output, now: Date())
    }

    /// The text a thrown failure may be classified from.
    ///
    /// A command failure keeps the CLI's own output out of its message on
    /// purpose, so the sign-in prompt is only in the detail — reading the
    /// message instead would silently stop recognising a signed-out CLI. The
    /// detail is matched here and never returned: what comes back out of
    /// `authenticationFailure` is fixed text.
    static func classifiableText(of error: Error) -> String {
        guard let probe = error as? ProbeError else { return error.localizedDescription }
        return probe.diagnosticDetail ?? probe.localizedDescription
    }

    /// Untrusted CLI text in, one concise actionable error out — or nil when the
    /// text is about something other than signing in.
    static func authenticationFailure(in text: String) -> ProbeError? {
        guard text.containsCaseInsensitive("login") || text.containsCaseInsensitive("authentication") else { return nil }
        return .unsupported("Claude authentication is required. Open Claude Code once and sign in.")
    }

    static func parse(_ output: String, now: Date) throws -> QuotaSnapshot {
        var windows: [QuotaWindow] = []
        // `[^)\n]` rather than `[^)]`: an unclosed parenthesis used to send
        // each attempt scanning the rest of the transcript for a `)`, which is
        // quadratic over untrusted output. A row is one line.
        let pattern = #"(?im)^Current (session|week)(?: \(([^)\n]+)\))?:\s*(\d{1,3}(?:\.\d+)?)%\s*used\s*·\s*resets\s+(.+?)\s*\(([^)\n]+)\)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)) {
            guard let kindRange = Range(match.range(at: 1), in: output),
                  let percentRange = Range(match.range(at: 3), in: output),
                  let percent = Double(output[percentRange]) else { continue }
            let kind = String(output[kindRange]).lowercased()
            let pool = Range(match.range(at: 2), in: output).map { String(output[$0]) }
            let label = kind == "session" ? "Session" : (pool?.lowercased() == "all models" ? "Weekly" : "Weekly \(pool ?? "Models")")
            let resetText = Range(match.range(at: 4), in: output).map { String(output[$0]) }
            let timeZoneName = Range(match.range(at: 5), in: output).map { String(output[$0]) }
            let resetAt = resetText.flatMap { Self.parseReset($0, timeZoneName: timeZoneName, now: now) }
            windows.append(.init(label: label, usedPercent: min(percent, 100), resetAt: resetAt))
        }
        guard !windows.isEmpty else {
            if let failure = Self.authenticationFailure(in: output) { throw failure }
            throw ProbeError.unsupported("Claude returned an unreadable /usage response.")
        }
        return .init(provider: .claude, windows: windows)
    }

    static func parseReset(_ value: String, timeZoneName: String?, now: Date) -> Date? {
        let timeZone = timeZoneName.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: now)
        let input = "\(value) \(year)"
        // Claude Code has shipped both "Aug 22 at 2am" and "Aug 22, 8:59am".
        let formats = ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy",
                       "MMM d, h:mma yyyy", "MMM d, ha yyyy"]
        let date = formats.lazy.compactMap { format -> Date? in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            return formatter.date(from: input)
        }.first
        guard var date else { return nil }
        // Around New Year, Claude may report a January reset while it is still December.
        if date < (calendar.date(byAdding: .day, value: -30, to: now) ?? now) {
            date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
        } else if date > (calendar.date(byAdding: .day, value: 180, to: now) ?? now) {
            date = calendar.date(byAdding: .year, value: -1, to: date) ?? date
        }
        return date
    }
}

struct CodexProbe: QuotaProbe {
    static let initializeRequest =
        #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"QuotaBar","title":"QuotaBar","version":"0.1.0"},"capabilities":{}}}"#
    static let initializedNotification = #"{"method":"initialized"}"#
    static let rateLimitsRequest = #"{"id":2,"method":"account/rateLimits/read"}"#
    /// One message for every shape of unreadable reply: a payload that is not a
    /// result object, and a window inside one whose percentage is not a number.
    static let unreadableReply = "Codex returned an unreadable quota response. Refresh after updating Codex."

    let runner: any ProbeRunner

    init(runner: any ProbeRunner = SystemProbeRunner()) { self.runner = runner }

    func fetch() throws -> QuotaSnapshot {
        guard let binary = runner.find("codex") else { throw ProbeError.missing("Codex") }
        // app-server speaks line-delimited JSON-RPC over stdio and silently ignores
        // requests sent before the initialize response, so the exchange has to be
        // sequenced — but plain pipes are enough for that. No pseudo-terminal, so
        // no `expect` dependency and nothing platform-specific, and still no
        // copying of the CLI's OAuth credentials into this app.
        let session = try runner.lineSession(executable: binary, arguments: ["app-server", "--stdio"],
                                             currentDirectory: probeWorkingDirectory())
        defer { session.close() }

        let deadline = Date().addingTimeInterval(30)
        var transcript: [String] = []

        try session.send(Self.initializeRequest)
        guard session.waitForLine(matching: { Self.identifier(of: $0) == 1 },
                                  before: deadline, transcript: &transcript) != nil else {
            throw Self.failure(transcript, detail: "Codex did not answer the initialize request.")
        }

        try session.send(Self.initializedNotification)
        try session.send(Self.rateLimitsRequest)
        guard let reply = session.waitForLine(matching: { Self.identifier(of: $0) == 2 },
                                              before: deadline, transcript: &transcript),
              let result = Self.jsonObject(reply)?["result"] as? [String: Any] else {
            throw Self.failure(transcript, detail: Self.unreadableReply)
        }
        return try Self.parse(result)
    }

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line[start...end].utf8)) as? [String: Any]
    }

    static func identifier(of line: String) -> Double? {
        jsonObject(line).flatMap { jsonNumber($0["id"]) }
    }

    private static func failure(_ transcript: [String], detail: String) -> ProbeError {
        let output = transcript.joined(separator: "\n")
        if output.containsCaseInsensitive("not logged in") || output.containsCaseInsensitive("authentication") {
            return .unsupported("Codex authentication is required. Open Codex once and sign in.")
        }
        return .unsupported(detail)
    }

    /// Reads the quota windows out of an `account/rateLimits/read` result, or
    /// throws the reason the payload could not be read.
    ///
    /// A window whose percentage is missing, quoted `"NaN"` or otherwise not a
    /// finite number is a failed refresh, not a `0%` window. Inventing the zero
    /// both reported a quota nobody measured and, because the snapshot then
    /// looked successful, let it overwrite — or, with no windows at all, delete —
    /// the last good reading the cache was holding. Throwing keeps the retention
    /// seam in `QuotaEngine.load` and `SnapshotCache.update` in charge instead. A
    /// percentage that *is* a number is still clamped rather than refused, since
    /// `-5` and `250` are Codex rounding, not a broken payload.
    static func parse(_ result: [String: Any]) throws -> QuotaSnapshot {
        let root = (result["rateLimits"] as? [String: Any]) ?? result
        let plan = root["planType"] as? String ?? root["plan_type"] as? String
        var windows: [QuotaWindow] = []
        func add(_ value: Any?, label: String) throws {
            guard let item = value as? [String: Any] else { return }
            guard let used = jsonNumber(item["usedPercent"]) ?? jsonNumber(item["used_percent"]) else {
                throw ProbeError.unsupported(Self.unreadableReply)
            }
            let timestamp = jsonNumber(item["resetsAt"]) ?? jsonNumber(item["resets_at"])
            let minutes = (jsonNumber(item["windowDurationMins"]) ?? jsonNumber(item["window_duration_mins"])).map { Int($0) }
            let resolvedLabel = minutes.map { $0 >= 1_440 ? "Weekly" : ($0 <= 360 ? "Session" : label) } ?? label
            windows.append(.init(label: resolvedLabel, usedPercent: min(max(used, 0), 100), resetAt: timestamp.map(Date.init(timeIntervalSince1970:))))
        }
        try add(root["primary"], label: "Session")
        try add(root["secondary"], label: "Weekly")
        if windows.isEmpty, let limits = root["limits"] as? [[String: Any]] {
            for (index, item) in limits.enumerated() { try add(item, label: index == 0 ? "Session" : "Window \(index + 1)") }
        }
        guard !windows.isEmpty else { throw ProbeError.unsupported("No active quota windows") }
        return .init(provider: .codex, windows: windows, plan: plan)
    }
}
