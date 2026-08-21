import XCTest
import Foundation
import Dispatch
@testable import QuotaCore

/// Path resolution, round-trips, the merge-under-lock write path and the
/// tolerance the CLI depends on when the state file is unusable.
final class StateStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-state-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - defaultURL

    /// The two conventions are selected at runtime, so each one is checked here on
    /// whichever platform happens to run the suite. `home` and the environment are
    /// both injected: no test may depend on the machine's real configuration.
    func testXDGConfigHomeDecidesTheStateFileLocation() {
        XCTAssertEqual(resolved(base: .xdg, environment: ["XDG_CONFIG_HOME": "/xdg"]).path,
                       "/xdg/quotabar/state.json")
    }

    func testXDGFallsBackToDotConfigWhenTheVariableIsMissingOrEmpty() {
        XCTAssertEqual(resolved(base: .xdg, environment: [:]).path,
                       "/home/tester/.config/quotabar/state.json")
        XCTAssertEqual(resolved(base: .xdg, environment: ["XDG_CONFIG_HOME": ""]).path,
                       "/home/tester/.config/quotabar/state.json",
                       "an empty variable is as good as unset")
    }

    /// A Windows front-end must land under `%APPDATA%` rather than inheriting the
    /// XDG rule. The injected value is POSIX-shaped so the assertion holds on the
    /// host actually running the suite.
    func testWindowsUsesAppDataWhenItIsSet() {
        XCTAssertEqual(resolved(base: .windowsAppData, environment: ["APPDATA": "/appdata"]).path,
                       "/appdata/quotabar/state.json")
    }

    func testWindowsFallsBackToRoamingAppDataUnderHome() {
        XCTAssertEqual(resolved(base: .windowsAppData, environment: [:]).path,
                       "/home/tester/AppData/Roaming/quotabar/state.json")
        XCTAssertEqual(resolved(base: .windowsAppData, environment: ["APPDATA": ""]).path,
                       "/home/tester/AppData/Roaming/quotabar/state.json")
    }

    /// The convention this build follows, and the no-argument overload that reads
    /// the real process environment.
    func testPlatformDefaultURLEndsInQuotabarStateJSON() {
        #if os(Windows)
        XCTAssertEqual(JSONFileStateStore.platformBase, .windowsAppData)
        #else
        XCTAssertEqual(JSONFileStateStore.platformBase, .xdg)
        #endif

        let url = JSONFileStateStore.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "state.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "quotabar")
    }

    /// Constructing without a URL only reads; it must not fail even when the
    /// default location holds nothing.
    func testStoreWithoutAnExplicitURLReadsTheDefaultLocation() {
        let store = JSONFileStateStore()
        XCTAssertNil(store.data(forKey: "quotabar.tests.absent.\(UUID().uuidString)"))
    }

    func testFactoryProducesThisPlatformsStore() {
        let store = StateStoreFactory.makeDefault()
        #if os(macOS)
        XCTAssertTrue(store is UserDefaultsStateStore)
        #else
        XCTAssertTrue(store is JSONFileStateStore)
        #endif
    }

    // MARK: - JSONFileStateStore round-trips

    func testDataAndIntegersRoundTripAcrossInstances() {
        let url = stateURL()
        let writer = JSONFileStateStore(url: url)
        writer.setData(Data("cached snapshot".utf8), forKey: "snapshot")
        writer.setInteger(45, forKey: "interval")
        writer.setInteger(-1, forKey: "negative")
        writer.setInteger(0, forKey: "zero")

        let reader = JSONFileStateStore(url: url)
        XCTAssertEqual(reader.data(forKey: "snapshot"), Data("cached snapshot".utf8))
        XCTAssertEqual(reader.integer(forKey: "interval"), 45)
        XCTAssertEqual(reader.integer(forKey: "negative"), -1)
        XCTAssertEqual(reader.integer(forKey: "zero"), 0, "0 is a value, not an absent key")
        XCTAssertNil(reader.data(forKey: "absent"))
        XCTAssertNil(reader.integer(forKey: "absent"))
    }

    /// `Data` is base64-encoded so the file stays valid JSON, and arbitrary bytes
    /// have to survive that encoding.
    func testArbitraryBytesSurviveTheBase64Encoding() throws {
        let url = stateURL()
        let payload = Data((0...255).map { UInt8($0) })
        JSONFileStateStore(url: url).setData(payload, forKey: "blob")

        XCTAssertEqual(JSONFileStateStore(url: url).data(forKey: "blob"), payload)

        // The file has to stay valid JSON, with the bytes carried as base64.
        let written = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        let encoded = try XCTUnwrap(object?["blob"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), payload)
    }

    /// The containing directory is created on demand — the CLI's first run has no
    /// `~/.config/quotabar` yet.
    func testWritingCreatesTheContainingDirectory() {
        let url = directory.appendingPathComponent("fresh", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("state.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        JSONFileStateStore(url: url).setInteger(30, forKey: "interval")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(JSONFileStateStore(url: url).integer(forKey: "interval"), 30)
    }

    /// The two value shapes never bleed into each other: reading a key with the
    /// wrong accessor reports absence rather than a coerced value.
    func testReadingAKeyWithTheWrongTypeReturnsNil() {
        let url = stateURL()
        let store = JSONFileStateStore(url: url)
        store.setData(Data("bytes".utf8), forKey: "blob")
        store.setInteger(7, forKey: "number")

        XCTAssertNil(store.integer(forKey: "blob"))
        XCTAssertNil(store.data(forKey: "number"))

        let reader = JSONFileStateStore(url: url)
        XCTAssertNil(reader.integer(forKey: "blob"))
        XCTAssertNil(reader.data(forKey: "number"))
    }

    func testWritingNilRemovesTheKeyFromTheFile() {
        let url = stateURL()
        let store = JSONFileStateStore(url: url)
        store.setData(Data("bytes".utf8), forKey: "blob")
        store.setInteger(7, forKey: "number")

        store.setData(nil, forKey: "blob")
        store.setInteger(nil, forKey: "number")
        XCTAssertNil(store.data(forKey: "blob"))
        XCTAssertNil(store.integer(forKey: "number"))

        let reader = JSONFileStateStore(url: url)
        XCTAssertNil(reader.data(forKey: "blob"))
        XCTAssertNil(reader.integer(forKey: "number"))
    }

    // MARK: - Merge under lock

    /// A `--watch` process and a one-shot run share this file. A write re-reads it
    /// under the lock and applies only the keys this instance changed, so the
    /// long-lived process cannot push its start-of-process snapshot over the
    /// other's keys — in particular the notification dedup map.
    func testWritingMergesRatherThanReplacingAnotherWritersKeys() {
        let url = stateURL()
        let watcher = JSONFileStateStore(url: url)
        watcher.setInteger(1, forKey: "watcher")

        let oneShot = JSONFileStateStore(url: url)
        oneShot.setData(Data("dedup".utf8), forKey: AlertEvaluator.deliveredKey)

        watcher.setInteger(2, forKey: "watcher")

        let fresh = JSONFileStateStore(url: url)
        XCTAssertEqual(fresh.integer(forKey: "watcher"), 2)
        XCTAssertEqual(fresh.data(forKey: AlertEvaluator.deliveredKey), Data("dedup".utf8))
        // The writer adopts the keys it merged, so its own later reads are current.
        XCTAssertEqual(watcher.data(forKey: AlertEvaluator.deliveredKey), Data("dedup".utf8))
    }

    func testConcurrentWritersKeepEveryKey() {
        let url = stateURL()
        let stores = (0..<8).map { _ in JSONFileStateStore(url: url) }
        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            stores[index].setInteger(index, forKey: "writer-\(index)")
        }

        let fresh = JSONFileStateStore(url: url)
        for index in 0..<stores.count {
            XCTAssertEqual(fresh.integer(forKey: "writer-\(index)"), index)
        }
    }

    // MARK: - Damaged and unusable files

    func testCorruptStateFileIsIgnoredAndOverwrittenOnTheNextWrite() throws {
        let url = stateURL()
        try Data("this is not JSON at all".utf8).write(to: url)

        let store = JSONFileStateStore(url: url)
        XCTAssertNil(store.integer(forKey: "interval"))

        store.setInteger(15, forKey: "interval")
        XCTAssertEqual(JSONFileStateStore(url: url).integer(forKey: "interval"), 15)
    }

    func testTruncatedStateFileIsIgnored() throws {
        let url = stateURL()
        try Data(#"{"interval":15,"snapshot":"Y2FjaGVk"#.utf8).write(to: url)

        let store = JSONFileStateStore(url: url)
        XCTAssertNil(store.integer(forKey: "interval"))
        XCTAssertNil(store.data(forKey: "snapshot"))
    }

    /// A value shape this build has no accessor for reads as absent — but the
    /// file is still a state file, and the keys it can read are unaffected.
    func testAValueThisBuildCannotInterpretReadsAsAbsent() throws {
        let url = stateURL()
        try Data(#"{"interval":{"nested":true},"flag":true,"nothing":null,"fraction":1.5,"snapshot":"Y2FjaGVk"}"#.utf8)
            .write(to: url)

        let store = JSONFileStateStore(url: url)
        for key in ["interval", "flag", "nothing", "fraction"] {
            XCTAssertNil(store.integer(forKey: key), "\(key) is not an integer this build wrote")
            XCTAssertNil(store.data(forKey: key), "\(key) is not data this build wrote")
        }
        XCTAssertEqual(store.data(forKey: "snapshot"), Data("cached".utf8),
                       "one unreadable value must not cost the readable keys")
    }

    /// The acceptance case: one key this build cannot decode must not take the
    /// rest of the file with it on the next write. Settings, cached snapshots and
    /// the dedup map all live here, and losing the last of those re-delivers
    /// alerts the user has already seen.
    func testAKeyThisBuildCannotDecodeKeepsItsSiblingsAcrossAWrite() throws {
        let url = stateURL()
        let snapshot = Data("cached snapshot".utf8).base64EncodedString()
        try Data(#"{"QuotaBar.futureFlag":true,"QuotaBar.cachedSnapshots.v1":"\#(snapshot)"}"#.utf8)
            .write(to: url)

        JSONFileStateStore(url: url).setInteger(30, forKey: "QuotaBar.refreshIntervalMinutes")

        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.contains(#""QuotaBar.futureFlag":true"#),
                      "a value written by a newer build survives verbatim, not as 1 and not at all: \(text)")
        XCTAssertTrue(text.contains(#""QuotaBar.cachedSnapshots.v1":"\#(snapshot)""#),
                      "the sibling key is byte for byte what it was: \(text)")

        let reader = JSONFileStateStore(url: url)
        XCTAssertEqual(reader.data(forKey: "QuotaBar.cachedSnapshots.v1"), Data("cached snapshot".utf8))
        XCTAssertEqual(reader.integer(forKey: "QuotaBar.refreshIntervalMinutes"), 30)
        XCTAssertNil(reader.integer(forKey: "QuotaBar.futureFlag"), "a bool is still not an integer")
        XCTAssertNil(reader.data(forKey: "QuotaBar.futureFlag"))
    }

    /// Every JSON shape round-trips, so the rule holds whatever a newer build
    /// chose to store — including inside arrays and nested objects.
    func testEveryJSONShapeSurvivesAWriteUnchanged() throws {
        let url = stateURL()
        let shapes = [#""flag":true"#, #""off":false"#, #""nothing":null"#, #""fraction":1.5"#,
                      #""text":"plain""#, #""list":[1,"two",false,null,{"deep":[]}]"#,
                      #""nested":{"a":{"b":[1.25]}}"#]
        try Data("{\(shapes.joined(separator: ","))}".utf8).write(to: url)

        JSONFileStateStore(url: url).setData(Data("bytes".utf8), forKey: "snapshot")

        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for shape in shapes {
            XCTAssertTrue(text.contains(shape), "\(shape) did not survive the write: \(text)")
        }
        XCTAssertEqual(JSONFileStateStore(url: url).data(forKey: "snapshot"), Data("bytes".utf8))
    }

    /// Bytes that are not a JSON object at all carry nothing to preserve, but they
    /// must not empty out what this process is already holding: adopting an
    /// unreadable file as `[:]` would drop the dedup map and re-alert.
    func testAFileThatIsNotAJSONObjectKeepsTheKeysThisProcessHolds() throws {
        let url = stateURL()
        let dedup = Data("delivered".utf8)
        JSONFileStateStore(url: url).setData(dedup, forKey: AlertEvaluator.deliveredKey)

        let store = JSONFileStateStore(url: url)
        XCTAssertEqual(store.data(forKey: AlertEvaluator.deliveredKey), dedup)

        try Data("[1,2,3]".utf8).write(to: url)
        store.setInteger(30, forKey: "interval")

        XCTAssertEqual(store.data(forKey: AlertEvaluator.deliveredKey), dedup,
                       "an unreadable file must not cost this process its dedup map")
        XCTAssertEqual(JSONFileStateStore(url: url).data(forKey: AlertEvaluator.deliveredKey), dedup,
                       "and the write puts it back on disk")
    }

    /// Persistence is best effort: a state file that cannot be created costs a
    /// cached snapshot, never a refresh. Callers keep working in memory.
    func testAnUnwritableLocationIsToleratedAndKeepsValuesInMemory() throws {
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let url = blocker.appendingPathComponent("state.json")

        let store = JSONFileStateStore(url: url)
        store.setData(Data("cached".utf8), forKey: "snapshot")
        store.setInteger(30, forKey: "interval")

        XCTAssertEqual(store.data(forKey: "snapshot"), Data("cached".utf8))
        XCTAssertEqual(store.integer(forKey: "interval"), 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - UserDefaultsStateStore

    func testUserDefaultsStoreRoundTripsInAScratchSuite() throws {
        let suiteName = "quotabar.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsStateStore(defaults: defaults)

        XCTAssertNil(store.data(forKey: "snapshot"))
        XCTAssertNil(store.integer(forKey: "interval"))

        store.setData(Data("cached snapshot".utf8), forKey: "snapshot")
        store.setInteger(45, forKey: "interval")
        XCTAssertEqual(store.data(forKey: "snapshot"), Data("cached snapshot".utf8))
        XCTAssertEqual(store.integer(forKey: "interval"), 45)

        store.setInteger(0, forKey: "interval")
        XCTAssertEqual(store.integer(forKey: "interval"), 0, "0 is a value, not an absent key")

        store.setData(nil, forKey: "snapshot")
        store.setInteger(nil, forKey: "interval")
        XCTAssertNil(store.data(forKey: "snapshot"))
        XCTAssertNil(store.integer(forKey: "interval"))
    }

    /// The default initializer targets the shared domain. Reading an absent key is
    /// the only thing safe to assert on it — writing would touch real settings.
    func testUserDefaultsStoreDefaultsToTheStandardDomain() {
        XCTAssertNil(UserDefaultsStateStore().data(forKey: "quotabar.tests.absent.\(UUID().uuidString)"))
    }

    // MARK: - Fixtures

    /// A fresh state file per call, in a directory that already exists so a test
    /// can seed the file itself.
    private func stateURL() -> URL {
        let container = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container.appendingPathComponent("state.json")
    }

    private func resolved(base: JSONFileStateStore.ConfigurationBase,
                          environment: [String: String]) -> URL {
        JSONFileStateStore.defaultURL(environment: environment,
                                      home: URL(fileURLWithPath: "/home/tester", isDirectory: true),
                                      base: base)
    }
}
