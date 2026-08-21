import XCTest
import Foundation
@testable import QuotaTray
import QuotaCore

final class StatusNotifierServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func state() -> TrayState {
        let snapshot = QuotaSnapshot(
            provider: .codex,
            windows: [QuotaWindow(key: "weekly", label: "Weekly", usedPercent: 40, resetAt: nil)],
            error: nil, updatedAt: now)
        return TrayStateBuilder.make(
            snapshots: [snapshot],
            selections: [QuotaSelection(provider: .codex, windowKey: "weekly", windowLabel: "Weekly")],
            revision: 7, now: now)
    }

    private func call(_ interface: String, _ member: String, body: [DBusValue] = [],
                      path: String = StatusNotifierService.itemPath) -> ServiceResponse {
        StatusNotifierService.handle(
            DBusMessage(kind: .methodCall, serial: 11, path: path, interface: interface,
                        member: member, sender: ":1.99", body: body),
            state: state())
    }

    private func variant(_ name: String, in value: DBusValue?) -> DBusValue? {
        guard case .array(_, let entries)? = value else { return nil }
        for entry in entries {
            guard case .dictEntry(let key, let wrapped) = entry,
                  case .string(let found) = key, found == name,
                  case .variant(let inner) = wrapped else { continue }
            return inner
        }
        return nil
    }

    // MARK: Routing

    /// A signal is a broadcast, not a call. Replying to one sends a message
    /// nobody is waiting for, and the bus would route it to whoever sent it.
    func testASignalIsNeverAnswered() {
        let signal = DBusMessage(kind: .signal, serial: 3, path: "/x",
                                 interface: "org.freedesktop.DBus", member: "NameOwnerChanged")
        XCTAssertEqual(StatusNotifierService.handle(signal, state: state()), ServiceResponse())
    }

    func testAnUnknownMethodBecomesAnUnknownMethodError() {
        let response = call(StatusNotifierService.itemInterface, "Teleport")
        XCTAssertEqual(response.replies.count, 1)
        XCTAssertEqual(response.replies[0].kind, .error)
        XCTAssertEqual(response.replies[0].errorName, "org.freedesktop.DBus.Error.UnknownMethod")
        XCTAssertNil(response.action)
    }

    /// Every reply has to carry the serial it answers and be addressed back to
    /// the caller, or the bus cannot route it.
    func testEveryReplyIsAddressedToItsCaller() {
        let response = call("org.freedesktop.DBus.Peer", "Ping")
        XCTAssertEqual(response.replies[0].kind, .methodReturn)
        XCTAssertEqual(response.replies[0].replySerial, 11)
        XCTAssertEqual(response.replies[0].destination, ":1.99")
    }

    // MARK: Properties

    func testGetAllOnTheItemInterfaceReturnsEveryPropertyATrayReads() {
        let response = call("org.freedesktop.DBus.Properties", "GetAll",
                            body: [.string(StatusNotifierService.itemInterface)])
        let table = response.replies[0].body.first
        XCTAssertEqual(variant("Id", in: table), .string("quotabar"))
        XCTAssertEqual(variant("Category", in: table), .string("ApplicationStatus"))
        XCTAssertEqual(variant("ItemIsMenu", in: table), .boolean(false))
        XCTAssertEqual(variant("Menu", in: table), .objectPath("/MenuBar"))
        XCTAssertEqual(table?.signature, "a{sv}")
        XCTAssertTrue(table?.isWellFormed == true)
    }

    func testGetAllOnTheMenuInterfaceReturnsTheDbusmenuProperties() {
        let response = call("org.freedesktop.DBus.Properties", "GetAll",
                            body: [.string(StatusNotifierService.menuInterface)])
        let table = response.replies[0].body.first
        XCTAssertEqual(variant("Version", in: table), .uint32(3))
        XCTAssertEqual(variant("Status", in: table), .string("normal"))
        XCTAssertEqual(variant("TextDirection", in: table), .string("ltr"))
        XCTAssertEqual(variant("IconThemePath", in: table), .strings([]))
    }

    func testGetReturnsOnePropertyWrappedInAVariant() {
        let response = call("org.freedesktop.DBus.Properties", "Get",
                            body: [.string(StatusNotifierService.itemInterface), .string("Status")])
        XCTAssertEqual(response.replies[0].body, [.variant(.string("Active"))])
    }

    func testGetOnAnUnknownPropertyIsAnError() {
        let response = call("org.freedesktop.DBus.Properties", "Get",
                            body: [.string(StatusNotifierService.itemInterface), .string("Nope")])
        XCTAssertEqual(response.replies[0].errorName, "org.freedesktop.DBus.Error.UnknownProperty")
    }

    func testAnUnknownInterfaceIsAnError() {
        let response = call("org.freedesktop.DBus.Properties", "GetAll",
                            body: [.string("com.example.Other")])
        XCTAssertEqual(response.replies[0].errorName, "org.freedesktop.DBus.Error.UnknownInterface")
    }

    /// A malformed call must be answered with an error, not ignored: a tray that
    /// gets no reply waits, and eventually drops the item.
    func testAMissingArgumentIsAnErrorRatherThanSilence() {
        let noInterface = call("org.freedesktop.DBus.Properties", "GetAll")
        XCTAssertEqual(noInterface.replies[0].errorName, "org.freedesktop.DBus.Error.InvalidArgs")

        let noProperty = call("org.freedesktop.DBus.Properties", "Get",
                              body: [.string(StatusNotifierService.itemInterface)])
        XCTAssertEqual(noProperty.replies[0].errorName, "org.freedesktop.DBus.Error.InvalidArgs")
    }

    // MARK: Clicks

    /// `ItemIsMenu` is false precisely so a left click arrives here.
    func testALeftClickRefreshes() {
        let response = call(StatusNotifierService.itemInterface, "Activate",
                            body: [.int32(0), .int32(0)])
        XCTAssertEqual(response.action, .refresh)
        XCTAssertEqual(response.replies[0].kind, .methodReturn)
    }

    /// Answered so the tray does not log a failure, but deliberately inert.
    func testAMiddleClickAndAScrollAreAnsweredButDoNothing() {
        for member in ["SecondaryActivate", "Scroll"] {
            let response = call(StatusNotifierService.itemInterface, member)
            XCTAssertEqual(response.replies[0].kind, .methodReturn, member)
            XCTAssertNil(response.action, member)
        }
    }

    func testClickingRefreshAndQuitRoutesToTheirActions() {
        let menu = state().menu
        let refreshID = menu.actions.first { $0.value == TrayMenu.refreshActionID }?.key
        let quitID = menu.actions.first { $0.value == TrayMenu.quitActionID }?.key
        XCTAssertNotNil(refreshID)
        XCTAssertNotNil(quitID)

        XCTAssertEqual(call(StatusNotifierService.menuInterface, "Event",
                            body: [.int32(refreshID!), .string("clicked"),
                                   .variant(.string("")), .uint32(0)]).action, .refresh)
        XCTAssertEqual(call(StatusNotifierService.menuInterface, "Event",
                            body: [.int32(quitID!), .string("clicked"),
                                   .variant(.string("")), .uint32(0)]).action, .quit)
    }

    /// A tray sends `hovered` and `opened` too. Treating those as a click would
    /// refresh — or quit — on a mouse-over.
    func testOnlyAClickActs() {
        let quitID = state().menu.actions.first { $0.value == TrayMenu.quitActionID }!.key
        for event in ["hovered", "opened", "closed"] {
            let response = call(StatusNotifierService.menuInterface, "Event",
                                body: [.int32(quitID), .string(event),
                                       .variant(.string("")), .uint32(0)])
            XCTAssertNil(response.action, event)
            XCTAssertEqual(response.replies[0].kind, .methodReturn, event)
        }
    }

    func testClickingAReadoutRowDoesNothing() {
        // Row 1 is a quota readout, which is not in the dispatch table.
        let response = call(StatusNotifierService.menuInterface, "Event",
                            body: [.int32(1), .string("clicked"),
                                   .variant(.string("")), .uint32(0)])
        XCTAssertNil(response.action)
    }

    func testAnEventForAnUnknownIdIsAnsweredWithoutActing() {
        let response = call(StatusNotifierService.menuInterface, "Event",
                            body: [.int32(9999), .string("clicked"),
                                   .variant(.string("")), .uint32(0)])
        XCTAssertNil(response.action)
        XCTAssertEqual(response.replies[0].kind, .methodReturn)
    }

    /// Refreshing and then quitting wastes a probe nobody will see.
    func testQuitWinsOverRefreshInOneBatch() {
        let menu = state().menu
        let refreshID = menu.actions.first { $0.value == TrayMenu.refreshActionID }!.key
        let quitID = menu.actions.first { $0.value == TrayMenu.quitActionID }!.key
        let events = DBusValue.array(element: "(isvu)", values: [
            .struct([.int32(refreshID), .string("clicked"), .variant(.string("")), .uint32(0)]),
            .struct([.int32(quitID), .string("clicked"), .variant(.string("")), .uint32(0)]),
        ])
        let response = call(StatusNotifierService.menuInterface, "EventGroup", body: [events])
        XCTAssertEqual(response.action, .quit)
        XCTAssertEqual(response.replies[0].body, [.array(element: "i", values: [])])
    }

    // MARK: Menu

    func testGetLayoutReturnsTheRevisionAndTheLayout() {
        let response = call(StatusNotifierService.menuInterface, "GetLayout",
                            body: [.int32(0), .int32(-1), .strings([])])
        XCTAssertEqual(response.replies[0].body.first, .uint32(7))
        XCTAssertEqual(response.replies[0].body.last?.signature, "(ia{sv}av)")
        XCTAssertTrue(response.replies[0].body.last?.isWellFormed == true)
    }

    func testGetGroupPropertiesListsEveryRow() {
        let response = call(StatusNotifierService.menuInterface, "GetGroupProperties",
                            body: [.array(element: "i", values: []), .strings([])])
        let entries = response.replies[0].body.first
        XCTAssertEqual(entries?.signature, "a(ia{sv})")
        XCTAssertTrue(entries?.isWellFormed == true)
        guard case .array(_, let rows)? = entries else { return XCTFail("expected a(ia{sv})") }
        XCTAssertFalse(rows.isEmpty)
    }

    /// Answering true on every open makes a tray rebuild the menu for nothing.
    func testAboutToShowSaysTheLayoutIsAlreadyCurrent() {
        XCTAssertEqual(call(StatusNotifierService.menuInterface, "AboutToShow",
                            body: [.int32(0)]).replies[0].body, [.boolean(false)])
    }

    // MARK: Registration and signals

    func testRegistrationTargetsTheWatcherWithOurName() {
        let message = StatusNotifierService.registration(uniqueName: ":1.42")
        XCTAssertEqual(message.kind, .methodCall)
        XCTAssertEqual(message.destination, "org.kde.StatusNotifierWatcher")
        XCTAssertEqual(message.path, "/StatusNotifierWatcher")
        XCTAssertEqual(message.member, "RegisterStatusNotifierItem")
        XCTAssertEqual(message.body, [.string(":1.42")])
    }

    /// StatusNotifierItem predates PropertiesChanged carrying values, so these
    /// are bare pokes and the tray re-reads for itself.
    func testChangeSignalsPokeEveryCachedProperty() {
        let signals = StatusNotifierService.changeSignals(revision: 12)
        XCTAssertEqual(signals.map(\.member), ["NewIcon", "NewStatus", "NewToolTip", "LayoutUpdated"])
        XCTAssertTrue(signals.allSatisfy { $0.kind == .signal })
        XCTAssertEqual(signals.last?.body, [.uint32(12), .int32(0)])
        XCTAssertEqual(signals.last?.path, "/MenuBar")
    }

    // MARK: Introspection

    func testIntrospectionDescribesTheInterfaceAtEachPath() {
        let item = StatusNotifierService.introspection(for: StatusNotifierService.itemPath)
        XCTAssertTrue(item.contains("org.kde.StatusNotifierItem"))
        XCTAssertFalse(item.contains("com.canonical.dbusmenu"))

        let menu = StatusNotifierService.introspection(for: "/MenuBar")
        XCTAssertTrue(menu.contains("com.canonical.dbusmenu"))
        XCTAssertFalse(menu.contains("org.kde.StatusNotifierItem"))

        // Both carry the standard interfaces, which is what busctl walks.
        for xml in [item, menu] {
            XCTAssertTrue(xml.contains("org.freedesktop.DBus.Properties"))
            XCTAssertTrue(xml.contains("<node>"))
        }
    }

    func testIntrospectIsAnsweredOverTheBus() {
        let response = call("org.freedesktop.DBus.Introspectable", "Introspect")
        guard case .string(let xml)? = response.replies[0].body.first else {
            return XCTFail("expected XML")
        }
        XCTAssertTrue(xml.contains("org.kde.StatusNotifierItem"))
    }
}
