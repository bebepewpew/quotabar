import XCTest
import Foundation
@testable import QuotaCore

/// The record codec and the path resolver: the two halves of history that are
/// pure functions, so they are pinned to exact bytes and exact paths rather than
/// exercised through a file.
final class HistoryFormatTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let series = HistorySeriesID(provider: .codex, windowKey: "session")

    // MARK: - Header

    /// The header is a fixed 32 bytes; anything else and every record offset in
    /// every file ever written moves.
    func testHeaderIsExactlyThirtyTwoBytesAndStartsWithTheMagic() {
        let encoded = HistoryFormat.Header(epoch: epoch).encoded()
        XCTAssertEqual(encoded.count, HistoryFormat.headerLength)
        XCTAssertEqual(Array([UInt8](encoded)[0..<4]), Array("QBH1".utf8))
    }

    func testHeaderRoundTripsVersionStrideAndEpoch() throws {
        let original = HistoryFormat.Header(version: 1, stride: 12, epoch: epoch)
        let decoded = try XCTUnwrap(HistoryFormat.Header.decode(original.encoded()))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.epoch.timeIntervalSince1970, epoch.timeIntervalSince1970)
    }

    /// Truncated, empty and foreign files all have to be distinguishable from a
    /// header, because the store creates a file for the first two and refuses to
    /// touch the third.
    func testHeaderDecodingRejectsShortAndForeignBytes() {
        XCTAssertNil(HistoryFormat.Header.decode(Data()))
        XCTAssertNil(HistoryFormat.Header.decode(Data(repeating: 0, count: 31)))
        XCTAssertNil(HistoryFormat.Header.decode(Data(repeating: 0x41, count: 64)))

        var wrongMagic = [UInt8](HistoryFormat.Header(epoch: epoch).encoded())
        wrongMagic[3] = 0x39
        XCTAssertNil(HistoryFormat.Header.decode(Data(wrongMagic)))
    }

    /// A newer format or an unfamiliar stride is readable by nobody here, and the
    /// store keys "do not write to this file" off exactly this flag.
    func testOnlyTheCurrentVersionAndStrideAreSupported() {
        XCTAssertTrue(HistoryFormat.Header(version: 1, stride: 12, epoch: epoch).isSupported)
        XCTAssertFalse(HistoryFormat.Header(version: 2, stride: 12, epoch: epoch).isSupported)
        XCTAssertFalse(HistoryFormat.Header(version: 1, stride: 13, epoch: epoch).isSupported)
        XCTAssertFalse(HistoryFormat.Header(version: 1, stride: 0, epoch: epoch).isSupported)
    }

    // MARK: - Records

    func testRecordIsExactlyTwelveBytes() throws {
        let sample = UsageSample(series: series, at: epoch, usedPercent: 12.5, resetAt: nil)
        let encoded = try XCTUnwrap(HistoryFormat.encodeRecord(sample, hash: 7, epoch: epoch))
        XCTAssertEqual(encoded.count, HistoryFormat.recordStride)
    }

    func testRecordRoundTripsEveryField() throws {
        let at = epoch.addingTimeInterval(3_600)
        let sample = UsageSample(series: series, at: at, usedPercent: 41.5,
                                 resetAt: at.addingTimeInterval(90 * 60))
        let encoded = try XCTUnwrap(HistoryFormat.encodeRecord(sample, hash: 0xDEAD_BEEF, epoch: epoch))
        let raw = HistoryFormat.decodeRecord([UInt8](encoded), at: 0)

        XCTAssertEqual(raw.offsetSeconds, 3_600)
        XCTAssertEqual(raw.hash, 0xDEAD_BEEF)
        XCTAssertEqual(raw.centi, 4_150)
        XCTAssertEqual(raw.resetMinutes, 90)

        let restored = HistoryFormat.sample(from: raw, series: series, epoch: epoch)
        XCTAssertEqual(restored.at, at)
        XCTAssertEqual(restored.usedPercent, 41.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(restored.resetAt).timeIntervalSince1970,
                       at.addingTimeInterval(90 * 60).timeIntervalSince1970, accuracy: 0.5)
    }

    /// 0% and 100% are both real readings and sit at opposite ends of the
    /// two-byte range, so both are pinned.
    func testBoundaryPercentagesSurviveTheRoundTrip() throws {
        for percent in [0.0, 100.0] {
            let sample = UsageSample(series: series, at: epoch, usedPercent: percent, resetAt: nil)
            let encoded = try XCTUnwrap(HistoryFormat.encodeRecord(sample, hash: 1, epoch: epoch))
            let raw = HistoryFormat.decodeRecord([UInt8](encoded), at: 0)
            XCTAssertEqual(HistoryFormat.sample(from: raw, series: series, epoch: epoch).usedPercent, percent)
        }
    }

    /// A CLI reporting `1e9%` must not overflow the two bytes it is stored in.
    func testPercentagesAreClampedOnTheWayIn() throws {
        let high = UsageSample(series: series, at: epoch, usedPercent: 1e9, resetAt: nil)
        let low = UsageSample(series: series, at: epoch, usedPercent: -40, resetAt: nil)
        XCTAssertEqual(HistoryFormat.decodeRecord([UInt8](try XCTUnwrap(
            HistoryFormat.encodeRecord(high, hash: 1, epoch: epoch))), at: 0).centi, 10_000)
        XCTAssertEqual(HistoryFormat.decodeRecord([UInt8](try XCTUnwrap(
            HistoryFormat.encodeRecord(low, hash: 1, epoch: epoch))), at: 0).centi, 0)
    }

    /// And clamped on the way out too: the file is as untrusted as the CLI text
    /// it came from, because another process may have written it.
    func testPercentagesAreClampedOnTheWayOut() {
        let raw = HistoryFormat.RawRecord(offsetSeconds: 0, hash: 1, centi: 60_000,
                                          resetMinutes: HistoryFormat.noReset)
        XCTAssertEqual(HistoryFormat.sample(from: raw, series: series, epoch: epoch).usedPercent, 100)
    }

    /// `NaN` survives `min(max(...))` unclamped, so it is refused outright rather
    /// than stored as an arbitrary two-byte value.
    func testNonFinitePercentagesAreRefused() {
        for percent in [Double.nan, .infinity, -.infinity] {
            let sample = UsageSample(series: series, at: epoch, usedPercent: percent, resetAt: nil)
            XCTAssertNil(HistoryFormat.encodeRecord(sample, hash: 1, epoch: epoch))
        }
    }

    /// A sample stamped before the file's epoch cannot be expressed as a positive
    /// offset, and one past the 32-bit range would wrap to the wrong century.
    func testSamplesOutsideTheRepresentableRangeAreRefused() {
        let before = UsageSample(series: series, at: epoch.addingTimeInterval(-1), usedPercent: 5, resetAt: nil)
        XCTAssertNil(HistoryFormat.encodeRecord(before, hash: 1, epoch: epoch))

        let atEpoch = UsageSample(series: series, at: epoch, usedPercent: 5, resetAt: nil)
        XCTAssertNotNil(HistoryFormat.encodeRecord(atEpoch, hash: 1, epoch: epoch))

        let far = UsageSample(series: series, at: epoch.addingTimeInterval(TimeInterval(UInt32.max) + 1),
                              usedPercent: 5, resetAt: nil)
        XCTAssertNil(HistoryFormat.encodeRecord(far, hash: 1, epoch: epoch))
    }

    // MARK: - Reset encoding

    /// The sentinel means "no reset reported", 0 means "resets now", and those
    /// are different states — a window sits in the second between its deadline
    /// passing and the next probe.
    func testResetMinutesDistinguishesUnknownFromDue() {
        XCTAssertEqual(HistoryFormat.resetMinutes(from: epoch, to: nil), HistoryFormat.noReset)
        XCTAssertEqual(HistoryFormat.resetMinutes(from: epoch, to: epoch), 0)
        XCTAssertEqual(HistoryFormat.resetMinutes(from: epoch, to: epoch.addingTimeInterval(-86_400)), 0)
    }

    func testResetMinutesClampsBeyondItsRange() {
        XCTAssertEqual(HistoryFormat.resetMinutes(from: epoch, to: epoch.addingTimeInterval(90 * 60)), 90)
        // A week, the longest window any provider reports, must be well inside.
        XCTAssertEqual(HistoryFormat.resetMinutes(from: epoch, to: epoch.addingTimeInterval(7 * 86_400)), 10_080)
        // 45 days and beyond saturate one below the sentinel, never onto it.
        let far = HistoryFormat.resetMinutes(from: epoch, to: epoch.addingTimeInterval(400 * 86_400))
        XCTAssertEqual(far, HistoryFormat.maximumResetMinutes)
        XCTAssertNotEqual(far, HistoryFormat.noReset)
        XCTAssertEqual(HistoryFormat.resetMinutes(from: epoch, to: .distantFuture),
                       HistoryFormat.maximumResetMinutes)
    }

    func testTheSentinelDecodesBackToNoReset() {
        let raw = HistoryFormat.RawRecord(offsetSeconds: 0, hash: 1, centi: 100,
                                          resetMinutes: HistoryFormat.noReset)
        XCTAssertNil(HistoryFormat.sample(from: raw, series: series, epoch: epoch).resetAt)
    }

    // MARK: - Little-endian primitives

    func testLittleEndianPrimitivesRoundTripAtTheirBounds() {
        for value: UInt16 in [0, 1, 0x00FF, 0xFF00, .max] {
            XCTAssertEqual(HistoryFormat.readUInt16(HistoryFormat.littleEndian(value), at: 0), value)
        }
        for value: UInt32 in [0, 1, 0x0000_FFFF, 0xFFFF_0000, .max] {
            XCTAssertEqual(HistoryFormat.readUInt32(HistoryFormat.littleEndian(value), at: 0), value)
        }
        for value: UInt64 in [0, 1, 0xFFFF_FFFF, 1_700_000_000, .max] {
            XCTAssertEqual(HistoryFormat.readUInt64(HistoryFormat.littleEndian(value), at: 0), value)
        }
    }

    /// Least-significant byte first, pinned so a rewrite cannot quietly flip the
    /// byte order of every file already on disk.
    func testLittleEndianOrderIsPinned() {
        XCTAssertEqual(HistoryFormat.littleEndian(UInt16(0x1234)), [0x34, 0x12])
        XCTAssertEqual(HistoryFormat.littleEndian(UInt32(0x1234_5678)), [0x78, 0x56, 0x34, 0x12])
    }

    func testPrimitivesReadFromAnOffsetWithinABuffer() {
        let bytes: [UInt8] = [0xAA, 0xBB] + HistoryFormat.littleEndian(UInt32(0x1122_3344))
        XCTAssertEqual(HistoryFormat.readUInt32(bytes, at: 2), 0x1122_3344)
    }

    // MARK: - Series hashing

    /// Pinned values, not just determinism: `Hasher` is seeded per process, and
    /// swapping to it would hand the same series a different hash on every launch
    /// and orphan every record already written.
    func testFNV1aMatchesTheReferenceValues() {
        XCTAssertEqual(HistorySeriesCatalog.fnv1a(""), 2_166_136_261)
        XCTAssertEqual(HistorySeriesCatalog.fnv1a("a"), 3_826_002_220)
        XCTAssertEqual(HistorySeriesCatalog.fnv1a("codex|session"), 2_355_849_492)
    }

    /// The hash is taken over the provider slug and the window *key*, so two
    /// providers sharing a window name stay distinct.
    func testSeriesHashInputCombinesProviderAndWindowKey() {
        XCTAssertEqual(HistorySeriesID(provider: .codex, windowKey: "session").hashInput, "codex|session")
        XCTAssertNotEqual(HistorySeriesID(provider: .claude, windowKey: "session").hashInput,
                          HistorySeriesID(provider: .codex, windowKey: "session").hashInput)
    }

    // MARK: - Location

    /// History is state, not configuration, so on Linux it follows
    /// `XDG_STATE_HOME` rather than joining `state.json` under the config root.
    func testLinuxHistoryFollowsTheXDGStateConvention() {
        XCTAssertEqual(resolved(base: .xdgState, environment: ["XDG_STATE_HOME": "/tmp/state"]).path,
                       "/tmp/state/quotabar/history.bin")
        XCTAssertEqual(resolved(base: .xdgState, environment: [:]).path,
                       "/home/tester/.local/state/quotabar/history.bin")
        // An empty variable is not a path; fall back as though it were unset.
        XCTAssertEqual(resolved(base: .xdgState, environment: ["XDG_STATE_HOME": ""]).path,
                       "/home/tester/.local/state/quotabar/history.bin")
    }

    func testMacOSHistoryLivesInApplicationSupport() {
        XCTAssertEqual(resolved(base: .applicationSupport, environment: [:]).path,
                       "/home/tester/Library/Application Support/QuotaBar/history.bin")
    }

    /// Local, not roaming: history is machine-specific state and should not be
    /// synchronised onto every machine the account signs into. The injected value
    /// is POSIX-shaped so the assertion holds on the host actually running the
    /// suite, the same way `StateStoreTests` injects `APPDATA`.
    func testWindowsHistoryLivesInLocalAppData() {
        XCTAssertEqual(resolved(base: .windowsLocalAppData,
                                environment: ["LOCALAPPDATA": "/localappdata"]).path,
                       "/localappdata/QuotaBar/history.bin")
        XCTAssertEqual(resolved(base: .windowsLocalAppData, environment: [:]).path,
                       "/home/tester/AppData/Local/QuotaBar/history.bin")
        XCTAssertEqual(resolved(base: .windowsLocalAppData, environment: ["LOCALAPPDATA": ""]).path,
                       "/home/tester/AppData/Local/QuotaBar/history.bin")
    }

    /// The platform picks a convention rather than the resolver guessing, so a
    /// future front-end cannot silently inherit XDG paths.
    func testThePlatformSelectsAConvention() {
        #if os(macOS)
        XCTAssertEqual(HistoryLocation.platformBase, .applicationSupport)
        #elseif os(Windows)
        XCTAssertEqual(HistoryLocation.platformBase, .windowsLocalAppData)
        #else
        XCTAssertEqual(HistoryLocation.platformBase, .xdgState)
        #endif
        XCTAssertEqual(HistoryLocation.defaultURL().lastPathComponent, "history.bin")
    }

    // MARK: - Fixtures

    private func resolved(base: HistoryLocation.StateBase, environment: [String: String]) -> URL {
        HistoryLocation.defaultURL(environment: environment,
                                   home: URL(fileURLWithPath: "/home/tester", isDirectory: true),
                                   base: base)
    }
}
