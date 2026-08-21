import Foundation
import QuotaCore

/// One row of the tray menu, independent of any toolkit so it can be tested
/// without a display and rendered by whichever front-end consumes it.
public struct TrayMenuItem: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        case quota, error, recommendation, separator, action
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let urgency: QuotaUrgency
    /// `"refresh"`, `"quit"`, … for `.action`; nil otherwise.
    public let actionID: String?
    public let enabled: Bool

    public init(kind: Kind, title: String, detail: String = "",
                urgency: QuotaUrgency = .normal, actionID: String? = nil, enabled: Bool = true) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.urgency = urgency
        self.actionID = actionID
        self.enabled = enabled
    }
}

public enum TrayMenu {
    public static let refreshActionID = "refresh"
    public static let quitActionID = "quit"

    /// A tray row is one line: an error longer than this is cut so a chatty CLI
    /// cannot push Refresh and Quit off the screen.
    static let reasonLimit = 120

    /// Only the most pressing advice reaches the tray. The full list is
    /// `quotabar advise`; a menu is not a report.
    static let maximumRecommendations = 2

    /// A row per provider/window, a row that keeps a failed provider visible with
    /// its reason, then Refresh and Quit.
    ///
    /// Text comes from `QuotaFormatting.rows(for:now:)` so the tray, the CLI and
    /// the waybar payload word a quota the same way, and so a provider that
    /// failed with cached windows still lists those windows — the failure is an
    /// extra row, never a reason to drop the numbers the user last saw.
    public static func items(for snapshots: [QuotaSnapshot], now: Date = Date()) -> [TrayMenuItem] {
        items(for: snapshots, recommendations: [], now: now)
    }

    /// As above, plus the advisor's most pressing findings.
    ///
    /// Informational advice is left out: "not enough history yet" is the right
    /// answer for `advise` and noise in a menu that exists to show numbers.
    public static func items(for snapshots: [QuotaSnapshot], recommendations: [Recommendation],
                             now: Date = Date()) -> [TrayMenuItem] {
        var items = snapshots.flatMap { snapshot -> [TrayMenuItem] in
            let rows = QuotaFormatting.rows(for: [snapshot], now: now)
            let quotas = rows.filter { $0.usedPercent != nil }.map { row in
                TrayMenuItem(kind: .quota,
                             title: "\(row.provider.rawValue) \(row.window)",
                             detail: detail(for: row),
                             urgency: row.urgency)
            }
            // `rows` repeats the provider's error on every window; the menu wants
            // one failure row per provider, not one per window.
            guard let error = rows.compactMap(\.error).first else { return quotas }
            return quotas + [TrayMenuItem(kind: .error, title: snapshot.provider.rawValue,
                                          detail: reason(error), urgency: .critical)]
        }
        let advice = recommendations
            .filter { $0.severity != .info }
            .prefix(maximumRecommendations)
            .map { recommendation in
                TrayMenuItem(kind: .recommendation,
                             title: reason(recommendation.headline),
                             detail: reason(recommendation.evidence.first ?? ""),
                             urgency: urgency(of: recommendation.severity))
            }
        if !advice.isEmpty {
            if !items.isEmpty { items.append(TrayMenuItem(kind: .separator, title: "")) }
            items += advice
        }
        // A leading separator would render as a stray rule above Refresh when no
        // provider is installed.
        if !items.isEmpty { items.append(TrayMenuItem(kind: .separator, title: "")) }
        items.append(TrayMenuItem(kind: .action, title: "Refresh", actionID: refreshActionID))
        items.append(TrayMenuItem(kind: .action, title: "Quit", actionID: quitActionID))
        return items
    }

    private static func urgency(of severity: Recommendation.Severity) -> QuotaUrgency {
        switch severity {
        case .critical: .critical
        case .warning: .warning
        case .opportunity, .info: .normal
        }
    }

    /// `QuotaFormatting` already clamped the percentage and phrased the reset;
    /// this only joins them.
    private static func detail(for row: QuotaRow) -> String {
        row.resetText.isEmpty ? row.percentText : "\(row.percentText) — \(row.resetText)"
    }

    /// A provider error carries CLI output, so it is untrusted: terminal control
    /// sequences go, the remaining lines collapse into the single line a menu row
    /// can show, and the failure never becomes an empty row.
    private static func reason(_ text: String) -> String {
        let text = CommandRunner.sanitizeDiagnostic(text)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        guard !text.isEmpty else { return "Unavailable" }
        guard text.count > reasonLimit else { return text }
        return text.prefix(reasonLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
