import XCTest
import Foundation
@testable import QuotaTray
import QuotaCore

final class StatusNotifierItemPropertiesTests: XCTestCase {
    private func quota(_ provider: Provider, _ used: Double?) -> MenuBarQuota {
        MenuBarQuota(selection: QuotaSelection(provider: provider, windowKey: "w", windowLabel: "W"),
                     usedPercent: used,
                     badge: "")
    }

    // MARK: Status

    func testStatusIsActiveWithNothingToReport() {
        XCTAssertEqual(StatusNotifierItemProperties.status(for: []), "Active")
    }

    func testStatusIsActiveBelowTheCriticalThreshold() {
        XCTAssertEqual(StatusNotifierItemProperties.status(for: [quota(.codex, 94.9)]), "Active")
    }

    /// `NeedsAttention` is what pulls an item out of a tray's overflow, so it is
    /// reserved for a quota that is genuinely nearly spent.
    func testStatusNeedsAttentionAtTheCriticalThreshold() {
        XCTAssertEqual(StatusNotifierItemProperties.status(for: [quota(.codex, 95)]), "NeedsAttention")
    }

    func testTheWorstQuotaDecidesTheStatus() {
        let quotas = [quota(.codex, 10), quota(.claude, 99), quota(.gemini, 50)]
        XCTAssertEqual(StatusNotifierItemProperties.status(for: quotas), "NeedsAttention")
    }

    /// A provider that failed has no reading. It must not be able to talk the
    /// item down from NeedsAttention that another window is still asserting.
    func testAQuotaWithNoReadingCannotClearAnAttentionState() {
        XCTAssertEqual(StatusNotifierItemProperties.status(for: [quota(.codex, nil), quota(.claude, 99)]),
                       "NeedsAttention")
        XCTAssertEqual(StatusNotifierItemProperties.status(for: [quota(.codex, nil)]), "Active")
    }

    // MARK: IconPixmap

    /// The spec is ARGB32 in network byte order, so the bytes run A, R, G, B —
    /// getting this wrong renders with rotated channels rather than failing.
    func testPixmapConvertsRGBAToARGBInNetworkByteOrder() {
        let bitmap = TrayBitmap(width: 1, height: 1, pixels: [0x11, 0x22, 0x33, 0x44])
        guard case .struct(let members) = StatusNotifierItemProperties.pixmap(bitmap),
              members.count == 3,
              case .array(_, let bytes) = members[2] else {
            return XCTFail("expected (ii ay)")
        }
        XCTAssertEqual(members[0], .int32(1))
        XCTAssertEqual(members[1], .int32(1))
        XCTAssertEqual(bytes, [.byte(0x44), .byte(0x11), .byte(0x22), .byte(0x33)])
    }

    func testPixmapCarriesEveryPixelAndItsDimensions() {
        let bitmap = TrayIcon.rasterise([quota(.codex, 50)], size: 8)
        guard case .struct(let members) = StatusNotifierItemProperties.pixmap(bitmap),
              case .array(_, let bytes) = members[2] else {
            return XCTFail("expected (ii ay)")
        }
        XCTAssertEqual(members[0], .int32(8))
        XCTAssertEqual(members[1], .int32(8))
        XCTAssertEqual(bytes.count, 8 * 8 * 4)
    }

    func testPixmapSignatureMatchesTheSpec() {
        let pixmap = StatusNotifierItemProperties.pixmap(TrayBitmap(width: 1, height: 1))
        XCTAssertEqual(pixmap.signature, "(iiay)")
        XCTAssertTrue(pixmap.isWellFormed)
    }

    /// Legal, and the honest state before the first refresh returns.
    func testIconPixmapWithNoBitmapsIsStillTypedCorrectly() {
        let icon = StatusNotifierItemProperties.iconPixmap([])
        XCTAssertEqual(icon.signature, "a(iiay)")
        XCTAssertTrue(icon.isWellFormed)
    }

    func testIconPixmapAcceptsSeveralSizes() {
        let icon = StatusNotifierItemProperties.iconPixmap([
            TrayBitmap(width: 16, height: 16), TrayBitmap(width: 22, height: 22),
        ])
        guard case .array(_, let values) = icon else { return XCTFail("expected an array") }
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(icon.isWellFormed)
    }

    // MARK: ToolTip

    func testToolTipSignatureMatchesTheSpec() {
        let tip = StatusNotifierItemProperties.toolTip(title: "QuotaBar", lines: ["a", "b"])
        XCTAssertEqual(tip.signature, "(sa(iiay)ss)")
        XCTAssertTrue(tip.isWellFormed)
    }

    func testToolTipJoinsItsLines() {
        guard case .struct(let members) = StatusNotifierItemProperties
                .toolTip(title: "T", lines: ["one", "two"]) else {
            return XCTFail("expected a struct")
        }
        XCTAssertEqual(members[3], .string("one\ntwo"))
    }

    /// AGENTS.md treats provider output as untrusted, and the description is
    /// rendered as markup, so a window label cannot be allowed to carry tags.
    func testToolTipEscapesMarkupComingFromProviderOutput() {
        guard case .struct(let members) = StatusNotifierItemProperties
                .toolTip(title: "<b>T</b>", lines: ["5 & 6 <script>"]) else {
            return XCTFail("expected a struct")
        }
        XCTAssertEqual(members[2], .string("&lt;b&gt;T&lt;/b&gt;"))
        XCTAssertEqual(members[3], .string("5 &amp; 6 &lt;script&gt;"))
    }

    /// The ampersand has to be replaced first, or every other entity gets its
    /// own `&` escaped a second time.
    func testEscapingAnAmpersandDoesNotDoubleEscapeTheRest() {
        XCTAssertEqual(StatusNotifierItemProperties.escapeMarkup("&<>\"'"),
                       "&amp;&lt;&gt;&quot;&apos;")
        XCTAssertEqual(StatusNotifierItemProperties.escapeMarkup("plain"), "plain")
    }

    // MARK: GetAll

    func testAllCarriesEveryPropertyATrayReads() {
        let all = StatusNotifierItemProperties.all(quotas: [quota(.codex, 10)],
                                                   bitmaps: [TrayBitmap(width: 22, height: 22)],
                                                   toolTipLines: ["codex 10%"])
        guard case .array(let element, let entries) = all else {
            return XCTFail("expected a{sv}")
        }
        XCTAssertEqual(element, "{sv}")
        let names = Set(entries.compactMap { entry -> String? in
            guard case .dictEntry(let key, _) = entry, case .string(let name) = key else { return nil }
            return name
        })
        XCTAssertEqual(names, [
            "Category", "Id", "Title", "Status", "IconName", "IconPixmap",
            "OverlayIconName", "AttentionIconName", "ItemIsMenu", "Menu", "ToolTip",
        ])
        XCTAssertTrue(all.isWellFormed)
    }

    /// A tray that believes the item *is* a menu never sends `Activate`, so a
    /// left click would stop refreshing.
    func testItemIsNotAMenuSoALeftClickReachesTheApplication() {
        let all = StatusNotifierItemProperties.all(quotas: [], bitmaps: [], toolTipLines: [])
        XCTAssertEqual(value(named: "ItemIsMenu", in: all), .boolean(false))
        XCTAssertEqual(value(named: "Menu", in: all), .objectPath("/MenuBar"))
    }

    /// Trays key their remembered tray position off `Id`, so it must not carry a
    /// version or a pid.
    func testIdentityIsStableAcrossRuns() {
        XCTAssertEqual(StatusNotifierItemProperties.identifier, "quotabar")
        XCTAssertEqual(StatusNotifierItemProperties.category, "ApplicationStatus")
    }

    private func value(named name: String, in dictionary: DBusValue) -> DBusValue? {
        guard case .array(_, let entries) = dictionary else { return nil }
        for entry in entries {
            guard case .dictEntry(let key, let value) = entry,
                  case .string(let found) = key, found == name,
                  case .variant(let inner) = value else { continue }
            return inner
        }
        return nil
    }
}
