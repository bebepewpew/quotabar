import Foundation

/// The bounds the time axis is held to.
///
/// Percentages are clamped wherever they arrive; instants and durations were
/// not. A provider CLI can answer `{"resetsAt": 1e19}` and a user can type
/// `--since 1e400d`, and both survive as finite-or-infinite `Double`s into
/// `Int(_:)`, which is not failable: it traps on a NaN, on an infinity and on
/// any magnitude an `Int` cannot hold. A trap is a hard crash of the menu-bar
/// app on data it was only asked to display, so everything on the time axis
/// passes through here before it can reach a conversion.
public enum QuotaTime {
    /// The longest window any supported provider reports is a week. A month of
    /// slack keeps a longer vendor cycle readable while rejecting a number that
    /// is not a window length at all.
    public static let maximumResetInterval: TimeInterval = 31 * 86_400

    /// The end of year 9999 in epoch seconds. Codex reports its reset as an
    /// absolute instant, so it is bounded absolutely rather than against a
    /// local clock that may itself be wrong — a fixture dated 2033 is still a
    /// reset, and `1e19` still is not.
    public static let maximumEpochSeconds: TimeInterval = 253_402_300_800

    /// How far ahead a reset is described precisely. Past it the wording says
    /// so instead of printing a number a malformed value produced.
    public static let reportingHorizon: TimeInterval = 365 * 86_400

    /// The longest span a report or a `--since` window may cover: a century,
    /// far past the three months of history that are kept, and small enough
    /// that every seconds-to-`Int` conversion downstream stays in range.
    public static let maximumSpan: TimeInterval = 100 * 365 * 86_400

    /// Rounds to whole seconds, clamping to the boundary instead of trapping.
    /// A NaN is no point on the axis at all and reads as zero.
    public static func wholeSeconds(_ value: TimeInterval) -> Int {
        guard !value.isNaN else { return 0 }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return .max }
        if rounded <= Double(Int.min) { return .min }
        return Int(rounded)
    }

    /// Whole seconds since 1970 for any `Date`, including one restored from a
    /// cache an older build wrote.
    public static func epochSeconds(_ date: Date) -> Int {
        wholeSeconds(date.timeIntervalSince1970)
    }

    /// An absolute reset instant, or `nil` when the number cannot be one: a
    /// reset before 1970 or past year 9999 is a malformed value, and a window
    /// with no reset already renders and alerts correctly.
    public static func resetInstant(epochSeconds value: TimeInterval) -> Date? {
        guard value >= 0, value <= maximumEpochSeconds else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// A reset `interval` ahead of `now`, or `nil` when it is longer than a
    /// quota window can be.
    public static func resetInstant(after interval: TimeInterval, from now: Date) -> Date? {
        guard interval > 0, interval <= maximumResetInterval else { return nil }
        return now.addingTimeInterval(interval)
    }

    /// A window length in whole minutes, or `nil` when the number cannot be
    /// one. A duration that is not believable must not name the window.
    public static func windowMinutes(_ value: Double) -> Int? {
        guard value >= 1, value <= maximumResetInterval / 60 else { return nil }
        return Int(value)
    }

    /// A span of `seconds`, or `nil` when it is not one a report can cover.
    public static func span(_ seconds: TimeInterval) -> TimeInterval? {
        guard seconds > 0, seconds <= maximumSpan else { return nil }
        return seconds
    }
}
