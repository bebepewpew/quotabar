import XCTest
import Foundation
import AppKit
@testable import QuotaBar

final class QuotaBarTests: XCTestCase {
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
        XCTAssertFalse(script.localizedCaseInsensitiveContains("waiting for authentication"))
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

    @MainActor func testBadgesAndUrgencyThresholds() {
        XCTAssertEqual(QuotaStore.preferredBadge(for: .init(provider: .codex, windowLabel: "Session")), "S")
        XCTAssertEqual(QuotaStore.preferredBadge(for: .init(provider: .gemini, windowKey: "gemini-2.5-flash-lite", windowLabel: "2.5 Flash Lite")), "L")
        let provider = NSColor.blue
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 79.9, provider: provider), provider)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 80, provider: provider), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 94.9, provider: provider), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 95, provider: provider), .systemRed)
    }
}
