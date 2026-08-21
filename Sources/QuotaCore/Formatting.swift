import Foundation

public enum QuotaUrgency: String, Sendable, Codable {
    case normal, warning, critical

    /// The exact reading each band starts at. Named rather than inlined because
    /// `QuotaFormatting.percent` reads them too, so a rounded percentage can
    /// never land on a threshold the reading itself has not reached.
    static let warningAt = 80.0
    static let criticalAt = 95.0
    static let boundaries: [Double] = [warningAt, criticalAt]

    public init(usedPercent: Double) {
        if usedPercent >= Self.criticalAt { self = .critical }
        else if usedPercent >= Self.warningAt { self = .warning }
        else { self = .normal }
    }
}

/// One provider/window pair flattened for display. Front-ends decide colour and
/// column widths; this type only decides *what* the text says.
public struct QuotaRow: Sendable, Equatable {
    public let provider: Provider
    public let window: String
    public let usedPercent: Double?
    public let percentText: String
    public let resetText: String
    public let urgency: QuotaUrgency
    public let error: String?

    public init(provider: Provider, window: String, usedPercent: Double?, percentText: String,
                resetText: String, urgency: QuotaUrgency, error: String?) {
        self.provider = provider
        self.window = window
        self.usedPercent = usedPercent
        self.percentText = percentText
        self.resetText = resetText
        self.urgency = urgency
        self.error = error
    }
}

public enum QuotaFormatting {
    /// A reading as text: whole when it is within 0.05 of a whole number, one
    /// decimal otherwise — but never rounded up onto or past an urgency
    /// threshold the reading has not reached. 79.96 rendered as "80%" beside a
    /// `.normal` tint and no notification, contradicting both, so it renders as
    /// "79.9%" instead.
    public static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        let whole = clamped.rounded()
        if abs(clamped - whole) < 0.05, !overstates(clamped, shownAs: whole) {
            return "\(Int(whole))%"
        }
        // `%.1f` rounds as well, so a reading a hair under a threshold has to be
        // floored at the precision it is displayed with, not merely left to it.
        let tenths = clamped * 10
        guard overstates(clamped, shownAs: tenths.rounded() / 10) else {
            return String(format: "%.1f%%", clamped)
        }
        return String(format: "%.1f%%", tenths.rounded(.down) / 10)
    }

    /// Whether displaying `value` as `shown` would put it in a higher urgency
    /// band than the reading is actually in.
    private static func overstates(_ value: Double, shownAs shown: Double) -> Bool {
        QuotaUrgency.boundaries.contains { value < $0 && shown >= $0 }
    }

    /// Compact, locale-free "resets in" text.
    ///
    /// `RelativeDateTimeFormatter` is absent from swift-corelibs-foundation, so the
    /// macOS and Linux front-ends share this instead of diverging on wording.
    public static func relativeReset(_ date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return "now" }
        if seconds < 60 { return "in under a minute" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let parts: [String]
        if days > 0 { parts = hours > 0 ? ["\(days)d", "\(hours)h"] : ["\(days)d"] }
        else if hours > 0 { parts = minutes > 0 ? ["\(hours)h", "\(minutes)m"] : ["\(hours)h"] }
        else { parts = ["\(minutes)m"] }
        return "in " + parts.joined(separator: " ")
    }

    /// Flattens snapshots into display rows. A failed probe with no cached windows
    /// still yields one row so the provider never silently disappears.
    public static func rows(for snapshots: [QuotaSnapshot], now: Date = Date()) -> [QuotaRow] {
        snapshots.flatMap { snapshot -> [QuotaRow] in
            guard !snapshot.windows.isEmpty else {
                return [QuotaRow(provider: snapshot.provider, window: "—", usedPercent: nil,
                                 percentText: "—", resetText: "", urgency: .normal,
                                 error: snapshot.error ?? "No quota data")]
            }
            return snapshot.windows.map { window in
                QuotaRow(provider: snapshot.provider,
                         window: window.label,
                         usedPercent: window.usedPercent,
                         percentText: percent(window.usedPercent),
                         resetText: window.resetAt.map { "resets \(relativeReset($0, from: now))" } ?? "",
                         urgency: QuotaUrgency(usedPercent: window.usedPercent),
                         error: snapshot.error)
            }
        }
    }

    /// Fixed-width usage bar, e.g. `████░░░░░░`.
    public static func bar(_ usedPercent: Double?, width: Int = 10) -> String {
        guard let usedPercent else { return String(repeating: "·", count: width) }
        let filled = Int((min(max(usedPercent, 0), 100) / 100 * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    /// Eight-level sparkline. `nil` is a bucket nothing was sampled in and
    /// renders as a gap, so an unwatched stretch never looks like zero usage.
    public static func sparkline(_ values: [Double?]) -> String {
        let ramp: [Character] = ["\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
                                 "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}"]
        return String(values.map { value -> Character in
            guard let value else { return " " }
            let clamped = min(max(value, 0), 100)
            return ramp[min(Int(clamped / 100 * Double(ramp.count - 1) + 0.5), ramp.count - 1)]
        })
    }

    /// Buckets `count` equal time slices across `from...to`, taking the **highest**
    /// reading in each. Maximum rather than mean because a downsampled chart that
    /// loses the peak loses the only number that matters.
    public static func buckets(_ points: [(at: Date, usedPercent: Double)],
                               from: Date, to: Date, count: Int) -> [Double?] {
        guard count > 0 else { return [] }
        let span = to.timeIntervalSince(from)
        guard span > 0 else {
            let only = points.map(\.usedPercent).max()
            return Array(repeating: only, count: count)
        }
        var out = [Double?](repeating: nil, count: count)
        for point in points {
            let offset = point.at.timeIntervalSince(from)
            guard offset >= 0, offset <= span else { continue }
            let index = min(Int(offset / span * Double(count)), count - 1)
            out[index] = max(out[index] ?? -1, point.usedPercent)
        }
        return out
    }

    /// The single most urgent row, used for one-line status bars. Rows without a
    /// reading are never the leader — a bar should say "n/a" rather than show a
    /// provider name next to an empty percentage.
    public static func mostUrgent(_ rows: [QuotaRow]) -> QuotaRow? {
        rows.filter { $0.usedPercent != nil }
            .max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }
}

/// Payload shape consumed by waybar's `custom/*` modules; polybar and the Plasma
/// command-output widget read the `text` field just as happily.
///
/// The leading reading decides `text`, `class`, `percentage` and `stale`, while
/// `tooltip` lists every row. Another program reads this, so keys are only ever
/// added: renaming one breaks a status bar the way changing a storage key breaks
/// a cache.
public struct WaybarPayload: Encodable, Sendable {
    /// The `class` for "no provider reported anything", which is not the same
    /// state as a healthy `normal` and is documented alongside the three
    /// `QuotaUrgency` names in `README.md`.
    public static let unavailableClass = "unavailable"

    /// The marker `text` carries for a retained reading, matching the glyph the
    /// CLI table puts beside the same row so staleness survives without colour.
    public static let staleMarker = "\u{26A0}"

    public let text: String
    public let tooltip: String
    public let `class`: String
    /// `nil` when nothing reported a reading. Encoded as JSON `null` rather than
    /// dropped, so the key a status bar reads is always present, and never `0`,
    /// which would claim a quota is untouched when it is simply unknown.
    public let percentage: Int?
    /// True when the leading reading is a retained one whose refresh failed, so
    /// the number is the last good value rather than a fresh one.
    public let stale: Bool

    private enum CodingKeys: String, CodingKey {
        case text, tooltip, `class`, percentage, stale
    }

    public init(rows: [QuotaRow]) {
        let leader = QuotaFormatting.mostUrgent(rows)
        // A local rather than `self.stale`: the closure below would otherwise
        // capture a partly initialised `self`.
        let isStale = leader?.error != nil
        stale = isStale
        text = leader.map {
            let head = "\(QuotaBadge.preferred(for: $0.provider, window: $0.window)) \($0.percentText)"
            return isStale ? "\(head) \(Self.staleMarker)" : head
        } ?? "n/a"
        tooltip = rows.map { row in
            guard row.usedPercent != nil else {
                return "\(row.provider.rawValue): \(row.error ?? "unavailable")"
            }
            let detail = row.error.map { " (\($0))" } ?? (row.resetText.isEmpty ? "" : " — \(row.resetText)")
            return "\(row.provider.rawValue) \(row.window): \(row.percentText)\(detail)"
        }.joined(separator: "\n")
        `class` = leader.map(\.urgency.rawValue) ?? Self.unavailableClass
        if let used = leader?.usedPercent {
            percentage = Int(used.rounded())
        } else {
            percentage = nil
        }
    }

    /// Hand-written so `percentage` is emitted as `null` instead of being left
    /// out: the synthesised encoding drops a `nil` optional, and a consumer that
    /// reads the key unconditionally would then find nothing at all.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(tooltip, forKey: .tooltip)
        try container.encode(`class`, forKey: .class)
        try container.encode(percentage, forKey: .percentage)
        try container.encode(stale, forKey: .stale)
    }
}
