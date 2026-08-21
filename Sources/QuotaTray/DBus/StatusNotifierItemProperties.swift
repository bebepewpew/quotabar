import Foundation
import QuotaCore

/// The `org.kde.StatusNotifierItem` properties, as plain values.
///
/// Plasma reads these over D-Bus; nothing here talks to a bus, so the whole
/// mapping from quota state to what the user sees in the system tray is testable
/// without a session. `StatusNotifierItem` is a freedesktop protocol that KDE,
/// and via libayatana-appindicator most other trays, already implement — so
/// serving it directly costs a few hundred lines of marshalling instead of
/// linking libdbus or pulling in GTK.
public enum StatusNotifierItemProperties {
    /// The tray reports the state of an application, not hardware or a
    /// conversation, which is what the spec's `ApplicationStatus` means.
    public static let category = "ApplicationStatus"
    /// Stable across restarts: trays key their "position in the tray" memory and
    /// any per-item user config off this, so it must not carry a version or pid.
    public static let identifier = "quotabar"
    public static let title = "QuotaBar"
    /// Where the dbusmenu lives on our own connection.
    public static let menuPath = "/MenuBar"

    /// `Status`. `NeedsAttention` is what makes a tray surface an item the user
    /// has collapsed into the overflow, so it is reserved for a quota that is
    /// actually close to running out rather than used for any warning.
    /// A quota with no reading yet contributes nothing rather than counting as
    /// `.normal`: a failed probe must not be able to clear an attention state
    /// that a still-readable window is asserting.
    public static func status(for quotas: [MenuBarQuota]) -> String {
        let urgencies = quotas.compactMap { $0.usedPercent.map(QuotaUrgency.init(usedPercent:)) }
        let worst = urgencies.max(by: { severity($0) < severity($1) }) ?? .normal
        return worst == .critical ? "NeedsAttention" : "Active"
    }

    private static func severity(_ urgency: QuotaUrgency) -> Int {
        switch urgency {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    /// One `(width, height, ARGB32)` entry for `IconPixmap`.
    ///
    /// The spec's pixel format is ARGB32 in **network byte order**, which is
    /// big-endian — so the bytes run A, R, G, B regardless of the host. Getting
    /// this wrong does not fail, it just renders the icon with the channels
    /// rotated, which is why the conversion is its own tested function rather
    /// than a loop inside the transport.
    public static func pixmap(_ bitmap: TrayBitmap) -> DBusValue {
        var argb = [UInt8]()
        argb.reserveCapacity(bitmap.pixels.count)
        var index = 0
        while index + 3 < bitmap.pixels.count {
            let r = bitmap.pixels[index]
            let g = bitmap.pixels[index + 1]
            let b = bitmap.pixels[index + 2]
            let a = bitmap.pixels[index + 3]
            argb.append(contentsOf: [a, r, g, b])
            index += 4
        }
        return .struct([.int32(Int32(bitmap.width)), .int32(Int32(bitmap.height)), .bytes(argb)])
    }

    /// `IconPixmap` — `a(iiay)`.
    ///
    /// A tray may pick whichever size suits its panel, so the spec takes an array
    /// of sizes. One entry is legal and is what a renderer that draws at a single
    /// size should send; an empty array is also legal and means "no pixmap", which
    /// is the honest answer before the first refresh completes.
    public static func iconPixmap(_ bitmaps: [TrayBitmap]) -> DBusValue {
        .array(element: "(iiay)", values: bitmaps.map(pixmap))
    }

    /// `ToolTip` — `(sa(iiay)ss)`: icon name, icon pixmaps, title, description.
    ///
    /// The description is Plasma-side markup, so anything drawn from CLI output
    /// is escaped. `AGENTS.md` treats provider output as untrusted, and a window
    /// label containing `<b>` would otherwise reformat the user's tooltip.
    public static func toolTip(title: String, lines: [String]) -> DBusValue {
        .struct([
            .string(""),
            .array(element: "(iiay)", values: []),
            .string(escapeMarkup(title)),
            .string(lines.map(escapeMarkup).joined(separator: "\n")),
        ])
    }

    /// Escapes the five XML entities Plasma's rich-text tooltip would otherwise
    /// interpret. `&` first, or it would double-escape the others.
    public static func escapeMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Everything `org.freedesktop.DBus.Properties.GetAll` should return.
    ///
    /// `ItemIsMenu` is false: a left click should refresh rather than open the
    /// menu, and a tray that believes the item *is* a menu never sends `Activate`.
    public static func all(quotas: [MenuBarQuota],
                          bitmaps: [TrayBitmap],
                          toolTipLines: [String]) -> DBusValue {
        .dictionary([
            "Category": .string(category),
            "Id": .string(identifier),
            "Title": .string(title),
            "Status": .string(status(for: quotas)),
            "IconName": .string(""),
            "IconPixmap": iconPixmap(bitmaps),
            "OverlayIconName": .string(""),
            "AttentionIconName": .string(""),
            "ItemIsMenu": .boolean(false),
            "Menu": .objectPath(menuPath),
            "ToolTip": toolTip(title: title, lines: toolTipLines),
        ])
    }
}
