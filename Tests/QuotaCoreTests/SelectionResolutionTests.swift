import XCTest
import Foundation
@testable import QuotaCore

/// Covers how a saved selection is resolved against a fresh probe result.
///
/// The window key is identity and the label is display data, and here the
/// consequence is persisted rather than cosmetic: the macOS store writes the
/// resolved selection back into `QuotaBar.menuBarSelections.v1`, so a selection
/// bound to the wrong window outlives the render that produced it.
final class SelectionResolutionTests: XCTestCase {

    /// A `/stats` view the shipped Gemini parser really accepts, in which two
    /// windows carry one label: the model-picker row `Flash` keys on its label,
    /// while the model-id row `gemini-flash` keys on the id and is *labelled*
    /// `Flash` as well.
    private func duplicateLabelSnapshot() throws -> QuotaSnapshot {
        try GeminiTerminalProbe.parse("""
        Model usage
        Flash ▬▬▬▬▬▬▬▬▬ 12% Resets: 10:05 AM (16h 18m)
        gemini-flash ▬▬▬ 88% Resets: 10:05 AM (16h 18m)
        (Press Esc to close)
        """, now: Date(timeIntervalSince1970: 1_000))
    }

    func testGeminiCanReportTwoWindowsUnderOneLabel() throws {
        let snapshot = try duplicateLabelSnapshot()
        XCTAssertEqual(snapshot.windows.map(\.label), ["Flash", "Flash"])
        XCTAssertEqual(snapshot.windows.map(\.key), ["flash", "gemini-flash"],
                       "the two rows must stay distinguishable by key")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12, 88])
    }

    func testWindowResolutionMatchesTheKeyAndNeverTheLabel() throws {
        let snapshots = [try duplicateLabelSnapshot()]
        let picker = QuotaSelection(provider: .gemini, windowKey: "flash", windowLabel: "Flash")
        let model = QuotaSelection(provider: .gemini, windowKey: "gemini-flash", windowLabel: "Flash")

        XCTAssertEqual(picker.window(in: snapshots)?.usedPercent, 12)
        XCTAssertEqual(model.window(in: snapshots)?.usedPercent, 88,
                       "each window of a shared label drives its own reading")

        // A key the provider is not reporting resolves to nothing, even though
        // its label matches both of the windows that are being reported.
        let absent = QuotaSelection(provider: .gemini, windowKey: "gemini-flash-lite", windowLabel: "Flash")
        XCTAssertNil(absent.window(in: snapshots))

        // Keys are unique per provider, not globally.
        XCTAssertNil(QuotaSelection(provider: .codex, windowKey: "flash", windowLabel: "Flash").window(in: snapshots))
        XCTAssertNil(picker.window(in: []))
    }

    func testRefreshingALabelKeepsTheKeyAndTakesTheCurrentLabel() {
        let snapshots = [QuotaSnapshot(provider: .gemini, windows: [
            QuotaWindow(key: "gemini-flash", label: "3 Flash", usedPercent: 40, resetAt: nil),
            QuotaWindow(key: "gemini-pro", label: "Pro", usedPercent: 5, resetAt: nil)
        ])]
        let saved = QuotaSelection(provider: .gemini, windowKey: "gemini-flash", windowLabel: "Flash")

        let refreshed = saved.refreshingLabel(in: snapshots)
        XCTAssertEqual(refreshed.windowKey, "gemini-flash")
        XCTAssertEqual(refreshed.windowLabel, "3 Flash", "a renamed window updates its display text")
        XCTAssertEqual(refreshed.id, saved.id)
    }

    func testRefreshingALabelLeavesASelectionTheProviderNoLongerReports() {
        // `Pro` is on offer under a different key. The saved choice must not be
        // repointed at it: the rewrite is persisted, so this would not be a
        // one-render slip.
        let snapshots = [QuotaSnapshot(provider: .gemini, windows: [
            QuotaWindow(key: "gemini-2-5-pro", label: "Pro", usedPercent: 77, resetAt: nil)
        ])]
        let saved = QuotaSelection(provider: .gemini, windowKey: "pro", windowLabel: "Pro")

        XCTAssertEqual(saved.refreshingLabel(in: snapshots), saved)
        XCTAssertNil(saved.window(in: snapshots))
        XCTAssertEqual(saved.refreshingLabel(in: []), saved, "a partial refresh must not rewrite a selection")
    }

    /// The compatibility case a label fallback used to stand in for: a payload
    /// written before selections carried a key resolves because the decoder
    /// derives the key from the label, not because matching falls back to it.
    func testASelectionSavedBeforeKeysExistedStillResolves() throws {
        let saved = try JSONDecoder().decode(QuotaSelection.self, from: Data("""
        {"provider":"Claude Code","windowLabel":"Weekly"}
        """.utf8))
        let snapshots = [QuotaSnapshot(provider: .claude, windows: [
            QuotaWindow(label: "Session", usedPercent: 10, resetAt: nil),
            QuotaWindow(label: "Weekly", usedPercent: 62, resetAt: nil)
        ])]

        XCTAssertEqual(saved.windowKey, "weekly")
        XCTAssertEqual(saved.window(in: snapshots)?.usedPercent, 62)
        XCTAssertEqual(saved.refreshingLabel(in: snapshots), saved)
    }
}
