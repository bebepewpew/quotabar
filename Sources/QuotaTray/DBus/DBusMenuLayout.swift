import Foundation
import QuotaCore

/// A `com.canonical.dbusmenu` layout built from `TrayMenu.items(for:now:)`.
///
/// StatusNotifierItem carries no menu of its own; it points at a dbusmenu object
/// and the tray fetches the layout from there. This turns the toolkit-independent
/// rows the tray model already produces into that wire shape, and hands back the
/// id-to-action mapping the transport needs to route a click — so which row is
/// clickable, and what clicking it means, is decided in tested code rather than
/// in the D-Bus callback.
public struct DBusMenuLayout: Equatable, Sendable {
    /// `(id, properties, children)` — signature `(ia{sv}av)`.
    public let node: DBusValue
    /// Menu item id to `TrayMenuItem.actionID`, for dispatching `Event`.
    public let actions: [Int32: String]

    public init(node: DBusValue, actions: [Int32: String]) {
        self.node = node
        self.actions = actions
    }
}

public extension DBusMenuLayout {
    /// dbusmenu reserves 0 for the root.
    static let rootID: Int32 = 0

    /// Fixed ids for the rows a click can act on.
    ///
    /// Not positional. Rows come and go as providers fail and recover, so a
    /// position-numbered id means an id shifts under a menu the user already has
    /// open — and a click still in flight then lands on whatever now occupies
    /// that slot. One row fewer and a click on Refresh arrives as the id Quit
    /// used to have, exiting the app instead. Pinning the actions means a stale
    /// id names the same action or names nothing, never a different one.
    static let actionIDs: [String: Int32] = [
        TrayMenu.refreshActionID: 1,
        TrayMenu.quitActionID: 2,
    ]

    /// Readout rows are numbered above every reserved action id, so the two
    /// ranges can never collide however many rows there are.
    static let firstReadoutID: Int32 = 100

    /// Builds the layout a tray will render.
    ///
    /// Quota and error rows are `enabled: false`. They are readouts, not
    /// commands, and a menu entry that highlights on hover but does nothing when
    /// clicked reads as broken. Only `.action` rows are live.
    static func build(from items: [TrayMenuItem]) -> DBusMenuLayout {
        var actions = [Int32: String]()
        var children = [DBusValue]()
        var nextReadoutID = firstReadoutID

        for item in items {
            // An actionable row keeps its reserved id across every layout; only
            // the readouts are numbered by position, and a stale click on one of
            // those does nothing because they are not in the dispatch table.
            let id: Int32
            if isEnabled(item), let actionID = item.actionID, let reserved = actionIDs[actionID] {
                id = reserved
                // Keyed off the same predicate that decides `enabled`, so the
                // menu cannot advertise a row as dead and still act on it.
                actions[id] = actionID
            } else {
                id = nextReadoutID
                nextReadoutID += 1
            }
            children.append(.variant(.struct([
                .int32(id),
                .dictionary(properties(for: item)),
                // Nothing here nests, but the signature still has to be `av`.
                .array(element: "v", values: []),
            ])))
        }

        let node = DBusValue.struct([
            .int32(rootID),
            .dictionary(["children-display": .string("submenu")]),
            .array(element: "v", values: children),
        ])
        return DBusMenuLayout(node: node, actions: actions)
    }

    /// The `a{sv}` properties of one row.
    ///
    /// Only what differs from the dbusmenu defaults is sent. A tray applies the
    /// spec's defaults for anything absent, so repeating them makes every message
    /// bigger for no behavioural difference.
    static func properties(for item: TrayMenuItem) -> [String: DBusValue] {
        if item.kind == .separator {
            return ["type": .string("separator")]
        }
        var properties: [String: DBusValue] = [
            "label": .string(label(for: item)),
        ]
        // `enabled` defaults to true, so it is only worth sending when false.
        if !isEnabled(item) {
            properties["enabled"] = .boolean(false)
        }
        return properties
    }

    /// Whether a row responds to a click. `.action` rows do, when the model says
    /// so; everything else is a readout.
    static func isEnabled(_ item: TrayMenuItem) -> Bool {
        item.kind == .action && item.enabled && item.actionID != nil
    }

    /// The visible text of a row.
    ///
    /// dbusmenu reads `_` as a mnemonic marker — `_Quit` underlines the Q — so a
    /// literal underscore has to be doubled or it disappears from the label and
    /// silently steals a keyboard shortcut. Provider and window names come from
    /// CLI output, which `AGENTS.md` treats as untrusted, so this is not
    /// hypothetical.
    static func label(for item: TrayMenuItem) -> String {
        let text = item.detail.isEmpty ? item.title : "\(item.title)  \(item.detail)"
        return text.replacingOccurrences(of: "_", with: "__")
    }
}
