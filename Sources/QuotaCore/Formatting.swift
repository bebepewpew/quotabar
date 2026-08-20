import Foundation

public enum QuotaUrgency: String, Sendable, Codable {
    case normal, warning, critical

    public init(usedPercent: Double) {
        if usedPercent >= 95 { self = .critical }
        else if usedPercent >= 80 { self = .warning }
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
    public static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        return abs(clamped - clamped.rounded()) < 0.05
            ? "\(Int(clamped.rounded()))%"
            : String(format: "%.1f%%", clamped)
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

    /// The single most urgent row, used for one-line status bars.
    public static func mostUrgent(_ rows: [QuotaRow]) -> QuotaRow? {
        rows.filter { $0.usedPercent != nil }
            .max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) } ?? rows.first
    }
}

/// Payload shape consumed by waybar's `custom/*` modules; polybar and the Plasma
/// command-output widget read the `text` field just as happily.
public struct WaybarPayload: Encodable, Sendable {
    public let text: String
    public let tooltip: String
    public let `class`: String
    public let percentage: Int

    public init(rows: [QuotaRow]) {
        let leader = QuotaFormatting.mostUrgent(rows)
        text = leader.map { "\(QuotaBadge.preferred(for: $0.provider, window: $0.window)) \($0.percentText)" } ?? "n/a"
        tooltip = rows.map { row in
            let detail = row.error.map { " (\($0))" } ?? (row.resetText.isEmpty ? "" : " — \(row.resetText)")
            return "\(row.provider.rawValue) \(row.window): \(row.percentText)\(detail)"
        }.joined(separator: "\n")
        `class` = (leader?.urgency ?? .normal).rawValue
        percentage = Int((leader?.usedPercent ?? 0).rounded())
    }
}
