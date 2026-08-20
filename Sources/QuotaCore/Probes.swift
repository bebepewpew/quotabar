import Foundation

protocol QuotaProbe: Sendable { func fetch() throws -> QuotaSnapshot }

/// `JSONSerialization` bridges numbers to `NSNumber` on Darwin, but on
/// swift-corelibs-foundation they arrive as plain `Int`/`Double`, so an
/// `as? NSNumber` cast silently yields zero for every Codex quota on Linux.
func jsonNumber(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: return number.doubleValue
    case let number as Double: return number
    case let number as Int: return Double(number)
    case let text as String: return Double(text)
    default: return nil
    }
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
    func fetch() throws -> QuotaSnapshot {
        guard let binary = CommandRunner.find("gemini") else { throw ProbeError.missing("Gemini CLI") }
        let output = try CommandRunner.runExpect(Self.expectScript(binary: binary), timeout: 125, currentDirectory: probeWorkingDirectory())
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
            set timeout 6
            expect {
                -re {(?i)(no longer supported|migrate to the antigravity|ineligible)} {puts "QUOTABAR_INELIGIBLE"}
                timeout {puts "QUOTABAR_AUTH"}
                eof {puts "QUOTABAR_AUTH"}
            }
            stop_child
            exit 0
        }
        set timeout 30
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
            eof {puts "QUOTABAR_STARTUP_TIMEOUT"; exit 0}
        }
        # Full /stats performs the quota refresh in Gemini 0.56, but its default
        # view contains session data only. Wait for it to finish before opening
        # /model, which renders the freshly updated account-wide quota buckets.
        after 300
        send -- "/stats"
        after 100
        send -- "\\r"
        set timeout 45
        expect {
            -re {(?i)Session Stats} {}
            -re {(?i)(no longer supported|migrate to the antigravity)} {puts "QUOTABAR_INELIGIBLE"; stop_child; exit 0}
            -re {(?i)do you trust the files in this folder} {puts "QUOTABAR_TRUST"; stop_child; exit 0}
            -re {(?i)(sign in|log in|authentication required|select.*auth)} {classify_auth}
            timeout {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STATS_TIMEOUT"; exit 0}
        }
        set timeout 15
        expect {
            -re {Type your message or @path/to/file} {}
            timeout {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STATS_TIMEOUT"; exit 0}
        }
        after 300
        send -- "/model"
        after 100
        send -- "\\r"
        set timeout 30
        expect {
            -re {(?i)\\(Press Esc to close\\)} {puts "QUOTABAR_STATS_COMPLETE"}
            timeout {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STATS_TIMEOUT"; exit 0}
        }
        stop_child
        """
    }

    static func parse(_ raw: String, now: Date) throws -> QuotaSnapshot {
        let output = normalize(raw)
        let modelPattern = #"(?ims)^\s*(Flash Lite|Flash|Pro|gemini-[a-z0-9._-]+)\s+.*?(\d{1,3}(?:\.\d+)?)%\s+Resets:\s+.*?\(([^)]*)\)"#
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
    func fetch() throws -> QuotaSnapshot {
        guard let binary = CommandRunner.find("claude") else { throw ProbeError.missing("Claude Code") }
        let data = try CommandRunner.run(binary, ["-p", "/usage"], timeout: 45, currentDirectory: probeWorkingDirectory())
        let output = String(decoding: data, as: UTF8.self)
        return try Self.parse(output, now: Date())
    }

    static func parse(_ output: String, now: Date) throws -> QuotaSnapshot {
        var windows: [QuotaWindow] = []
        let pattern = #"(?im)^Current (session|week)(?: \(([^)]+)\))?:\s*(\d{1,3}(?:\.\d+)?)%\s*used\s*·\s*resets\s+(.+?)\s*\(([^)]+)\)\s*$"#
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
            if output.containsCaseInsensitive("login") || output.containsCaseInsensitive("authentication") {
                throw ProbeError.unsupported("Claude authentication is required. Open Claude Code once and sign in.")
            }
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

    func fetch() throws -> QuotaSnapshot {
        guard let binary = CommandRunner.find("codex") else { throw ProbeError.missing("Codex") }
        // app-server speaks line-delimited JSON-RPC over stdio and silently ignores
        // requests sent before the initialize response, so the exchange has to be
        // sequenced — but plain pipes are enough for that. No pseudo-terminal, so
        // no `expect` dependency and nothing platform-specific, and still no
        // copying of the CLI's OAuth credentials into this app.
        let session = try ProcessLineSession(executable: binary, arguments: ["app-server", "--stdio"],
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
            throw Self.failure(transcript, detail: "Codex returned an unreadable quota response. Refresh after updating Codex.")
        }
        return Self.parse(result)
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

    static func parse(_ result: [String: Any]) -> QuotaSnapshot {
        let root = (result["rateLimits"] as? [String: Any]) ?? result
        let plan = root["planType"] as? String ?? root["plan_type"] as? String
        var windows: [QuotaWindow] = []
        func add(_ value: Any?, label: String) {
            guard let item = value as? [String: Any] else { return }
            let used = jsonNumber(item["usedPercent"]) ?? jsonNumber(item["used_percent"]) ?? 0
            let timestamp = jsonNumber(item["resetsAt"]) ?? jsonNumber(item["resets_at"])
            let minutes = (jsonNumber(item["windowDurationMins"]) ?? jsonNumber(item["window_duration_mins"])).map { Int($0) }
            let resolvedLabel = minutes.map { $0 >= 1_440 ? "Weekly" : ($0 <= 360 ? "Session" : label) } ?? label
            windows.append(.init(label: resolvedLabel, usedPercent: min(max(used, 0), 100), resetAt: timestamp.map(Date.init(timeIntervalSince1970:))))
        }
        add(root["primary"], label: "Session")
        add(root["secondary"], label: "Weekly")
        if windows.isEmpty, let limits = root["limits"] as? [[String: Any]] {
            for (index, item) in limits.enumerated() { add(item, label: index == 0 ? "Session" : "Window \(index + 1)") }
        }
        return .init(provider: .codex, windows: windows, plan: plan, error: windows.isEmpty ? "No active quota windows" : nil)
    }
}
