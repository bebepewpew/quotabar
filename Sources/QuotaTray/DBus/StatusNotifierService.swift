import Foundation
import QuotaCore

/// Everything a tray can see about QuotaBar at one moment.
///
/// Built by the executable after each refresh and handed to the service, which
/// never reaches back for anything. That is what keeps the whole protocol
/// surface — every method a tray may call — testable without a bus.
public struct TrayState: Sendable {
    public var quotas: [MenuBarQuota]
    public var bitmaps: [TrayBitmap]
    public var toolTipLines: [String]
    public var menu: DBusMenuLayout
    /// dbusmenu requires a revision that increases whenever the layout changes;
    /// a tray refetches only when it sees a number it has not seen.
    public var revision: UInt32

    public init(quotas: [MenuBarQuota] = [], bitmaps: [TrayBitmap] = [],
                toolTipLines: [String] = [],
                menu: DBusMenuLayout = DBusMenuLayout.build(from: []),
                revision: UInt32 = 1) {
        self.quotas = quotas
        self.bitmaps = bitmaps
        self.toolTipLines = toolTipLines
        self.menu = menu
        self.revision = revision
    }
}

/// What a tray's click asked the application to do.
public enum TrayAction: Equatable, Sendable {
    case refresh
    case quit
}

/// The replies to send, and anything the application must act on.
public struct ServiceResponse: Equatable, Sendable {
    public var replies: [DBusMessage]
    public var action: TrayAction?

    public init(replies: [DBusMessage] = [], action: TrayAction? = nil) {
        self.replies = replies
        self.action = action
    }
}

/// Serves `org.kde.StatusNotifierItem` and `com.canonical.dbusmenu`.
///
/// A pure function of (message, state). The executable owns the socket and the
/// refresh timer; everything about *what* to answer lives here, so a tray's
/// entire vocabulary can be exercised in tests.
public enum StatusNotifierService {
    public static let itemInterface = "org.kde.StatusNotifierItem"
    public static let menuInterface = "com.canonical.dbusmenu"
    public static let itemPath = "/StatusNotifierItem"
    public static let watcherService = "org.kde.StatusNotifierWatcher"
    public static let watcherPath = "/StatusNotifierWatcher"

    /// dbusmenu protocol version we implement.
    public static let menuVersion: UInt32 = 3

    public static func handle(_ message: DBusMessage, state: TrayState) -> ServiceResponse {
        // Signals are broadcast, not addressed to us, and answering one would
        // send a reply nobody is waiting for.
        guard message.kind == .methodCall else { return ServiceResponse() }

        switch (message.interface, message.member) {
        case ("org.freedesktop.DBus.Peer", "Ping"):
            return ServiceResponse(replies: [reply(to: message)])
        case ("org.freedesktop.DBus.Introspectable", "Introspect"):
            return ServiceResponse(replies: [reply(to: message,
                                                   body: [.string(introspection(for: message.path))])])
        case ("org.freedesktop.DBus.Properties", "GetAll"):
            return properties(message, state: state, all: true)
        case ("org.freedesktop.DBus.Properties", "Get"):
            return properties(message, state: state, all: false)

        // A left click. `ItemIsMenu` is false precisely so this arrives.
        case (itemInterface, "Activate"):
            return ServiceResponse(replies: [reply(to: message)], action: .refresh)
        case (itemInterface, "SecondaryActivate"), (itemInterface, "Scroll"):
            // Answered so the tray does not log a failure, but deliberately
            // inert: a middle click or a scroll on a quota meter has no obvious
            // meaning, and guessing one is worse than doing nothing.
            return ServiceResponse(replies: [reply(to: message)])

        case (menuInterface, "GetLayout"):
            return ServiceResponse(replies: [reply(to: message, body: [
                .uint32(state.revision),
                state.menu.node,
            ])])
        case (menuInterface, "GetGroupProperties"):
            return ServiceResponse(replies: [reply(to: message,
                                                   body: [groupProperties(state: state)])])
        case (menuInterface, "AboutToShow"):
            // False: the layout is already current, so the tray need not refetch
            // before showing it. Answering true on every open makes a tray
            // rebuild the menu for nothing.
            return ServiceResponse(replies: [reply(to: message, body: [.boolean(false)])])
        case (menuInterface, "Event"):
            return event(message, state: state)
        case (menuInterface, "EventGroup"):
            // Same routing, but the tray batches. Returning an empty `ai` means
            // "no ids failed".
            return ServiceResponse(replies: [reply(to: message,
                                                   body: [.array(element: "i", values: [])])],
                                   action: batchedAction(message, state: state))

        default:
            return ServiceResponse(replies: [error(to: message,
                                                   name: "org.freedesktop.DBus.Error.UnknownMethod",
                                                   text: "\(message.interface ?? "?").\(message.member ?? "?")")])
        }
    }

    /// The call that puts the icon on the panel.
    public static func registration(uniqueName: String) -> DBusMessage {
        DBusMessage(kind: .methodCall,
                    path: watcherPath,
                    interface: watcherService,
                    member: "RegisterStatusNotifierItem",
                    destination: watcherService,
                    body: [.string(uniqueName)])
    }

    /// Signals telling a tray that something it has cached is stale.
    ///
    /// StatusNotifierItem predates `PropertiesChanged` carrying values, so these
    /// are bare pokes: the tray re-reads the property itself.
    public static func changeSignals(revision: UInt32) -> [DBusMessage] {
        ["NewIcon", "NewStatus", "NewToolTip"].map {
            DBusMessage(kind: .signal, path: itemPath, interface: itemInterface, member: $0)
        } + [
            DBusMessage(kind: .signal, path: StatusNotifierItemProperties.menuPath,
                        interface: menuInterface, member: "LayoutUpdated",
                        body: [.uint32(revision), .int32(DBusMenuLayout.rootID)]),
        ]
    }

    // MARK: Properties

    private static func properties(_ message: DBusMessage, state: TrayState,
                                   all: Bool) -> ServiceResponse {
        guard case .string(let interface)? = message.body.first else {
            return ServiceResponse(replies: [error(to: message,
                                                   name: "org.freedesktop.DBus.Error.InvalidArgs",
                                                   text: "expected an interface name")])
        }
        let table: [String: DBusValue]
        switch interface {
        case itemInterface:
            table = itemProperties(state: state)
        case menuInterface:
            table = menuProperties()
        default:
            return ServiceResponse(replies: [error(to: message,
                                                   name: "org.freedesktop.DBus.Error.UnknownInterface",
                                                   text: interface)])
        }

        if all {
            return ServiceResponse(replies: [reply(to: message, body: [.dictionary(table)])])
        }
        guard message.body.count > 1, case .string(let name) = message.body[1] else {
            return ServiceResponse(replies: [error(to: message,
                                                   name: "org.freedesktop.DBus.Error.InvalidArgs",
                                                   text: "expected a property name")])
        }
        guard let value = table[name] else {
            return ServiceResponse(replies: [error(to: message,
                                                   name: "org.freedesktop.DBus.Error.UnknownProperty",
                                                   text: name)])
        }
        return ServiceResponse(replies: [reply(to: message, body: [.variant(value)])])
    }

    static func itemProperties(state: TrayState) -> [String: DBusValue] {
        guard case .array(_, let entries) = StatusNotifierItemProperties.all(
            quotas: state.quotas, bitmaps: state.bitmaps, toolTipLines: state.toolTipLines)
        else { return [:] }
        var table = [String: DBusValue]()
        for entry in entries {
            guard case .dictEntry(let key, let value) = entry,
                  case .string(let name) = key, case .variant(let inner) = value else { continue }
            table[name] = inner
        }
        return table
    }

    static func menuProperties() -> [String: DBusValue] {
        [
            "Version": .uint32(menuVersion),
            "Status": .string("normal"),
            "TextDirection": .string("ltr"),
            "IconThemePath": .strings([]),
        ]
    }

    // MARK: dbusmenu

    /// `a(ia{sv})` — every item's properties, which a tray asks for instead of
    /// walking the layout when it only needs labels.
    private static func groupProperties(state: TrayState) -> DBusValue {
        guard case .struct(let root) = state.menu.node, root.count == 3,
              case .array(_, let children) = root[2] else {
            return .array(element: "(ia{sv})", values: [])
        }
        let entries: [DBusValue] = children.compactMap { child in
            guard case .variant(let node) = child, case .struct(let fields) = node,
                  fields.count == 3 else { return nil }
            return .struct([fields[0], fields[1]])
        }
        return .array(element: "(ia{sv})", values: entries)
    }

    private static func event(_ message: DBusMessage, state: TrayState) -> ServiceResponse {
        ServiceResponse(replies: [reply(to: message)], action: action(for: message.body, state: state))
    }

    /// `Event(id i, eventId s, data v, timestamp u)`.
    ///
    /// Only `clicked` acts. A tray also sends `hovered` and `opened`, and
    /// treating those as a click would refresh or quit on a mouse-over.
    private static func action(for body: [DBusValue], state: TrayState) -> TrayAction? {
        guard body.count >= 2, case .int32(let id) = body[0],
              case .string(let kind) = body[1], kind == "clicked",
              let actionID = state.menu.actions[id] else { return nil }
        switch actionID {
        case TrayMenu.refreshActionID: return .refresh
        case TrayMenu.quitActionID: return .quit
        default: return nil
        }
    }

    /// `EventGroup(a(isvu))`. Quit wins over refresh: if both are in one batch,
    /// refreshing first and then quitting wastes a probe the user cannot see.
    private static func batchedAction(_ message: DBusMessage, state: TrayState) -> TrayAction? {
        guard case .array(_, let events)? = message.body.first else { return nil }
        var found: TrayAction?
        for event in events {
            guard case .struct(let fields) = event, fields.count >= 2 else { continue }
            if let action = action(for: Array(fields.prefix(2)), state: state) {
                if action == .quit { return .quit }
                found = action
            }
        }
        return found
    }

    // MARK: Message helpers

    static func reply(to message: DBusMessage, body: [DBusValue] = []) -> DBusMessage {
        DBusMessage(kind: .methodReturn, replySerial: message.serial,
                    destination: message.sender, body: body)
    }

    static func error(to message: DBusMessage, name: String, text: String) -> DBusMessage {
        DBusMessage(kind: .error, errorName: name, replySerial: message.serial,
                    destination: message.sender, body: [.string(text)])
    }

    /// Introspection XML. Plasma does not require it, but `busctl introspect`
    /// and `d-feet` do, and being able to inspect the item by hand is what makes
    /// a tray that has not appeared diagnosable.
    static func introspection(for path: String?) -> String {
        let menuNode = """
            <interface name="com.canonical.dbusmenu">
              <property name="Version" type="u" access="read"/>
              <property name="Status" type="s" access="read"/>
              <property name="TextDirection" type="s" access="read"/>
              <property name="IconThemePath" type="as" access="read"/>
              <method name="GetLayout">
                <arg type="i" name="parentId" direction="in"/>
                <arg type="i" name="recursionDepth" direction="in"/>
                <arg type="as" name="propertyNames" direction="in"/>
                <arg type="u" name="revision" direction="out"/>
                <arg type="(ia{sv}av)" name="layout" direction="out"/>
              </method>
              <method name="GetGroupProperties">
                <arg type="ai" name="ids" direction="in"/>
                <arg type="as" name="propertyNames" direction="in"/>
                <arg type="a(ia{sv})" name="properties" direction="out"/>
              </method>
              <method name="Event">
                <arg type="i" name="id" direction="in"/>
                <arg type="s" name="eventId" direction="in"/>
                <arg type="v" name="data" direction="in"/>
                <arg type="u" name="timestamp" direction="in"/>
              </method>
              <method name="AboutToShow">
                <arg type="i" name="id" direction="in"/>
                <arg type="b" name="needUpdate" direction="out"/>
              </method>
              <signal name="LayoutUpdated">
                <arg type="u" name="revision"/>
                <arg type="i" name="parent"/>
              </signal>
            </interface>
            """
        let itemNode = """
            <interface name="org.kde.StatusNotifierItem">
              <property name="Category" type="s" access="read"/>
              <property name="Id" type="s" access="read"/>
              <property name="Title" type="s" access="read"/>
              <property name="Status" type="s" access="read"/>
              <property name="IconName" type="s" access="read"/>
              <property name="IconPixmap" type="a(iiay)" access="read"/>
              <property name="ItemIsMenu" type="b" access="read"/>
              <property name="Menu" type="o" access="read"/>
              <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
              <method name="Activate">
                <arg type="i" name="x" direction="in"/>
                <arg type="i" name="y" direction="in"/>
              </method>
              <signal name="NewIcon"/>
              <signal name="NewStatus"/>
              <signal name="NewToolTip"/>
            </interface>
            """
        let body = path == StatusNotifierItemProperties.menuPath ? menuNode : itemNode
        return """
            <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" \
            "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
            <node>
              <interface name="org.freedesktop.DBus.Introspectable">
                <method name="Introspect"><arg type="s" name="xml" direction="out"/></method>
              </interface>
              <interface name="org.freedesktop.DBus.Properties">
                <method name="Get">
                  <arg type="s" name="interface" direction="in"/>
                  <arg type="s" name="property" direction="in"/>
                  <arg type="v" name="value" direction="out"/>
                </method>
                <method name="GetAll">
                  <arg type="s" name="interface" direction="in"/>
                  <arg type="a{sv}" name="properties" direction="out"/>
                </method>
              </interface>
            \(body)
            </node>
            """
    }
}
