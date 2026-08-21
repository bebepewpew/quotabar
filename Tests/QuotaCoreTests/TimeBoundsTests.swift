import XCTest
import Foundation
@testable import QuotaCore

/// The bounds on the time axis, at the boundary values that decide them.
///
/// Every one of these numbers can arrive from a provider CLI's output or from a
/// flag the user types. `Int(_:)` is not failable, so an unbounded one is a trap
/// and a trap is a crash: the assertions below are as much about "does not
/// crash" as they are about the value returned.
final class TimeBoundsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - wholeSeconds

    func testWholeSecondsRoundsWithinRange() {
        XCTAssertEqual(QuotaTime.wholeSeconds(0), 0)
        XCTAssertEqual(QuotaTime.wholeSeconds(0.4), 0)
        XCTAssertEqual(QuotaTime.wholeSeconds(0.5), 1)
        XCTAssertEqual(QuotaTime.wholeSeconds(-0.5), -1)
        XCTAssertEqual(QuotaTime.wholeSeconds(59.6), 60)
        XCTAssertEqual(QuotaTime.wholeSeconds(2_000_000_000), 2_000_000_000)
    }

    /// `Int(1e19)` traps: 2^63 is 9.22e18, and a `Double` says nothing about
    /// that when it is handed over. Each of these clamps instead.
    func testWholeSecondsClampsWhatAnIntCannotHold() {
        XCTAssertEqual(QuotaTime.wholeSeconds(1e19), .max)
        XCTAssertEqual(QuotaTime.wholeSeconds(-1e19), .min)
        XCTAssertEqual(QuotaTime.wholeSeconds(.greatestFiniteMagnitude), .max)
        XCTAssertEqual(QuotaTime.wholeSeconds(-Double.greatestFiniteMagnitude), .min)
        XCTAssertEqual(QuotaTime.wholeSeconds(.infinity), .max)
        XCTAssertEqual(QuotaTime.wholeSeconds(-Double.infinity), .min)
        XCTAssertEqual(QuotaTime.wholeSeconds(.nan), 0, "a NaN is no point on the axis at all")
    }

    /// The exact edge of the conversion. `Double(Int.max)` rounds *up* to 2^63,
    /// which is one past what an `Int` holds, so the boundary case has to clamp
    /// rather than convert.
    func testWholeSecondsAtTheEdgeOfTheIntRange() {
        XCTAssertEqual(QuotaTime.wholeSeconds(Double(Int.max)), .max)
        XCTAssertEqual(QuotaTime.wholeSeconds(Double(Int.min)), .min)
        XCTAssertEqual(QuotaTime.wholeSeconds(9_223_372_036_854_774_784), 9_223_372_036_854_774_784,
                       "the largest double below 2^63 still converts")
    }

    func testEpochSecondsClampsRatherThanTrappingOnAnyDate() {
        XCTAssertEqual(QuotaTime.epochSeconds(now), 1_700_000_000)
        XCTAssertEqual(QuotaTime.epochSeconds(Date(timeIntervalSince1970: .greatestFiniteMagnitude)), .max)
        XCTAssertEqual(QuotaTime.epochSeconds(Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude)), .min)
    }

    // MARK: - resetInstant

    func testAnAbsoluteResetIsKeptThroughYear9999AndDroppedBeyondIt() {
        XCTAssertEqual(QuotaTime.resetInstant(epochSeconds: 0), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(QuotaTime.resetInstant(epochSeconds: 2_000_000_000),
                       Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(QuotaTime.resetInstant(epochSeconds: QuotaTime.maximumEpochSeconds),
                       Date(timeIntervalSince1970: QuotaTime.maximumEpochSeconds))
        XCTAssertNil(QuotaTime.resetInstant(epochSeconds: QuotaTime.maximumEpochSeconds + 1))
        XCTAssertNil(QuotaTime.resetInstant(epochSeconds: -1), "a reset before 1970 is not a reset")
        XCTAssertNil(QuotaTime.resetInstant(epochSeconds: 1e19))
        XCTAssertNil(QuotaTime.resetInstant(epochSeconds: .infinity))
        XCTAssertNil(QuotaTime.resetInstant(epochSeconds: .nan))
    }

    func testARelativeResetIsKeptUpToAWindowLengthAndDroppedBeyondIt() {
        XCTAssertEqual(QuotaTime.resetInstant(after: 3_600, from: now), now.addingTimeInterval(3_600))
        XCTAssertEqual(QuotaTime.resetInstant(after: QuotaTime.maximumResetInterval, from: now),
                       now.addingTimeInterval(QuotaTime.maximumResetInterval))
        XCTAssertNil(QuotaTime.resetInstant(after: QuotaTime.maximumResetInterval + 1, from: now))
        XCTAssertNil(QuotaTime.resetInstant(after: 0, from: now), "no interval is no reset")
        XCTAssertNil(QuotaTime.resetInstant(after: -3_600, from: now))
        XCTAssertNil(QuotaTime.resetInstant(after: .infinity, from: now))
        XCTAssertNil(QuotaTime.resetInstant(after: .nan, from: now))
        XCTAssertEqual(QuotaTime.maximumResetInterval, 31 * 86_400, "a week is the longest real window")
    }

    // MARK: - windowMinutes

    func testWindowMinutesAcceptsARealWindowAndRejectsANumberThatIsNotOne() {
        XCTAssertEqual(QuotaTime.windowMinutes(1), 1)
        XCTAssertEqual(QuotaTime.windowMinutes(360), 360)
        XCTAssertEqual(QuotaTime.windowMinutes(1_440), 1_440)
        XCTAssertEqual(QuotaTime.windowMinutes(10_080), 10_080, "a weekly window")
        XCTAssertEqual(QuotaTime.windowMinutes(44_640), 44_640, "the ceiling, in minutes")
        XCTAssertEqual(QuotaTime.windowMinutes(300.7), 300, "a fractional minute truncates, as it always did")
        XCTAssertNil(QuotaTime.windowMinutes(44_641))
        XCTAssertNil(QuotaTime.windowMinutes(0))
        XCTAssertNil(QuotaTime.windowMinutes(-300))
        XCTAssertNil(QuotaTime.windowMinutes(1e19))
        XCTAssertNil(QuotaTime.windowMinutes(.infinity))
        XCTAssertNil(QuotaTime.windowMinutes(.nan))
    }

    // MARK: - span

    func testSpanAcceptsAReportableWindowAndRejectsTheRest() {
        XCTAssertEqual(QuotaTime.span(90 * 60), 5_400)
        XCTAssertEqual(QuotaTime.span(7 * 86_400), 604_800)
        XCTAssertEqual(QuotaTime.span(QuotaTime.maximumSpan), QuotaTime.maximumSpan)
        XCTAssertNil(QuotaTime.span(QuotaTime.maximumSpan + 86_400))
        XCTAssertNil(QuotaTime.span(0))
        XCTAssertNil(QuotaTime.span(-1))
        XCTAssertNil(QuotaTime.span(1e300 * 86_400), "`--since 1e300d` is finite and still not a span")
        XCTAssertNil(QuotaTime.span(.infinity))
        XCTAssertNil(QuotaTime.span(.nan))
    }
}
