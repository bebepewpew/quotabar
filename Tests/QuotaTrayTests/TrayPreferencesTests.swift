import XCTest
@testable import QuotaTray
import QuotaCore

/// Exercises the tray's own selection key against a real `JSONFileStateStore`
/// pointed at a temporary file, so the persisted payload — not just an in-memory
/// double — is what the assertions see.
final class TrayPreferencesTests: XCTestCase {
    /// The macOS menu bar's key. The tray must never write it.
    private static let macOSKey = "QuotaBar.menuBarSelections.v1"

    private var directory: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-tray-preferences-\(UUID().uuidString)", isDirectory: true)
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

    func testNoSavedPayloadReadsAsEmpty() {
        XCTAssertEqual(TrayPreferences(store: makeStore()).selections, [])
    }

    func testSelectionsRoundTripThroughTheStateFile() {
        let saved = [selection("Session"), selection("Weekly", provider: .claude)]
        TrayPreferences(store: makeStore()).setSelections(saved)

        // A fresh store and a fresh preferences object: this reads the file back,
        // not an in-memory copy.
        let reloaded = TrayPreferences(store: makeStore()).selections
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded.map(\.windowKey), ["session", "weekly"])
    }

    func testWritesAreCappedAtMaximumSelections() throws {
        let labels = ["Session", "Weekly", "Monthly", "Yearly"]
        XCTAssertGreaterThan(labels.count, TrayPreferences.maximumSelections)
        TrayPreferences(store: makeStore()).setSelections(labels.map { selection($0) })

        let reloaded = TrayPreferences(store: makeStore()).selections
        XCTAssertEqual(reloaded.count, TrayPreferences.maximumSelections)
        XCTAssertEqual(reloaded.map(\.windowLabel), ["Session", "Weekly", "Monthly"])

        // The cap is what was persisted, not just what was returned.
        let store = makeStore()
        let data = try XCTUnwrap(store.data(forKey: TrayPreferences.storageKey))
        XCTAssertEqual(try JSONDecoder().decode([QuotaSelection].self, from: data).count,
                       TrayPreferences.maximumSelections)
    }

    /// A longer list written by some other build is truncated on read rather than
    /// overflowing the tray.
    func testOverLongStoredListIsTruncatedOnRead() throws {
        let store = makeStore()
        let stored = ["Session", "Weekly", "Monthly", "Yearly", "Daily"].map { selection($0) }
        store.setData(try JSONEncoder().encode(stored), forKey: TrayPreferences.storageKey)

        let selections = TrayPreferences(store: store).selections
        XCTAssertEqual(selections.count, TrayPreferences.maximumSelections)
        XCTAssertEqual(selections.map(\.windowLabel), ["Session", "Weekly", "Monthly"])
    }

    func testMalformedPayloadsDecodeAsEmptyInsteadOfThrowing() throws {
        let payloads = [
            Data("not json at all".utf8),
            Data("{}".utf8),
            Data("[{\"provider\":\"Nope\",\"windowLabel\":\"Weekly\"}]".utf8),
            Data("[{\"windowLabel\":\"Weekly\"}]".utf8),
            Data()
        ]
        for payload in payloads {
            let store = makeStore()
            store.setData(payload, forKey: TrayPreferences.storageKey)
            XCTAssertEqual(TrayPreferences(store: store).selections, [],
                           "payload \(String(decoding: payload, as: UTF8.self)) should decode as empty")
        }
    }

    /// Old payloads without `windowKey` still decode, matching `QuotaSelection`'s
    /// backward-compatible decoding.
    func testLegacyPayloadWithoutWindowKeyStillDecodes() {
        let store = makeStore()
        store.setData(Data(#"[{"provider":"Codex","windowLabel":"Weekly"}]"#.utf8),
                      forKey: TrayPreferences.storageKey)
        XCTAssertEqual(TrayPreferences(store: store).selections.map(\.windowKey), ["weekly"])
    }

    func testMacOSMenuBarKeyIsNeverWritten() throws {
        let store = makeStore()
        let preferences = TrayPreferences(store: store)
        preferences.setSelections([selection("Session"), selection("Weekly")])
        preferences.setSelections([])

        XCTAssertNotEqual(TrayPreferences.storageKey, Self.macOSKey)
        XCTAssertNil(store.data(forKey: Self.macOSKey))
        XCTAssertNil(makeStore().data(forKey: Self.macOSKey))

        let raw = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(Self.macOSKey))
        XCTAssertTrue(raw.contains(TrayPreferences.storageKey))
    }

    /// A menu-bar selection saved by the macOS app survives tray writes untouched.
    func testExistingMacOSSelectionsSurviveTrayWrites() throws {
        let macOSPayload = try JSONEncoder().encode([selection("Weekly", provider: .gemini)])
        let seed = makeStore()
        seed.setData(macOSPayload, forKey: Self.macOSKey)

        TrayPreferences(store: makeStore()).setSelections([selection("Session")])

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.data(forKey: Self.macOSKey), macOSPayload)
        XCTAssertEqual(TrayPreferences(store: reloaded).selections.map(\.windowLabel), ["Session"])
    }
}
