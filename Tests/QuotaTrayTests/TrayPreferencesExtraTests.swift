import Foundation
import XCTest
@testable import QuotaTray
import QuotaCore

private struct EncodingFailure: Error {}

/// The branches `TrayPreferencesTests` leaves alone: the encode failure that
/// must not wipe what is already saved, clearing a saved list, and a payload
/// that is valid JSON of the wrong shape.
final class TrayPreferencesExtraTests: XCTestCase {
    private var directory: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-tray-preferences-extra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("state.json")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        stateURL = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> JSONFileStateStore { JSONFileStateStore(url: stateURL) }

    private func selection(_ label: String, provider: Provider = .codex) -> QuotaSelection {
        QuotaSelection(provider: provider, windowLabel: label)
    }

    /// `setSelections` refuses to write when encoding fails. `[QuotaSelection]`
    /// always encodes, so the guarantee is only observable through the encoding
    /// seam — and what it protects is the previously saved list.
    func testAPayloadThatCannotBeEncodedLeavesTheSavedSelectionsIntact() throws {
        let store = makeStore()
        TrayPreferences(store: store).setSelections([selection("Session")])
        let saved = try XCTUnwrap(store.data(forKey: TrayPreferences.storageKey))

        TrayPreferences(store: store, encode: { _ in throw EncodingFailure() })
            .setSelections([selection("Weekly", provider: .gemini)])

        XCTAssertEqual(store.data(forKey: TrayPreferences.storageKey), saved,
                       "a failed encode must not overwrite the stored value")
        XCTAssertEqual(TrayPreferences(store: makeStore()).selections.map(\.windowLabel), ["Session"],
                       "and the file on disk still holds the old selection")
    }

    /// Clearing is a write of an empty list, not a removal: the tray shows
    /// nothing and a later write puts a selection back.
    func testClearingWritesAnEmptyListAndCanBeSetAgain() throws {
        TrayPreferences(store: makeStore()).setSelections([selection("Session"),
                                                           selection("Weekly", provider: .claude)])
        TrayPreferences(store: makeStore()).setSelections([])

        let cleared = makeStore()
        XCTAssertEqual(TrayPreferences(store: cleared).selections, [])
        let data = try XCTUnwrap(cleared.data(forKey: TrayPreferences.storageKey),
                                 "clearing writes an empty list rather than dropping the key")
        XCTAssertEqual(try JSONDecoder().decode([QuotaSelection].self, from: data), [])

        TrayPreferences(store: makeStore()).setSelections([selection("Monthly")])
        XCTAssertEqual(TrayPreferences(store: makeStore()).selections.map(\.windowLabel), ["Monthly"])
    }

    /// Well-formed JSON of the wrong shape — a bare list of labels, the obvious
    /// thing an older or hand-edited state file could hold — reads as empty and
    /// is left on disk, so a build that does understand it still finds it.
    func testAWellFormedPayloadOfTheWrongShapeReadsAsEmptyAndIsNotDeleted() {
        let payload = Data(#"["Weekly","Session"]"#.utf8)
        let store = makeStore()
        store.setData(payload, forKey: TrayPreferences.storageKey)

        XCTAssertEqual(TrayPreferences(store: store).selections, [])
        XCTAssertEqual(store.data(forKey: TrayPreferences.storageKey), payload,
                       "reading must not rewrite a payload it could not decode")
        XCTAssertEqual(makeStore().data(forKey: TrayPreferences.storageKey), payload)
    }
}
