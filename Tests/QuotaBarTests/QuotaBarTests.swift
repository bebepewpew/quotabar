import XCTest
import AppKit
@testable import QuotaBar
import QuotaCore

/// Everything platform-independent now lives in `QuotaCoreTests`. What remains
/// here is the AppKit menu-bar rendering that only exists on macOS, and the
/// menu-bar store that owns the persisted selection.
final class QuotaBarTests: XCTestCase {
    @MainActor func testMenuBarProgressColourFollowsUrgencyThresholds() {
        let provider = NSColor.blue
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 79.9, provider: provider), provider)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 80, provider: provider), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 94.9, provider: provider), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 95, provider: provider), .systemRed)
    }

    /// Two Gemini windows the shipped parser can produce from one `/stats` view
    /// share the label `Flash` and differ only by key.
    private static let sharedLabelSnapshot = QuotaSnapshot(provider: .gemini, windows: [
        QuotaWindow(key: "flash", label: "Flash", usedPercent: 12, resetAt: nil),
        QuotaWindow(key: "gemini-flash", label: "Flash", usedPercent: 88, resetAt: nil)
    ])

    @MainActor func testMenuBarIndicatorsBindEachSharedLabelWindowToItsOwnReading() throws {
        let state = MemoryStateStore()
        try state.saveSelections([
            QuotaSelection(provider: .gemini, windowKey: "flash", windowLabel: "Flash"),
            QuotaSelection(provider: .gemini, windowKey: "gemini-flash", windowLabel: "Flash")
        ])

        let store = QuotaStore(store: state)
        store.snapshots = [Self.sharedLabelSnapshot]

        let readings: [Double?] = store.menuBarIndicators.map(\.usedPercent)
        XCTAssertEqual(readings, [12, 88], "each window of a shared label drives its own indicator")
    }

    /// The migration is persisted by `menuBarSelections.didSet`, so a rewrite onto
    /// the wrong window would survive the render that produced it.
    @MainActor func testMigrationRewritesASavedSelectionOnlyWhenTheKeyMatches() throws {
        let state = MemoryStateStore()
        try state.saveSelections([QuotaSelection(provider: .gemini, windowKey: "gemini-flash", windowLabel: "Flash")])

        let store = QuotaStore(store: state)
        store.snapshots = [Self.sharedLabelSnapshot]
        store.migrateMenuBarSelections()

        XCTAssertEqual(store.menuBarSelections.map(\.windowKey), ["gemini-flash"])
        XCTAssertEqual(try state.loadSelections().map(\.windowKey), ["gemini-flash"],
                       "the persisted selection must keep pointing at the key the user chose")
    }

    @MainActor func testMigrationLeavesASelectionTheProviderStoppedReporting() throws {
        let state = MemoryStateStore()
        try state.saveSelections([QuotaSelection(provider: .gemini, windowKey: "gemini-flash", windowLabel: "Flash")])

        let store = QuotaStore(store: state)
        // Only the other `Flash` window is being reported now.
        store.snapshots = [QuotaSnapshot(provider: .gemini, windows: [
            QuotaWindow(key: "flash", label: "Flash", usedPercent: 12, resetAt: nil)
        ])]
        store.migrateMenuBarSelections()

        XCTAssertEqual(store.menuBarSelections.map(\.windowKey), ["gemini-flash"])
        XCTAssertEqual(try state.loadSelections().map(\.windowKey), ["gemini-flash"])
        XCTAssertEqual(store.menuBarIndicators.count, 1)
        XCTAssertNil(store.menuBarIndicators[0].usedPercent, "an absent window shows no reading, not another one's")
    }
}

// MARK: - Stubs

/// In-memory `StateStore` so the store's persistence runs without touching user
/// defaults.
private final class MemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var numbers: [String: Int] = [:]

    static let selectionsKey = "QuotaBar.menuBarSelections.v1"

    func data(forKey key: String) -> Data? { lock.withLock { blobs[key] } }
    func setData(_ value: Data?, forKey key: String) { lock.withLock { blobs[key] = value } }
    func integer(forKey key: String) -> Int? { lock.withLock { numbers[key] } }
    func setInteger(_ value: Int?, forKey key: String) { lock.withLock { numbers[key] = value } }

    func saveSelections(_ selections: [QuotaSelection]) throws {
        setData(try JSONEncoder().encode(selections), forKey: Self.selectionsKey)
    }

    func loadSelections() throws -> [QuotaSelection] {
        try JSONDecoder().decode([QuotaSelection].self, from: XCTUnwrap(data(forKey: Self.selectionsKey)))
    }
}
