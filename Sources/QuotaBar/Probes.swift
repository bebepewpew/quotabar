import Foundation

protocol QuotaProbe: Sendable { func fetch() throws -> QuotaSnapshot }

private func probeWorkingDirectory() -> URL {
    let candidate = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tmp", isDirectory: true)
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && isDirectory.boolValue
        ? candidate : FileManager.default.homeDirectoryForCurrentUser
}


struct GeminiTerminalProbe: QuotaProbe {
    func fetch() throws -> QuotaSnapshot {
        guard let binary = CommandRunner.find("gemini") else { throw ProbeError.missing("Gemini CLI") }
        let output = try CommandRunner.runExpect(Self.expectScript(binary: binary), timeout: 45, currentDirectory: probeWorkingDirectory())
        if output.contains("QUOTABAR_AUTH") { throw ProbeError.unsupported("Gemini authentication is required. Open Gemini CLI and sign in.") }
        if output.contains("QUOTABAR_STARTUP_TIMEOUT") { throw ProbeError.unsupported("Gemini did not reach its input prompt in time.") }
        if output.contains("QUOTABAR_STATS_TIMEOUT") { throw ProbeError.unsupported("Gemini did not finish refreshing /stats in time.") }
        return try Self.parse(output, now: Date())
    }

    static func expectScript(binary: String) -> String {
        """
        proc stop_child {} { catch {send -- "\\003"}; catch {send -- "/quit\\r"}; catch {close}; catch {wait} }
        set timeout 18
        set env(TERM) xterm-256color
        set env(NO_COLOR) 1
        spawn -noecho \(CommandRunner.tclQuoted(binary)) --screen-reader
        stty rows 40 columns 160 < $spawn_out(slave,name)
        expect {
            -re {(?i)(sign in|log in|authentication required|select.*auth)} {puts "QUOTABAR_AUTH"; stop_child; exit 0}
            -re {(User:|[>❯]) *$} {}
            timeout {puts "QUOTABAR_STARTUP_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STARTUP_TIMEOUT"; exit 0}
        }
        send -- "/stats\\r"
        set timeout 25
        expect {
            -re {(?i)(Model Usage|Usage left)} {}
            -re {(?i)(sign in|log in|authentication required)} {puts "QUOTABAR_AUTH"; stop_child; exit 0}
            timeout {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STATS_TIMEOUT"; exit 0}
        }
        expect {
            -re {(User:|[>❯]) *$} {puts "QUOTABAR_STATS_COMPLETE"}
            timeout {puts "QUOTABAR_STATS_TIMEOUT"; stop_child; exit 0}
            eof {puts "QUOTABAR_STATS_TIMEOUT"; exit 0}
        }
        stop_child
        """
    }

    static func parse(_ raw: String, now: Date) throws -> QuotaSnapshot {
        let output = normalize(raw)
        let regex = try NSRegularExpression(pattern: #"(?im)^\s*(gemini-[a-z0-9._-]+)\s+(?:-|[\d,]+)\s+(\d{1,3}(?:\.\d+)?)%\s*(?:\((?:resets?\s+)?([^\r\n)]*)\))?\s*$"#)
        var windows: [QuotaWindow] = []
        var seen = Set<String>()
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count == 1 { characters += trimmed }
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
        let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*([dhms])\b"#, options: .caseInsensitive)
        var interval: TimeInterval = 0
        for match in regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let number = Double(text[numberRange]) else { continue }
            let multiplier: TimeInterval = ["d": 86_400, "h": 3_600, "m": 60, "s": 1][text[unitRange].lowercased()] ?? 0
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
        var windows: [QuotaWindow] = []
        let rows: [(String, String)] = [
            (#"(?im)^Current session:\s*(\d{1,3})%\s*used\s*·\s*resets\s+(.+?)\s*\(([^)]+)\)\s*$"#, "Session"),
            (#"(?im)^Current week \(all models\):\s*(\d{1,3})%\s*used\s*·\s*resets\s+(.+?)\s*\(([^)]+)\)\s*$"#, "Weekly")
        ]
        for (pattern, label) in rows {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output),
                  let percent = Double(output[range]) else { continue }
            let resetText = Range(match.range(at: 2), in: output).map { String(output[$0]) }
            let timeZoneName = Range(match.range(at: 3), in: output).map { String(output[$0]) }
            let resetAt = resetText.flatMap { Self.parseReset($0, timeZoneName: timeZoneName, now: Date()) }
            windows.append(.init(label: label, usedPercent: min(percent, 100), resetAt: resetAt))
        }
        guard !windows.isEmpty else {
            if output.localizedCaseInsensitiveContains("login") || output.localizedCaseInsensitiveContains("authentication") {
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
        let date = ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy"].lazy.compactMap { format -> Date? in
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
    func fetch() throws -> QuotaSnapshot {
        guard let binary = CommandRunner.find("codex") else { throw ProbeError.missing("Codex") }
        // app-server requires strict sequencing: it silently ignores requests sent
        // before the initialize response. expect gives us that handshake without
        // copying the CLI's OAuth credentials into this app.
        let script = """
        set timeout 12
        spawn -noecho \(CommandRunner.tclQuoted(binary)) app-server --stdio
        stty -echo < $spawn_out(slave,name)
        send -- "{\\"id\\":1,\\"method\\":\\"initialize\\",\\"params\\":{\\"clientInfo\\":{\\"name\\":\\"QuotaBar\\",\\"title\\":\\"QuotaBar\\",\\"version\\":\\"0.1.0\\"},\\"capabilities\\":{}}}\\n"
        expect { -re {"id":1} {} timeout {puts "QUOTABAR_ERROR=initialize timeout"; exit 2} eof {exit 2} }
        send -- "{\\"method\\":\\"initialized\\"}\\n{\\"id\\":2,\\"method\\":\\"account/rateLimits/read\\"}\\n"
        expect { -re {"id":2.*\\r\\n} {} timeout {puts "QUOTABAR_ERROR=quota timeout"; exit 2} eof {exit 2} }
        close
        """
        let output = try CommandRunner.runExpect(script, timeout: 30)
        let objects = output.components(separatedBy: .newlines).compactMap { line -> [String: Any]? in
            guard let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}") else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(line[start...end].utf8)) as? [String: Any]
        }
        guard let response = objects.first(where: { ($0["id"] as? NSNumber)?.intValue == 2 }),
              let result = response["result"] as? [String: Any] else {
            if output.localizedCaseInsensitiveContains("not logged in") || output.localizedCaseInsensitiveContains("authentication") {
                throw ProbeError.unsupported("Codex authentication is required. Open Codex once and sign in.")
            }
            throw ProbeError.unsupported("Codex returned an unreadable quota response. Refresh after updating Codex.")
        }
        return Self.parse(result)
    }

    static func parse(_ result: [String: Any]) -> QuotaSnapshot {
        let root = (result["rateLimits"] as? [String: Any]) ?? result
        let plan = root["planType"] as? String ?? root["plan_type"] as? String
        var windows: [QuotaWindow] = []
        func add(_ value: Any?, label: String) {
            guard let item = value as? [String: Any] else { return }
            let used = (item["usedPercent"] as? NSNumber)?.doubleValue ?? (item["used_percent"] as? NSNumber)?.doubleValue ?? 0
            let timestamp = (item["resetsAt"] as? NSNumber)?.doubleValue ?? (item["resets_at"] as? NSNumber)?.doubleValue
            let minutes = (item["windowDurationMins"] as? NSNumber)?.intValue ?? (item["window_duration_mins"] as? NSNumber)?.intValue
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
