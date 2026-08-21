import XCTest
import Foundation
@testable import QuotaTray
import QuotaCore

final class DBusMenuLayoutTests: XCTestCase {
    private func action(_ title: String, _ id: String, enabled: Bool = true) -> TrayMenuItem {
        TrayMenuItem(kind: .action, title: title, actionID: id, enabled: enabled)
    }

    private func properties(of node: DBusValue) -> [String: DBusValue] {
        guard case .struct(let members) = node, members.count == 3,
              case .array(_, let entries) = members[1] else { return [:] }
        var found = [String: DBusValue]()
        for entry in entries {
            guard case .dictEntry(let key, let value) = entry,
                  case .string(let name) = key, case .variant(let inner) = value else { continue }
            found[name] = inner
        }
        return found
    }

    private func children(of layout: DBusMenuLayout) -> [DBusValue] {
        guard case .struct(let members) = layout.node, members.count == 3,
              case .array(_, let kids) = members[2] else { return [] }
        return kids.compactMap { child in
            guard case .variant(let inner) = child else { return nil }
            return inner
        }
    }

    func testLayoutSignatureMatchesTheDbusmenuSpec() {
        let layout = DBusMenuLayout.build(from: [action("Refresh", TrayMenu.refreshActionID)])
        XCTAssertEqual(layout.node.signature, "(ia{sv}av)")
        XCTAssertTrue(layout.node.isWellFormed)
    }

    func testRootIsZeroAndChildrenAreNumberedFromOne() {
        let layout = DBusMenuLayout.build(from: [
            action("Refresh", TrayMenu.refreshActionID),
            action("Quit", TrayMenu.quitActionID),
        ])
        guard case .struct(let members) = layout.node else { return XCTFail("expected a struct") }
        XCTAssertEqual(members[0], .int32(0))

        let ids: [DBusValue] = children(of: layout).compactMap { child in
            guard case .struct(let fields) = child else { return nil }
            return fields[0]
        }
        XCTAssertEqual(ids, [.int32(1), .int32(2)])
    }

    func testAnEmptyMenuIsStillAWellFormedRoot() {
        let layout = DBusMenuLayout.build(from: [])
        XCTAssertTrue(layout.node.isWellFormed)
        XCTAssertEqual(layout.node.signature, "(ia{sv}av)")
        XCTAssertTrue(children(of: layout).isEmpty)
        XCTAssertTrue(layout.actions.isEmpty)
    }

    func testActionRowsAreTheOnlyOnesInTheDispatchTable() {
        let items = [
            TrayMenuItem(kind: .quota, title: "codex weekly", detail: "40%"),
            TrayMenuItem(kind: .error, title: "gemini", detail: "not installed", urgency: .critical),
            TrayMenuItem(kind: .separator, title: ""),
            action("Refresh", TrayMenu.refreshActionID),
            action("Quit", TrayMenu.quitActionID),
        ]
        let layout = DBusMenuLayout.build(from: items)
        XCTAssertEqual(layout.actions, [4: TrayMenu.refreshActionID, 5: TrayMenu.quitActionID])
    }

    /// A row that highlights on hover and then does nothing reads as broken, so
    /// readouts are explicitly disabled rather than left at the default.
    func testReadoutRowsAreDisabled() {
        let layout = DBusMenuLayout.build(from: [
            TrayMenuItem(kind: .quota, title: "codex weekly", detail: "40%"),
            TrayMenuItem(kind: .error, title: "gemini", detail: "not installed"),
        ])
        for child in children(of: layout) {
            XCTAssertEqual(properties(of: child)["enabled"], .boolean(false))
        }
    }

    /// `enabled` defaults to true in the spec, so sending it would only make
    /// every message bigger.
    func testAnEnabledActionOmitsTheRedundantEnabledProperty() {
        let layout = DBusMenuLayout.build(from: [action("Refresh", TrayMenu.refreshActionID)])
        let found = properties(of: children(of: layout)[0])
        XCTAssertNil(found["enabled"])
        XCTAssertEqual(found["label"], .string("Refresh"))
    }

    func testADisabledActionIsNeitherEnabledNorDispatchable() {
        let layout = DBusMenuLayout.build(from: [
            action("Refresh", TrayMenu.refreshActionID, enabled: false),
        ])
        XCTAssertEqual(properties(of: children(of: layout)[0])["enabled"], .boolean(false))
        XCTAssertTrue(layout.actions.isEmpty)
    }

    func testSeparatorCarriesOnlyItsType() {
        let layout = DBusMenuLayout.build(from: [TrayMenuItem(kind: .separator, title: "")])
        XCTAssertEqual(properties(of: children(of: layout)[0]), ["type": .string("separator")])
    }

    func testLabelJoinsTitleAndDetail() {
        let layout = DBusMenuLayout.build(from: [
            TrayMenuItem(kind: .quota, title: "codex weekly", detail: "40% · resets in 2d"),
        ])
        XCTAssertEqual(properties(of: children(of: layout)[0])["label"],
                       .string("codex weekly  40% · resets in 2d"))
    }

    func testLabelOmitsTheSeparatorWhenThereIsNoDetail() {
        let layout = DBusMenuLayout.build(from: [action("Quit", TrayMenu.quitActionID)])
        XCTAssertEqual(properties(of: children(of: layout)[0])["label"], .string("Quit"))
    }

    /// dbusmenu reads `_` as a mnemonic marker, so an underscore in a window
    /// label would vanish from the menu and silently claim a keyboard shortcut.
    /// Window names come from CLI output, which AGENTS.md treats as untrusted.
    func testUnderscoresAreDoubledSoTheyRenderLiterally() {
        let layout = DBusMenuLayout.build(from: [
            TrayMenuItem(kind: .quota, title: "gemini_2.5_pro", detail: "10%"),
        ])
        XCTAssertEqual(properties(of: children(of: layout)[0])["label"],
                       .string("gemini__2.5__pro  10%"))
    }

    func testTheRootAdvertisesItselfAsASubmenu() {
        let layout = DBusMenuLayout.build(from: [])
        guard case .struct(let members) = layout.node,
              case .array(_, let entries) = members[1],
              case .dictEntry(let key, let value) = entries.first else {
            return XCTFail("expected root properties")
        }
        XCTAssertEqual(key, .string("children-display"))
        XCTAssertEqual(value, .variant(.string("submenu")))
    }

    /// The layout is built straight from what the tray model already produces,
    /// so a real snapshot has to survive the round trip.
    func testARealSnapshotProducesAWellFormedLayout() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = QuotaSnapshot(provider: .codex,
                                     windows: [QuotaWindow(key: "weekly", label: "Weekly",
                                                           usedPercent: 40, resetAt: nil)],
                                     error: nil,
                                     updatedAt: now)
        let layout = DBusMenuLayout.build(from: TrayMenu.items(for: [snapshot], now: now))
        XCTAssertTrue(layout.node.isWellFormed)
        XCTAssertEqual(Set(layout.actions.values), [TrayMenu.refreshActionID, TrayMenu.quitActionID])
    }
}
