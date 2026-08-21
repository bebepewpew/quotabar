import Foundation
import QuotaCore

/// Turns snapshots into everything a tray can see.
///
/// Here rather than in the executable so it is tested: this is the step that
/// decides which quotas reach the icon, what the tooltip says, and what the menu
/// offers. The executable is left with the socket and the clock.
public enum TrayStateBuilder {
    /// The tray icon draws at one size. A tray scales what it is given, and
    /// sending several costs a redraw per refresh for no visible difference.
    public static let iconSize = 22

    public static func make(snapshots: [QuotaSnapshot],
                            selections: [QuotaSelection],
                            revision: UInt32,
                            now: Date = Date()) -> TrayState {
        let quotas = menuBarQuotas(snapshots: snapshots, selections: selections)
        return TrayState(quotas: quotas,
                         bitmaps: [TrayIcon.rasterise(quotas, size: iconSize)],
                         toolTipLines: toolTipLines(snapshots: snapshots, now: now),
                         menu: DBusMenuLayout.build(from: TrayMenu.items(for: snapshots, now: now)),
                         revision: revision)
    }

    /// One entry per selection, in the order the user chose them.
    ///
    /// A selection whose window is missing keeps its place with no reading
    /// rather than being dropped: the icon must not silently reorder itself
    /// because one provider failed.
    public static func menuBarQuotas(snapshots: [QuotaSnapshot],
                                     selections: [QuotaSelection]) -> [MenuBarQuota] {
        selections.map { selection in
            let window = snapshots.first { $0.provider == selection.provider }?
                .windows.first { $0.key == selection.windowKey || $0.label == selection.windowLabel }
            return MenuBarQuota(selection: selection,
                                usedPercent: window?.usedPercent,
                                badge: QuotaBadge.preferred(for: selection))
        }
    }

    /// The tooltip lists every window, not only the selected ones — it is the
    /// place with room, and a user who selected two of five still wants the
    /// other three on hover.
    public static func toolTipLines(snapshots: [QuotaSnapshot], now: Date = Date()) -> [String] {
        let rows = QuotaFormatting.rows(for: snapshots, now: now)
        guard !rows.isEmpty else {
            // Never empty: a tooltip with no text renders as a stray empty box.
            return ["No provider CLI reported a quota."]
        }
        return rows.map { row in
            var line = "\(row.provider.rawValue) \(row.window)  \(row.percentText)"
            if !row.resetText.isEmpty { line += "  \(row.resetText)" }
            if let error = row.error, !error.isEmpty { line += "  — \(error)" }
            return line
        }
    }

    /// dbusmenu revisions must strictly increase, and 0 is reserved, so this
    /// wraps to 1. A tray only refetches when it sees a number it has not seen.
    public static func nextRevision(after revision: UInt32) -> UInt32 {
        revision == UInt32.max ? 1 : revision + 1
    }
}
