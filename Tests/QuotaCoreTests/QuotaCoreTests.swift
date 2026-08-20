import XCTest
import Foundation
@testable import QuotaCore

final class QuotaCoreTests: XCTestCase {
    func testParsesCodexWindows() {
        let result: [String: Any] = ["rateLimits": [
            "planType": "plus",
            "primary": ["usedPercent": NSNumber(value: 23), "resetsAt": NSNumber(value: 2_000_000_000)],
            "secondary": ["usedPercent": NSNumber(value: 71), "resetsAt": NSNumber(value: 2_000_100_000)]
        ]]
        let value = CodexProbe.parse(result)
        XCTAssertEqual(value.plan, "plus")
        XCTAssertEqual(value.windows.count, 2)
        XCTAssertEqual(value.windows[0].usedPercent, 23)
    }

    /// swift-corelibs-foundation hands back plain `Int`/`Double` rather than
    /// `NSNumber`, which used to collapse every Codex quota to 0% on Linux.
    func testParsesCodexWindowsFromUnbridgedJSONNumbers() {
        let result: [String: Any] = ["rateLimits": [
            "planType": "pro",
            "primary": ["usedPercent": 42.5, "resetsAt": 2_000_000_000, "windowDurationMins": 300],
            "secondary": ["usedPercent": 88, "resetsAt": Double(2_000_100_000), "windowDurationMins": 10_080]
        ]]
        let value = CodexProbe.parse(result)
        XCTAssertEqual(value.plan, "pro")
        XCTAssertEqual(value.windows.map(\.usedPercent), [42.5, 88])
        XCTAssertEqual(value.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(value.windows[0].resetAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testParsesClaudeResetDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12)))
        let reset = try XCTUnwrap(ClaudePrintProbe.parseReset("Aug 22 at 2am", timeZoneName: "Europe/Warsaw", now: now))
        XCTAssertEqual(calendar.component(.day, from: reset), 22)
        XCTAssertEqual(calendar.component(.hour, from: reset), 2)
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

    func testGeminiProbeUsesFullStatsAndBoundedTerminal() {
        let script = GeminiTerminalProbe.expectScript(binary: "/tmp/gemini")
        XCTAssertTrue(script.contains("/stats\\r"))
        XCTAssertFalse(script.contains("/stats model"))
        XCTAssertTrue(script.contains("rows 40 columns 160"))
        XCTAssertTrue(script.contains("--screen-reader"))
        XCTAssertTrue(script.contains("wait -nowait"))
        XCTAssertFalse(script.containsCaseInsensitive("waiting for authentication"))
        XCTAssertTrue(script.contains("[>❯])[ \t]+"))
        XCTAssertTrue(script.contains("set timeout 12"))
        XCTAssertTrue(script.contains("set timeout 15"))
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
