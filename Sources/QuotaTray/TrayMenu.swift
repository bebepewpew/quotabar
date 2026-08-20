import Foundation
import QuotaCore

/// One row of the tray menu, independent of any toolkit so it can be tested
/// without a display and rendered by whichever front-end consumes it.
public struct TrayMenuItem: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        case quota, error, separator, action
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
    /// A row per provider/window, a row that keeps a failed provider visible with
    /// its reason, then Refresh and Quit.
    public static func items(for snapshots: [QuotaSnapshot], now: Date = Date()) -> [TrayMenuItem] {
        // TODO(task 2: menu model)
        []
    }
}
