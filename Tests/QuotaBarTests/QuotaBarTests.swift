import XCTest
import AppKit
@testable import QuotaBar
import QuotaCore

/// Everything platform-independent now lives in `QuotaCoreTests`. What remains
/// here is the AppKit menu-bar rendering that only exists on macOS.
final class QuotaBarTests: XCTestCase {
    @MainActor func testMenuBarProgressColourFollowsUrgencyThresholds() {
        let provider = NSColor.blue
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 79.9, provider: provider), provider)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 80, provider: provider), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 94.9, provider: provider), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.progressColor(used: 95, provider: provider), .systemRed)
    }
}

/// What the app asks the history file for after a refresh. The store is a stub,
/// so the span itself is the assertion: it used to be `.distantPast` to
/// `.distantFuture`, which contradicted `recentUsage`'s promise never to hold
/// three months of samples.
final class QuotaStoreHistoryReadTests: XCTestCase {
    @MainActor func testAReloadReadsOnlyTheSpanItRenders() async throws {
        let history = RecordingHistoryStore()
        let subject = QuotaStore(store: MemoryStateStore(), history: history)

        await subject.reloadHistory(recording: [])

        XCTAssertEqual(history.reads.count, 1)
        let range = try XCTUnwrap(history.reads.first)
        XCTAssertEqual(range.from, range.to.addingTimeInterval(-Advisor.adviceLookback))
        // At least the week the sparklines draw, and never the whole file.
        XCTAssertLessThanOrEqual(range.from, range.to.addingTimeInterval(-QuotaStore.sparklineSpan))
        XCTAssertGreaterThan(range.from, .distantPast)
        XCTAssertLessThan(range.to, .distantFuture)
    }

    // MARK: - Stubs

    private final class RecordingHistoryStore: HistoryStore, @unchecked Sendable {
        private(set) var reads: [(from: Date, to: Date)] = []

        func append(_ samples: [UsageSample]) -> Int { samples.count }

        func read(from: Date, to: Date) -> HistoryReadResult {
            reads.append((from: from, to: to))
            return HistoryReadResult()
        }

        func heads() -> [HistorySeriesID: UsageSample] { [:] }
        func compact(now: Date, horizon: TimeInterval) -> Int { 0 }
        func needsCompaction(now: Date, horizon: TimeInterval) -> Bool { false }
        func removeAll() {}
    }

    /// Keeps the test off the real `UserDefaults`.
    private final class MemoryStateStore: StateStore, @unchecked Sendable {
        private var values: [String: Data] = [:]
        private var numbers: [String: Int] = [:]

        func data(forKey key: String) -> Data? { values[key] }
        func setData(_ data: Data?, forKey key: String) { values[key] = data }
        func integer(forKey key: String) -> Int? { numbers[key] }
        func setInteger(_ value: Int?, forKey key: String) { numbers[key] = value }
    }
}
