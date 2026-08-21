import XCTest
import Foundation
@testable import QuotaTray
import QuotaCore

final class TrayStateBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func selection(_ provider: Provider, _ key: String,
                           _ label: String) -> QuotaSelection {
        QuotaSelection(provider: provider, windowKey: key, windowLabel: label)
    }

    private func snapshot(_ provider: Provider, windows: [QuotaWindow],
                          error: String? = nil) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, windows: windows, error: error, updatedAt: now)
    }

    private func window(_ key: String, _ label: String, _ used: Double) -> QuotaWindow {
        QuotaWindow(key: key, label: label, usedPercent: used, resetAt: nil)
    }

    // MARK: Selections

    func testQuotasFollowTheOrderTheUserChose() {
        let quotas = TrayStateBuilder.menuBarQuotas(
            snapshots: [snapshot(.codex, windows: [window("w", "W", 10)]),
                        snapshot(.claude, windows: [window("w", "W", 20)])],
            selections: [selection(.claude, "w", "W"), selection(.codex, "w", "W")])
        XCTAssertEqual(quotas.map(\.selection.provider), [.claude, .codex])
        XCTAssertEqual(quotas.map(\.usedPercent), [20, 10])
    }

    /// A provider that failed must not silently reorder the icon by dropping out
    /// of it — the bar keeps its place with no reading.
    func testASelectionWithNoWindowKeepsItsPlaceWithoutAReading() {
        let quotas = TrayStateBuilder.menuBarQuotas(
            snapshots: [snapshot(.codex, windows: [], error: "not installed")],
            selections: [selection(.codex, "weekly", "Weekly")])
        XCTAssertEqual(quotas.count, 1)
        XCTAssertNil(quotas[0].usedPercent)
    }

    /// Windows are matched by key first, because the key is stable identity and
    /// the label is display text a vendor may reword.
    func testAWindowIsMatchedByKeyEvenWhenItsLabelChanged() {
        let quotas = TrayStateBuilder.menuBarQuotas(
            snapshots: [snapshot(.gemini, windows: [window("gemini-2.5-pro", "Renamed Tier", 55)])],
            selections: [selection(.gemini, "gemini-2.5-pro", "Old Name")])
        XCTAssertEqual(quotas[0].usedPercent, 55)
    }

    func testAWindowStillMatchesByLabelWhenTheKeyDoesNot() {
        let quotas = TrayStateBuilder.menuBarQuotas(
            snapshots: [snapshot(.codex, windows: [window("new-key", "Weekly", 30)])],
            selections: [selection(.codex, "old-key", "Weekly")])
        XCTAssertEqual(quotas[0].usedPercent, 30)
    }

    /// A key match must win outright, not per-window: matching `key || label`
    /// in one pass let a label collision on an earlier window beat the real key
    /// match on a later one.
    func testAKeyMatchWinsOverALabelCollisionOnAnEarlierWindow() {
        let quotas = TrayStateBuilder.menuBarQuotas(
            snapshots: [snapshot(.gemini, windows: [
                window("other-key", "Weekly", 10),      // label matches, key does not
                window("weekly", "Renamed", 90),        // the real key match
            ])],
            selections: [selection(.gemini, "weekly", "Weekly")])
        XCTAssertEqual(quotas[0].usedPercent, 90)
    }

    /// Nothing on Linux writes tray selections yet, so without a fallback the
    /// icon would draw the empty track forever and never reach NeedsAttention.
    func testWithNoStoredSelectionsTheIconStillShowsSomething() {
        let snapshots = [snapshot(.codex, windows: [window("a", "Weekly", 20)]),
                         snapshot(.claude, windows: [window("b", "Weekly", 95)])]
        let state = TrayStateBuilder.make(snapshots: snapshots, selections: [],
                                          revision: 1, now: now)
        XCTAssertFalse(state.quotas.isEmpty)
        // Busiest first, so the icon shows the one closest to running out.
        XCTAssertEqual(state.quotas.first?.usedPercent, 95)
        XCTAssertEqual(StatusNotifierItemProperties.status(for: state.quotas), "NeedsAttention")
    }

    func testAnExplicitSelectionStillWinsOverTheFallback() {
        let snapshots = [snapshot(.codex, windows: [window("a", "Weekly", 20)]),
                         snapshot(.claude, windows: [window("b", "Weekly", 95)])]
        let state = TrayStateBuilder.make(snapshots: snapshots,
                                          selections: [selection(.codex, "a", "Weekly")],
                                          revision: 1, now: now)
        XCTAssertEqual(state.quotas.count, 1)
        XCTAssertEqual(state.quotas[0].usedPercent, 20)
    }

    func testTheFallbackIsCappedTheWayTheMenuBarIs() {
        let many = (0..<10).map { window("k\($0)", "W\($0)", Double($0)) }
        let selections = TrayStateBuilder.defaultSelections(from: [snapshot(.codex, windows: many)])
        XCTAssertEqual(selections.count, TrayPreferences.maximumSelections)
    }

    /// `menuBarQuotas` itself takes the selections it is given; the fallback
    /// lives in `make`, so this still maps nothing to nothing.
    func testMenuBarQuotasMapsNoSelectionsToNoQuotas() {
        XCTAssertTrue(TrayStateBuilder.menuBarQuotas(
            snapshots: [snapshot(.codex, windows: [window("w", "W", 10)])],
            selections: []).isEmpty)
    }

    // MARK: Tooltip

    /// A tooltip with no text renders as a stray empty box.
    func testTheToolTipIsNeverEmpty() {
        let lines = TrayStateBuilder.toolTipLines(snapshots: [], now: now)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].isEmpty)
    }

    /// The tooltip is the place with room, so it lists every window rather than
    /// only the ones on the icon.
    func testTheToolTipListsEveryWindowNotOnlyTheSelectedOnes() {
        let lines = TrayStateBuilder.toolTipLines(
            snapshots: [snapshot(.codex, windows: [window("a", "Weekly", 10),
                                                   window("b", "Monthly", 20)])],
            now: now)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Weekly"))
        XCTAssertTrue(lines[1].contains("Monthly"))
    }

    func testTheToolTipCarriesAProvidersFailure() {
        let lines = TrayStateBuilder.toolTipLines(
            snapshots: [snapshot(.gemini, windows: [], error: "Gemini CLI is not installed")],
            now: now)
        XCTAssertTrue(lines.contains { $0.contains("not installed") }, "\(lines)")
    }

    // MARK: Revisions

    /// dbusmenu revisions must strictly increase, and 0 is reserved.
    func testRevisionsIncreaseAndWrapPastZero() {
        XCTAssertEqual(TrayStateBuilder.nextRevision(after: 1), 2)
        XCTAssertEqual(TrayStateBuilder.nextRevision(after: UInt32.max), 1)
        XCTAssertNotEqual(TrayStateBuilder.nextRevision(after: UInt32.max), 0)
    }

    // MARK: Whole state

    func testStateCarriesOneIconOfTheDeclaredSize() {
        let state = TrayStateBuilder.make(
            snapshots: [snapshot(.codex, windows: [window("w", "W", 40)])],
            selections: [selection(.codex, "w", "W")], revision: 3, now: now)
        XCTAssertEqual(state.bitmaps.count, 1)
        XCTAssertEqual(state.bitmaps[0].width, TrayStateBuilder.iconSize)
        XCTAssertEqual(state.bitmaps[0].height, TrayStateBuilder.iconSize)
        XCTAssertEqual(state.revision, 3)
    }

    func testStateProducesAMenuWithBothActions() {
        let state = TrayStateBuilder.make(
            snapshots: [snapshot(.codex, windows: [window("w", "W", 40)])],
            selections: [], revision: 1, now: now)
        XCTAssertEqual(Set(state.menu.actions.values),
                       [TrayMenu.refreshActionID, TrayMenu.quitActionID])
        XCTAssertTrue(state.menu.node.isWellFormed)
    }

    /// The whole point of the cold-start path: nothing to report still produces
    /// a drawable icon and a usable menu rather than an empty item.
    func testAnEmptyStateIsStillDrawableAndWellFormed() {
        let state = TrayStateBuilder.make(snapshots: [], selections: [], revision: 1, now: now)
        XCTAssertEqual(state.bitmaps.count, 1)
        XCTAssertFalse(state.toolTipLines.isEmpty)
        XCTAssertTrue(state.menu.node.isWellFormed)

        let properties = StatusNotifierService.itemProperties(state: state)
        XCTAssertEqual(properties["Status"], .string("Active"))
        XCTAssertTrue(properties["IconPixmap"]?.isWellFormed == true)
    }
}

final class TrayArgumentsTests: XCTestCase {
    /// Pinned to the literals `--help` promises, not to the constants
    /// themselves: asserting a value against its own constant passes however
    /// that constant drifts away from what the usage text says.
    func testTheDocumentedNumbersAreTheRealOnes() {
        XCTAssertEqual(TrayArguments.parse([]).interval, 900)
        XCTAssertEqual(TrayArguments.parse(["--interval", "1"]).interval, 30)
        XCTAssertEqual(TrayArguments.parse(["--interval", "999999999"]).interval, 86_400)
        for promised in ["900", "30", "86400"] {
            XCTAssertTrue(TrayArguments.usage.contains(promised),
                          "usage does not mention \(promised)")
        }
    }

    func testDefaultsAreTheDocumentedOnes() {
        let parsed = TrayArguments.parse([])
        XCTAssertEqual(parsed.interval, TrayArguments.defaultInterval)
        XCTAssertFalse(parsed.help)
        XCTAssertFalse(parsed.version)
        XCTAssertTrue(parsed.unknown.isEmpty)
    }

    func testIntervalIsRead() {
        XCTAssertEqual(TrayArguments.parse(["--interval", "120"]).interval, 120)
    }

    /// A tray probing every second is a fork bomb with a nice icon; one probing
    /// weekly is not a monitor.
    func testIntervalIsClampedRatherThanRejected() {
        XCTAssertEqual(TrayArguments.parse(["--interval", "1"]).interval,
                       TrayArguments.minimumInterval)
        XCTAssertEqual(TrayArguments.parse(["--interval", "999999999"]).interval,
                       TrayArguments.maximumInterval)
        XCTAssertTrue(TrayArguments.parse(["--interval", "1"]).unknown.isEmpty)
    }

    /// A mistyped value that silently becomes the default looks like the tray
    /// ignoring a setting.
    func testABadIntervalIsReportedNotSilentlyDefaulted() {
        let parsed = TrayArguments.parse(["--interval", "soon"])
        XCTAssertEqual(parsed.unknown.count, 1)
        XCTAssertTrue(parsed.unknown[0].contains("--interval"))
    }

    func testAMissingIntervalValueIsReported() {
        XCTAssertEqual(TrayArguments.parse(["--interval"]).unknown.count, 1)
    }

    func testANonFiniteIntervalIsRejected() {
        XCTAssertFalse(TrayArguments.parse(["--interval", "inf"]).unknown.isEmpty)
        XCTAssertFalse(TrayArguments.parse(["--interval", "nan"]).unknown.isEmpty)
    }

    func testHelpAndVersionAreRecognised() {
        XCTAssertTrue(TrayArguments.parse(["--help"]).help)
        XCTAssertTrue(TrayArguments.parse(["-h"]).help)
        XCTAssertTrue(TrayArguments.parse(["--version"]).version)
    }

    func testAnUnknownFlagIsCollected() {
        XCTAssertEqual(TrayArguments.parse(["--nonsense"]).unknown, ["--nonsense"])
    }

    func testFlagsCombine() {
        let parsed = TrayArguments.parse(["--interval", "60", "--help"])
        XCTAssertEqual(parsed.interval, 60)
        XCTAssertTrue(parsed.help)
    }

    func testTheAutostartFlagsAreRecognised() {
        XCTAssertTrue(TrayArguments.parse(["--install-autostart"]).installAutostart)
        XCTAssertTrue(TrayArguments.parse(["--remove-autostart"]).removeAutostart)
        XCTAssertFalse(TrayArguments.parse([]).installAutostart)
        XCTAssertFalse(TrayArguments.parse([]).removeAutostart)
        XCTAssertTrue(TrayArguments.parse(["--install-autostart"]).unknown.isEmpty)
    }

    func testUsageNamesEveryFlagItAccepts() {
        for flag in ["--interval", "--version", "--help",
                     "--install-autostart", "--remove-autostart"] {
            XCTAssertTrue(TrayArguments.usage.contains(flag), flag)
        }
    }
}
