import Foundation

/// The Linux answer to `LoginItemManager`: a systemd **user** unit, so the tray
/// starts with the desktop session rather than the machine.
public enum TrayAutostart {
    public static let unitName = "quotabar-tray.service"

    /// Contents of the unit that launches `execPath`.
    public static func unitText(execPath: String) -> String {
        // TODO(task 3: autostart)
        ""
    }

    /// `${XDG_CONFIG_HOME:-~/.config}/systemd/user/quotabar-tray.service`.
    /// The environment and home are injected so tests never depend on the
    /// machine they run on.
    public static func unitURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        // TODO(task 3: autostart)
        home
    }
}
