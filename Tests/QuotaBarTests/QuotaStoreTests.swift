import XCTest
@testable import QuotaBar
import QuotaCore

/// The rules `QuotaStore` owns on its own: the three-selection cap, the badge
/// renumbering that keeps two same-provider windows apart, the key-only
/// resolution of saved selections, and the guard on the stored refresh interval.
///
/// Each case runs against a real `JSONFileStateStore` on a temporary file — the
/// seam `TrayPreferencesTests` already uses on the Linux side — so the assertions
/// see the persisted payload rather than an in-memory double. The storage keys
/// are spelled out as literals deliberately: they are a compatibility contract,
/// and a test that read them back from the implementation could not notice one
/// changing.
final class QuotaStoreTests: XCTestCase {
    private static let intervalKey = "QuotaBar.refreshIntervalMinutes"
    private static let menuBarKey = "QuotaBar.menuBarSelections.v1"

    private var directory: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-menu-bar-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("state.json")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        stateURL = nil
        try super.tearDownWithError()
    }

    /// A fresh view of the same state file. Reading through a new one is what
    /// proves a value reached the file instead of only the published property.
    private func makeStateStore() -> JSONFileStateStore { JSONFileStateStore(url: stateURL) }

    @MainActor private func makeQuotaStore() -> QuotaStore { QuotaStore(store: makeStateStore()) }

    private func selection(_ provider: Provider, _ label: String, key: String? = nil) -> QuotaSelection {
        QuotaSelection(provider: provider, windowKey: key, windowLabel: label)
    }

    private func window(_ label: String, key: String? = nil, used: Double) -> QuotaWindow {
        QuotaWindow(key: key, label: label, usedPercent: used, resetAt: nil)
    }

    // MARK: Stored refresh interval

    /// A value the picker never offers — a hand-edited file, or one written by a
    /// build that offered a different set — must not become the schedule.
    @MainActor func testStoredRefreshIntervalOutsideTheOfferedSetFallsBackToFifteen() {
        XCTAssertFalse(QuotaStore.refreshIntervals.contains(7))
        makeStateStore().setInteger(7, forKey: Self.intervalKey)
        XCTAssertEqual(makeQuotaStore().refreshIntervalMinutes, 15)
    }

    @MainActor func testAbsentOrNonsensicalStoredIntervalsFallBackToFifteen() {
        XCTAssertEqual(makeQuotaStore().refreshIntervalMinutes, 15, "no stored value")
        for stored in [-60, -1, 1, 14, 16, 59, 1_440] {
            makeStateStore().setInteger(stored, forKey: Self.intervalKey)
            XCTAssertEqual(makeQuotaStore().refreshIntervalMinutes, 15, "stored \(stored)")
        }
    }

    /// Zero is a real choice — refresh only on demand — so the guard must not
    /// mistake it for a missing value and overwrite it with the default.
    @MainActor func testEveryOfferedIntervalLoadsUnchanged() {
        XCTAssertEqual(QuotaStore.refreshIntervals, [0, 5, 15, 30, 60])
        for offered in QuotaStore.refreshIntervals {
            makeStateStore().setInteger(offered, forKey: Self.intervalKey)
            XCTAssertEqual(makeQuotaStore().refreshIntervalMinutes, offered, "stored \(offered)")
        }
    }

    @MainActor func testChangingTheIntervalIsPersistedUnderTheStableKey() {
        let store = makeQuotaStore()
        store.refreshIntervalMinutes = 30
        XCTAssertEqual(makeStateStore().integer(forKey: Self.intervalKey), 30)
        XCTAssertEqual(makeQuotaStore().refreshIntervalMinutes, 30)
    }

    // MARK: Menu-bar selection cap

    @MainActor func testAFourthSelectionIsRejectedAndTheFreedSlotIsReusable() {
        let store = makeQuotaStore()
        let picks = [selection(.codex, "Session"), selection(.claude, "Weekly"),
                     selection(.gemini, "Pro"), selection(.gemini, "Flash")]
        for pick in picks { store.setMenuBarSelection(pick, enabled: true) }

        XCTAssertEqual(store.menuBarSelections.count, 3)
        XCTAssertEqual(store.menuBarSelections, Array(picks.prefix(3)))
        XCTAssertFalse(store.menuBarSelections.contains(picks[3]))
        XCTAssertEqual(makeQuotaStore().menuBarSelections, Array(picks.prefix(3)))

        // The cap is a cap, not a lock: dropping one frees the slot again.
        store.setMenuBarSelection(picks[0], enabled: false)
        store.setMenuBarSelection(picks[3], enabled: true)
        XCTAssertEqual(store.menuBarSelections, [picks[1], picks[2], picks[3]])
        XCTAssertEqual(makeQuotaStore().menuBarSelections, [picks[1], picks[2], picks[3]])
    }

    @MainActor func testReAddingASelectionChangesNothingAndCostsNoSlot() {
        let store = makeQuotaStore()
        let first = selection(.codex, "Session")
        let second = selection(.claude, "Weekly")
        store.setMenuBarSelection(first, enabled: true)
        store.setMenuBarSelection(second, enabled: true)
        store.setMenuBarSelection(first, enabled: true)

        XCTAssertEqual(store.menuBarSelections, [first, second])

        let third = selection(.gemini, "Pro")
        store.setMenuBarSelection(third, enabled: true)
        XCTAssertEqual(store.menuBarSelections, [first, second, third])
    }

    @MainActor func testRemovingASelectionThatWasNeverAddedLeavesTheRestAlone() {
        let store = makeQuotaStore()
        let kept = selection(.codex, "Session")
        store.setMenuBarSelection(kept, enabled: true)
        store.setMenuBarSelection(selection(.gemini, "Flash"), enabled: false)
        XCTAssertEqual(store.menuBarSelections, [kept])
    }

    /// A payload holding more than the cap — an older build, another machine, a
    /// hand-edited file — is trimmed on load rather than rendered.
    @MainActor func testSavedSelectionsBeyondTheCapAreTrimmedOnLoad() throws {
        let saved = [selection(.codex, "Session"), selection(.codex, "Weekly"),
                     selection(.claude, "Session"), selection(.claude, "Weekly")]
        makeStateStore().setData(try JSONEncoder().encode(saved), forKey: Self.menuBarKey)
        XCTAssertEqual(makeQuotaStore().menuBarSelections, Array(saved.prefix(3)))
    }

    @MainActor func testDamagedSavedSelectionsLoadAsNoSelections() {
        makeStateStore().setData(Data("not a selection list".utf8), forKey: Self.menuBarKey)
        XCTAssertEqual(makeQuotaStore().menuBarSelections, [])
    }

    // MARK: Badge collisions

    @MainActor func testTwoWindowsOfOneProviderSharingABadgeAreNumbered() {
        let session = selection(.codex, "Session")
        let fiveHour = selection(.codex, "5h limit")
        XCTAssertEqual(QuotaBadge.preferred(for: session), "S")
        XCTAssertEqual(QuotaBadge.preferred(for: fiveHour), "S")

        let store = makeQuotaStore()
        store.snapshots = [QuotaSnapshot(provider: .codex,
                                         windows: [window("Session", used: 12), window("5h limit", used: 34)])]
        store.setMenuBarSelection(session, enabled: true)
        store.setMenuBarSelection(fiveHour, enabled: true)

        XCTAssertEqual(store.menuBarIndicators.map(\.badge), ["1", "2"])
        // Numbering must not merge the two rows: each keeps its own reading.
        XCTAssertEqual(store.menuBarIndicators.map(\.usedPercent), [12, 34] as [Double?])
    }

    @MainActor func testTheSameBadgeUnderTwoProvidersKeepsBothLetters() {
        let codex = selection(.codex, "Session")
        let claude = selection(.claude, "Session")
        XCTAssertEqual(QuotaBadge.preferred(for: codex), "S")
        XCTAssertEqual(QuotaBadge.preferred(for: claude), "S")

        let store = makeQuotaStore()
        store.setMenuBarSelection(codex, enabled: true)
        store.setMenuBarSelection(claude, enabled: true)

        // The provider symbol already separates these two, and a number would
        // only hide which window each one is.
        XCTAssertEqual(store.menuBarIndicators.map(\.badge), ["S", "S"])
    }

    @MainActor func testOnlyTheCollidingBadgesBecomeNumbers() {
        let weekly = selection(.claude, "Weekly")
        let session = selection(.codex, "Session")
        let fiveHour = selection(.codex, "5h limit")

        let store = makeQuotaStore()
        for pick in [weekly, session, fiveHour] { store.setMenuBarSelection(pick, enabled: true) }

        // The number is the position in the whole strip, not within the pair.
        XCTAssertEqual(store.menuBarIndicators.map(\.badge), ["W", "2", "3"])
    }

    /// The reading is matched on the window key alone. The label is display text
    /// two windows of one provider can share, so a fallback to it would bind a
    /// saved selection to a reading the user never chose.
    @MainActor func testIndicatorReadingsMatchOnTheWindowKeyAlone() {
        let store = makeQuotaStore()
        store.snapshots = [QuotaSnapshot(provider: .gemini,
                                         windows: [window("Pro", key: "gemini-pro", used: 41),
                                                   window("Flash", key: "gemini-flash", used: 8)])]
        let byKey = selection(.gemini, "A label nobody reports", key: "gemini-pro")
        let staleKey = selection(.gemini, "Flash", key: "a-stale-key")
        let absent = selection(.claude, "Session")
        for pick in [byKey, staleKey, absent] { store.setMenuBarSelection(pick, enabled: true) }

        XCTAssertEqual(store.menuBarIndicators.map(\.usedPercent), [41, nil, nil] as [Double?],
                       "a key nobody reports shows no reading, even when its label matches one")
    }

    /// The compatibility case a label fallback used to stand in for: a payload
    /// written before selections carried a key resolves because the decoder
    /// derives the key from the label on the way in, not because matching falls
    /// back to it.
    @MainActor func testASelectionSavedBeforeKeysExistedStillReadsItsWindow() {
        makeStateStore().setData(Data("""
        [{"provider":"Claude Code","windowLabel":"Weekly"}]
        """.utf8), forKey: Self.menuBarKey)

        let store = makeQuotaStore()
        store.snapshots = [QuotaSnapshot(provider: .claude,
                                         windows: [window("Session", used: 10),
                                                   window("Weekly", used: 62)])]

        XCTAssertEqual(store.menuBarSelections.map(\.windowKey), ["weekly"])
        XCTAssertEqual(store.menuBarIndicators.map(\.usedPercent), [62] as [Double?])
    }

    // MARK: Selection migration

    /// A selection whose key the provider has stopped reporting keeps that key,
    /// even when another window carries the label it was saved under. The
    /// migration is persisted by `menuBarSelections.didSet`, so re-pointing it at
    /// a window the user never chose would outlive the render that did it.
    @MainActor func testMigrationDoesNotRekeyASelectionOnAMatchingLabel() {
        let store = makeQuotaStore()
        let saved = selection(.gemini, "Pro", key: "gemini-2-5-pro")
        store.setMenuBarSelection(saved, enabled: true)
        store.snapshots = [QuotaSnapshot(provider: .gemini, windows: [window("Pro", key: "pro", used: 5)])]

        store.migrateMenuBarSelections()

        XCTAssertEqual(store.menuBarSelections, [saved])
        XCTAssertEqual(makeQuotaStore().menuBarSelections.map(\.windowKey), ["gemini-2-5-pro"])
        XCTAssertNil(store.menuBarIndicators[0].usedPercent,
                     "an absent window shows no reading, not the one that shares its label")
    }

    @MainActor func testMigrationAdoptsANewLabelForTheSameKey() {
        let store = makeQuotaStore()
        store.setMenuBarSelection(selection(.claude, "Weekly limit", key: "weekly"), enabled: true)
        store.snapshots = [QuotaSnapshot(provider: .claude,
                                         windows: [window("Weekly (all models)", key: "weekly", used: 60)])]

        store.migrateMenuBarSelections()

        XCTAssertEqual(store.menuBarSelections.map(\.windowKey), ["weekly"])
        XCTAssertEqual(store.menuBarSelections.map(\.windowLabel), ["Weekly (all models)"])
    }

    /// A provider missing from this refresh keeps its selection untouched, so a
    /// partial failure cannot quietly discard what the user picked.
    @MainActor func testMigrationKeepsASelectionWithNoMatchingWindow() {
        let store = makeQuotaStore()
        let saved = selection(.claude, "Weekly", key: "weekly-v2")
        store.setMenuBarSelection(saved, enabled: true)
        store.snapshots = [QuotaSnapshot(provider: .codex, windows: [window("Session", used: 3)])]

        store.migrateMenuBarSelections()

        XCTAssertEqual(store.menuBarSelections, [saved])
    }
}
