import XCTest
import Foundation
@testable import QuotaCore

/// The parsing corners `ProbeFetchTests` and `QuotaCoreTests` do not reach.
///
/// Those two cover the happy paths and the markers a probe reports: this file
/// covers what each parser does with output that is duplicated by a redraw,
/// spelled a different way, truncated, shaped like a payload from an older or
/// newer CLI, or simply not a number. Every fixture is CLI text or a JSON-RPC
/// reply, and nothing here spawns a process.
final class ProbeParsingEdgeTests: XCTestCase {

    // MARK: - jsonNumber

    /// `JSONSerialization` hands numbers back as `NSNumber` on Darwin and as
    /// plain `Int`/`Double` on swift-corelibs-foundation, and Codex has shipped
    /// quoted numbers too. All three have to read as the same quota.
    func testJSONNumberAcceptsEveryShapeAQuotaNumberArrivesIn() {
        XCTAssertEqual(jsonNumber(NSNumber(value: 23)), 23)
        XCTAssertEqual(jsonNumber(42.5), 42.5)
        XCTAssertEqual(jsonNumber(7), 7)
        XCTAssertEqual(jsonNumber("3.25"), 3.25)
        XCTAssertEqual(jsonNumber("-1e2"), -100)
        XCTAssertEqual(jsonNumber(2_000_000_000), 2_000_000_000)
    }

    func testJSONNumberRejectsEverythingThatIsNotANumber() {
        XCTAssertNil(jsonNumber(nil))
        XCTAssertNil(jsonNumber("soon"))
        XCTAssertNil(jsonNumber(""))
        XCTAssertNil(jsonNumber(NSNull()))
        XCTAssertNil(jsonNumber(["usedPercent": 10]))
        XCTAssertNil(jsonNumber([1, 2, 3]))
    }

    /// Untrusted CLI output can spell a number `"NaN"` or `1e400`, and
    /// `Double(_:)` parses both. NaN compares false against everything, so it
    /// walks straight through `min(max(used, 0), 100)`, poisons the badge and
    /// makes `JSONEncoder` reject the whole cached snapshot.
    func testJSONNumberRejectsNonFiniteValues() throws {
        XCTAssertNil(jsonNumber("NaN"))
        XCTAssertNil(jsonNumber("nan"))
        XCTAssertNil(jsonNumber("inf"))
        XCTAssertNil(jsonNumber("-infinity"))
        XCTAssertNil(jsonNumber("1e400"))

        let snapshot = CodexProbe.parse(["rateLimits": ["primary": ["usedPercent": "NaN", "resetsAt": "inf"]]])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0])
        XCTAssertNil(snapshot.windows[0].resetAt)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot), "a non-finite percent must never reach the cache")
    }

    // MARK: - Gemini: normalize

    /// Gemini frames its panels in box-drawing characters and, in screen-reader
    /// mode, can wrap a row one character per line. A row has to survive both.
    func testGeminiNormalizeStripsFramesTitlesAndRejoinsWrappedRows() throws {
        let framed = """
        \u{1B}]0;gemini\u{07}╭──────────────────────────────────────╮
        │ Model Usage      Reqs      Usage left │
        │ gemini-2.5-pro      -      40.0%      │
        ╰──────────────────────────────────────╯
        """
        let normalized = GeminiTerminalProbe.normalize(framed)
        XCTAssertFalse(normalized.contains("│"))
        XCTAssertFalse(normalized.contains("╭"))
        XCTAssertFalse(normalized.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
        XCTAssertEqual(try XCTUnwrap(GeminiTerminalProbe.parse(framed, now: Date()).windows.first).usedPercent, 60)

        // A run of single-character lines rejoins into one row; an ordinary line
        // ends the run and stays where it was, and a run that reaches the end of
        // the transcript is still flushed.
        XCTAssertEqual(GeminiTerminalProbe.normalize("Model Usage\na\nb\nc"), "Model Usage\nabc")
        XCTAssertEqual(GeminiTerminalProbe.normalize("a\nb\nModel Usage\nc\nd"), "ab\nModel Usage\ncd")
    }

    // MARK: - Gemini: parse

    /// A terminal redraw leaves the previous copy of a row in the transcript.
    /// The first row wins, so a stale duplicate cannot overwrite fresh quota.
    func testGeminiParseKeepsTheFirstOfDuplicatedModelPickerRows() throws {
        let transcript = """
        Model usage
        Pro ▬▬▬▬▬▬ 1% Resets: 10:01 AM (16h 14m)
        Pro ▬▬▬▬▬▬ 37% Resets: 10:01 AM (16h 14m)
        (Press Esc to close)
        """
        let snapshot = try GeminiTerminalProbe.parse(transcript, now: Date())
        XCTAssertEqual(snapshot.windows.map(\.key), ["pro"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [1])
    }

    func testGeminiParseKeepsTheFirstOfDuplicatedStatsTableRows() throws {
        let transcript = """
        Model Usage                 Reqs                  Usage left
        gemini-2.5-pro                 -    40.0% (Resets in 2h)
        gemini-2.5-pro                 -    10.0% (Resets in 2h)
        """
        let snapshot = try GeminiTerminalProbe.parse(transcript, now: Date())
        XCTAssertEqual(snapshot.windows.map(\.key), ["gemini-2.5-pro"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [60])
    }

    /// Gemini omits the `Resets:` clause from a bucket it has not computed yet.
    /// The row parser used to read straight across the line break to find one,
    /// and reported the *next* model's percentage under the unfinished name.
    func testGeminiParseKeepsARowWithoutAResetFromClaimingTheNextRowsPercentage() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let transcript = """
        Model usage
        Pro ▬▬ 3%
        Flash ▬▬ 97% Resets: 10:05 AM (16h 18m)
        (Press Esc to close)
        """
        let snapshot = try GeminiTerminalProbe.parse(transcript, now: now)
        XCTAssertEqual(snapshot.windows.map(\.key), ["flash"], "an unfinished row must not borrow the row below it")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [97])
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[0].resetAt).timeIntervalSince(now), 58_680)

        // The same reach, one line shorter: a bare model name is not a row.
        let bare = try GeminiTerminalProbe.parse("""
        Model usage
        Pro
        Flash ▬▬ 97% Resets: 10:05 AM (16h 18m)
        """, now: now)
        XCTAssertEqual(bare.windows.map(\.key), ["flash"])
    }

    /// A narrow terminal breaks the reset parenthetical across the line it
    /// opened on. That wrap is a supported row form, so confining the row to a
    /// single line must not cost it.
    func testGeminiParseAcceptsAResetParentheticalThatWrapsOnce() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try GeminiTerminalProbe.parse("""
        Model usage
        gemini-3.5-flash ▬▬▬ 4.5% Resets: 10:05 AM (16h
        18m)
        (Press Esc to close)
        """, now: now)
        XCTAssertEqual(snapshot.windows.map(\.key), ["gemini-3.5-flash"])
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[0].resetAt).timeIntervalSince(now), 58_680)
    }

    /// The parse runs after the process deadline is already satisfied, so
    /// nothing bounds it, and `QuotaStore.refresh` holds `isRefreshing` until it
    /// returns. Rows that open like a model row and never finish used to cost
    /// quadratic time in three separate ways; 186 KB took about a minute.
    func testGeminiParseRejectsRowsThatNeverFinishWithoutBacktrackingForever() {
        let unfinished = ["Pro ▬▬▬ 3% used of the window\n",  // never reaches Resets:
                          "Pro ▬▬ 3% Resets: 10:05 AM soon\n",  // never reaches an open paren
                          "Pro ▬▬ 3% Resets: 10:05 AM (16h\n"]  // never closes the paren
        for row in unfinished {
            let transcript = String(repeating: row, count: 186_000 / row.count)
            XCTAssertGreaterThan(transcript.count, 180_000)
            let started = Date()
            XCTAssertThrowsError(try GeminiTerminalProbe.parse(transcript, now: Date()))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                              "\(transcript.count) characters of unfinished rows took too long to reject")
        }
    }

    /// Coming back with nothing has two different causes and two different
    /// answers: a row that a redraw cut in half is not the same complaint as a
    /// screen that never held quota at all.
    func testGeminiParseSeparatesATruncatedRowFromAnUnrecognisedScreen() {
        XCTAssertEqual(geminiParseFailure("Model Usage\ngemini-2.5-pro  -  1000%\nQUOTABAR_STATS_COMPLETE"),
                       "Gemini returned incomplete quota rows.")
        XCTAssertEqual(geminiParseFailure("Model Usage\nGEMINI-2.5-PRO\n"),
                       "Gemini returned incomplete quota rows.")
        XCTAssertEqual(geminiParseFailure("Model usage\nNo usage data available yet.\n(Press Esc to close)"),
                       "Gemini returned an unsupported /stats response.")
        XCTAssertEqual(geminiParseFailure(""), "Gemini returned an unsupported /stats response.")
    }

    // MARK: - Gemini: modelLabel

    func testGeminiModelLabelTitlesKnownPartsAndKeepsUnfamiliarOnes() {
        XCTAssertEqual(GeminiTerminalProbe.modelLabel("gemini-2.5-flash-lite"), "2.5 Flash Lite")
        XCTAssertEqual(GeminiTerminalProbe.modelLabel("gemini-3-pro-preview-11-2025"), "3 Pro preview 11 2025")
        XCTAssertEqual(GeminiTerminalProbe.modelLabel("flash"), "Flash", "a name without the vendor prefix still reads")
        XCTAssertEqual(GeminiTerminalProbe.modelLabel("gemini-Pro"), "Pro", "the mapping is exact, so a capitalised part is left alone")
        XCTAssertEqual(GeminiTerminalProbe.modelLabel("gemini-"), "")
        XCTAssertEqual(GeminiTerminalProbe.modelLabel(""), "")
    }

    // MARK: - Gemini: parseReset

    func testGeminiResetAddsEveryUnitSpellingItAccepts() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        func interval(_ text: String) throws -> TimeInterval {
            try XCTUnwrap(GeminiTerminalProbe.parseReset(text, now: now), "\(text) parsed as no duration")
                .timeIntervalSince(now)
        }
        XCTAssertEqual(try interval("Resets in 1d 2h 3m 4s"), 93_784, accuracy: 0.001)
        XCTAssertEqual(try interval("resets in 1 day"), 86_400, accuracy: 0.001)
        XCTAssertEqual(try interval("in 2 hours 30 minutes"), 9_000, accuracy: 0.001)
        XCTAssertEqual(try interval("45 seconds"), 45, accuracy: 0.001)
        XCTAssertEqual(try interval("1 HOUR"), 3_600, accuracy: 0.001, "the CLI upper-cases in some themes")
        XCTAssertEqual(try interval("1.5h"), 5_400, accuracy: 0.001)
    }

    /// The reset column is display text: an absolute clock time, an already
    /// elapsed window or an empty cell all mean "no deadline we can show".
    func testGeminiResetIsNilWhenTheTextHoldsNoDuration() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(GeminiTerminalProbe.parseReset("10:05 AM", now: now))
        XCTAssertNil(GeminiTerminalProbe.parseReset("in 0m", now: now))
        XCTAssertNil(GeminiTerminalProbe.parseReset("resets soon", now: now))
        XCTAssertNil(GeminiTerminalProbe.parseReset("", now: now))
    }

    // MARK: - Gemini: failure precedence

    /// `failure(in:)` reports the most specific marker in the transcript. These
    /// are the pairings the end-to-end tests do not already pin down.
    func testGeminiFailurePrecedenceAcrossOverlappingMarkers() throws {
        let rows: [(transcript: String, expected: String?)] = [
            ("QUOTABAR_AUTH\nQUOTABAR_STARTUP_TIMEOUT\n",
             "Gemini authentication is required. Open Gemini CLI and sign in."),
            ("QUOTABAR_TRUST\nQUOTABAR_STATS_TIMEOUT\n",
             "Gemini is waiting for a folder-trust decision. Start Gemini CLI once in your home directory and trust the folder."),
            ("QUOTABAR_STARTUP_TIMEOUT\nQUOTABAR_STATS_TIMEOUT\n",
             "Gemini did not reach its input prompt in time."),
            // The spinner alone is not a verdict: without a trust prompt or a
            // startup timeout behind it, the sign-in menu is what to report.
            ("Waiting for authentication...\nQUOTABAR_AUTH\n",
             "Gemini authentication is required. Open Gemini CLI and sign in."),
            ("QUOTABAR_INELIGIBLE\n",
             "Gemini rejected this client: Google no longer supports Gemini Code Assist for individual accounts here. Signing in again will not help — see https://antigravity.google."),
            ("", nil)
        ]
        for row in rows {
            XCTAssertEqual(GeminiTerminalProbe.failure(in: row.transcript)?.errorDescription, row.expected,
                           "misclassified: \(row.transcript.replacingOccurrences(of: "\n", with: " / "))")
        }
    }

    // MARK: - Claude Code: parse

    /// Claude Code prints the weekly row with a pool name, with `all models`,
    /// and — on older builds — with nothing at all.
    func testClaudeParseLabelsAWeeklyRowThatNamesNoPool() throws {
        let output = """
        Current week: 50% used · resets Aug 22 at 2am (Europe/Warsaw)
        """
        let snapshot = try ClaudePrintProbe.parse(output, now: Date())
        XCTAssertEqual(snapshot.windows.map(\.label), ["Weekly Models"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [50])
    }

    func testClaudeParseClampsAPercentAboveOneHundred() throws {
        let output = "Current session: 120% used · resets Aug 22 at 2am (Europe/Warsaw)"
        let snapshot = try ClaudePrintProbe.parse(output, now: Date())
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [100])
    }

    /// A pool name and a time-zone name are display text on the row's own line.
    /// Letting either cross the line break smuggled a newline into a window
    /// label, and made an unclosed parenthesis send every attempt scanning the
    /// rest of the transcript for a `)`: 180 KB of it used to take seconds.
    func testClaudeParseConfinesARowToASingleLine() {
        XCTAssertEqual(claudeParseFailure("Current week (all\nmodels): 50% used · resets Aug 22 at 2am (Europe/Warsaw)"),
                       "Claude returned an unreadable /usage response.")
        XCTAssertEqual(claudeParseFailure("Current week: 50% used · resets Aug 22 at 2am (Europe/\nWarsaw)"),
                       "Claude returned an unreadable /usage response.")

        let transcript = String(repeating: "Current week (aaaaaaaaaa: 50% used · resets x\n", count: 4_000)
        let started = Date()
        XCTAssertEqual(claudeParseFailure(transcript), "Claude returned an unreadable /usage response.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "\(transcript.count) characters of unclosed parentheses took too long to reject")
    }

    /// Coming back with no rows is either a sign-in prompt, which is
    /// actionable, or output we simply do not understand, which is not.
    func testClaudeParseSeparatesASignInPromptFromAnUnreadableResponse() {
        XCTAssertEqual(claudeParseFailure("Please run /login to continue"),
                       "Claude authentication is required. Open Claude Code once and sign in.")
        XCTAssertEqual(claudeParseFailure("Error: Authentication failed"),
                       "Claude authentication is required. Open Claude Code once and sign in.")
        XCTAssertEqual(claudeParseFailure("Usage data is temporarily unavailable"),
                       "Claude returned an unreadable /usage response.")
        XCTAssertEqual(claudeParseFailure("Current session: not available"),
                       "Claude returned an unreadable /usage response.")
    }

    // MARK: - Claude Code: parseReset

    /// Claude prints a reset as a bare month and day, so the year is ours to
    /// infer. In the last days of December the next reset is in January.
    func testClaudeResetRollsTheYearForwardForAJanuaryResetSeenInDecember() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 28, hour: 12)))
        let reset = try XCTUnwrap(ClaudePrintProbe.parseReset("Jan 2 at 3am", timeZoneName: "UTC", now: now))
        XCTAssertEqual(calendar.component(.year, from: reset), 2027)
        XCTAssertEqual(calendar.component(.month, from: reset), 1)
        XCTAssertEqual(calendar.component(.day, from: reset), 2)
        XCTAssertGreaterThan(reset, now, "a reset in the future must not be dated in the past")
    }

    /// And in the first days of January a still-open December window belongs to
    /// the year that just ended.
    func testClaudeResetRollsTheYearBackForADecemberResetSeenInJanuary() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12)))
        let reset = try XCTUnwrap(ClaudePrintProbe.parseReset("Dec 31, 11pm", timeZoneName: "UTC", now: now))
        XCTAssertEqual(calendar.component(.year, from: reset), 2025)
        XCTAssertEqual(calendar.component(.month, from: reset), 12)
        XCTAssertEqual(calendar.component(.day, from: reset), 31)
    }

    /// A date comfortably inside the window is left exactly where it is, which
    /// is what keeps the two rollovers above from firing on ordinary output.
    func testClaudeResetLeavesADateInsideTheWindowAlone() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12)))
        let reset = try XCTUnwrap(ClaudePrintProbe.parseReset("Aug 22 at 2am", timeZoneName: "UTC", now: now))
        XCTAssertEqual(calendar.component(.year, from: reset), 2026)
        XCTAssertEqual(calendar.component(.day, from: reset), 22)
    }

    func testClaudeResetFallsBackToTheLocalZoneForAnUnknownTimeZoneName() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12)))
        XCTAssertNotNil(ClaudePrintProbe.parseReset("Aug 22 at 2am", timeZoneName: nil, now: now))
        XCTAssertNotNil(ClaudePrintProbe.parseReset("Aug 22 at 2am", timeZoneName: "Not/AZone", now: now))
        XCTAssertNotNil(ClaudePrintProbe.parseReset("Aug 22 at 2am", timeZoneName: "", now: now))
    }

    func testClaudeResetIsNilForTextInNoSupportedFormat() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12)))
        XCTAssertNil(ClaudePrintProbe.parseReset("tomorrow", timeZoneName: "UTC", now: now))
        XCTAssertNil(ClaudePrintProbe.parseReset("2026-08-22T02:00:00Z", timeZoneName: "UTC", now: now))
        XCTAssertNil(ClaudePrintProbe.parseReset("", timeZoneName: "UTC", now: now))
    }

    // MARK: - Claude Code: fetch

    /// A failure that is not about signing in keeps the diagnostic that says
    /// what actually went wrong, even when it never was a `ProbeError`.
    func testClaudeFetchPassesANonProbeErrorThroughUntouched() {
        let runner = StubProbeRunner(executables: ["claude": "/usr/bin/claude"], runResult: .failure(BrokenPipeError()))
        XCTAssertThrowsError(try ClaudePrintProbe(runner: runner).fetch()) { error in
            XCTAssertTrue(error is BrokenPipeError, "an unrelated failure must not be reworded, got \(error)")
        }
    }

    /// …while a sign-in prompt is still recognised when it arrives inside a
    /// foreign error rather than a `ProbeError`.
    func testClaudeFetchClassifiesASignInPromptCarriedByAForeignError() {
        let underlying = NSError(domain: "ClaudeCLI", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "Invalid API key · Please run /login"])
        let runner = StubProbeRunner(executables: ["claude": "/usr/bin/claude"], runResult: .failure(underlying))
        XCTAssertThrowsError(try ClaudePrintProbe(runner: runner).fetch()) { error in
            XCTAssertEqual((error as? ProbeError)?.errorDescription,
                           "Claude authentication is required. Open Claude Code once and sign in.")
        }
    }

    // MARK: - Codex: jsonObject

    func testCodexJSONObjectNeedsABalancedObjectOnTheLine() {
        XCTAssertNil(CodexProbe.jsonObject(""))
        XCTAssertNil(CodexProbe.jsonObject("codex: command not found"))
        XCTAssertNil(CodexProbe.jsonObject("} {"), "a closing brace before the opening one is not an object")
        XCTAssertNil(CodexProbe.jsonObject("{not json}"))
        XCTAssertNil(CodexProbe.jsonObject("[1,2,3]"))
        XCTAssertNotNil(CodexProbe.jsonObject("warning: deprecated {\"id\":2} "),
                        "an object framed by log noise still reads")
        XCTAssertNil(CodexProbe.identifier(of: "no braces here"))
        XCTAssertNil(CodexProbe.identifier(of: #"{"id":"two"}"#), "a non-numeric id is not an id")
    }

    // MARK: - Codex: parse

    /// Older Codex builds answer with the rate limits at the top level and in
    /// snake_case. Both spellings have to read as the same quota.
    func testCodexParseReadsAFlatSnakeCaseReply() throws {
        let reply = try XCTUnwrap(CodexProbe.jsonObject("""
        {"id":2,"result":{"plan_type":"team",\
        "primary":{"used_percent":12.5,"resets_at":2000000000,"window_duration_mins":300},\
        "secondary":{"used_percent":80,"resets_at":2000100000,"window_duration_mins":10080}}}
        """))
        let snapshot = CodexProbe.parse(try XCTUnwrap(reply["result"] as? [String: Any]))
        XCTAssertEqual(snapshot.plan, "team")
        XCTAssertEqual(snapshot.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12.5, 80])
        XCTAssertEqual(snapshot.windows[0].resetAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(snapshot.windows[1].resetAt, Date(timeIntervalSince1970: 2_000_100_000))
        XCTAssertNil(snapshot.error)
    }

    /// A window duration between the session and weekly cutoffs is not one we
    /// can name, so the caller's label stands. A missing percent is 0, not a
    /// crash, and one above the ceiling is clamped.
    func testCodexParseKeepsTheCallersLabelForAnUnnamedDurationAndClampsThePercent() {
        let snapshot = CodexProbe.parse(["rateLimits": [
            "primary": ["windowDurationMins": 720],
            "secondary": ["usedPercent": 250, "windowDurationMins": 720]
        ]])
        XCTAssertEqual(snapshot.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 100])
        XCTAssertNil(snapshot.windows[0].resetAt)
        XCTAssertNil(snapshot.plan)
    }

    func testCodexParseNamesWindowsByTheirDurationAtEachCutoff() {
        func label(minutes: Int) -> String? {
            CodexProbe.parse(["rateLimits": ["primary": ["windowDurationMins": minutes]]]).windows.first?.label
        }
        XCTAssertEqual(label(minutes: 360), "Session")
        XCTAssertEqual(label(minutes: 361), "Session", "the caller already calls the primary window a session")
        XCTAssertEqual(label(minutes: 1_439), "Session")
        XCTAssertEqual(label(minutes: 1_440), "Weekly")
    }

    /// Newer Codex builds answer with an array instead of named windows.
    func testCodexParseFallsBackToTheLimitsArray() throws {
        let reply = try XCTUnwrap(CodexProbe.jsonObject("""
        {"id":2,"result":{"rateLimits":{"planType":"enterprise","limits":[\
        {"usedPercent":-5,"resetsAt":2000000000,"windowDurationMins":300},\
        {"usedPercent":64,"window_duration_mins":720},\
        {"usedPercent":91,"windowDurationMins":10080}]}}}
        """))
        let snapshot = CodexProbe.parse(try XCTUnwrap(reply["result"] as? [String: Any]))
        XCTAssertEqual(snapshot.plan, "enterprise")
        XCTAssertEqual(snapshot.windows.map(\.label), ["Session", "Window 2", "Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 64, 91], "a negative percent is clamped, not shown")
        XCTAssertEqual(snapshot.windows[0].resetAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(snapshot.error)
    }

    /// Named windows win: an array carried alongside them is not a second copy
    /// of the same quota.
    func testCodexParseIgnoresTheLimitsArrayWhenNamedWindowsExist() throws {
        let reply = try XCTUnwrap(CodexProbe.jsonObject("""
        {"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":300},\
        "limits":[{"usedPercent":99,"windowDurationMins":300}]}}
        """))
        XCTAssertEqual(CodexProbe.parse(reply).windows.map(\.usedPercent), [30])
    }

    /// Anything that is not a window object is skipped rather than counted, and
    /// a reply holding none of them says so instead of reporting 0%.
    func testCodexParseReportsNoActiveWindowsRatherThanInventingThem() throws {
        for json in [#"{"rateLimits":{"planType":"plus"}}"#,
                     #"{"rateLimits":{"primary":"soon","secondary":[1,2]}}"#,
                     #"{"rateLimits":{"limits":"soon"}}"#,
                     #"{"rateLimits":{"limits":[]}}"#,
                     "{}"] {
            let snapshot = CodexProbe.parse(try XCTUnwrap(CodexProbe.jsonObject(json)))
            XCTAssertTrue(snapshot.windows.isEmpty, "\(json) holds no quota window")
            XCTAssertEqual(snapshot.error, "No active quota windows")
            XCTAssertEqual(snapshot.provider, .codex)
        }
    }

    // MARK: - Helpers

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func geminiParseFailure(_ raw: String) -> String? {
        failureMessage { try GeminiTerminalProbe.parse(raw, now: Date()) }
    }

    private func claudeParseFailure(_ output: String) -> String? {
        failureMessage { try ClaudePrintProbe.parse(output, now: Date()) }
    }

    private func failureMessage(_ body: () throws -> QuotaSnapshot) -> String? {
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

/// A command failure that is not a `ProbeError`, which is how anything below
/// `CommandRunner` — a pipe, a decoder — would surface.
private struct BrokenPipeError: Error {}

/// The smallest `ProbeRunner` these tests need: a binary lookup and one scripted
/// `run` result. Nothing here starts a process.
private final class StubProbeRunner: ProbeRunner, @unchecked Sendable {
    private let executables: [String: String]
    private let runResult: Result<Data, Error>

    init(executables: [String: String], runResult: Result<Data, Error>) {
        self.executables = executables
        self.runResult = runResult
    }

    func find(_ executable: String) -> String? { executables[executable] }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, currentDirectory: URL?) throws -> Data {
        try runResult.get()
    }

    func runExpect(_ script: String, timeout: TimeInterval, currentDirectory: URL?) throws -> String {
        throw ProbeError.message("no scripted expect run")
    }

    func lineSession(executable: String, arguments: [String], currentDirectory: URL?) throws -> any LineSession {
        throw ProbeError.message("no scripted session")
    }
}
