import Foundation

/// The tray's command line.
///
/// Parsed as a value so the rules are tested rather than trusted — the
/// executable itself is the one part of the tray a test cannot drive.
public struct TrayArguments: Equatable, Sendable {
    /// Seconds between refreshes.
    public var interval: TimeInterval
    public var help: Bool
    public var version: Bool
    /// Write the systemd user unit and exit.
    public var installAutostart: Bool
    /// Remove it and exit.
    public var removeAutostart: Bool
    /// Anything the parser did not recognise, reported rather than ignored.
    public var unknown: [String]

    public init(interval: TimeInterval = TrayArguments.defaultInterval,
                help: Bool = false, version: Bool = false,
                installAutostart: Bool = false, removeAutostart: Bool = false,
                unknown: [String] = []) {
        self.interval = interval
        self.help = help
        self.version = version
        self.installAutostart = installAutostart
        self.removeAutostart = removeAutostart
        self.unknown = unknown
    }

    /// Fifteen minutes. Every refresh spawns provider CLIs, one of which drives
    /// a pseudo-terminal, so the default is deliberately unhurried.
    public static let defaultInterval: TimeInterval = 900

    /// Bounds, for the same reason the CLI bounds its own interval: a tray that
    /// probes every second is a fork bomb with a nice icon, and one that probes
    /// once a week is not a monitor.
    public static let minimumInterval: TimeInterval = 30
    public static let maximumInterval: TimeInterval = 86_400

    public static let version = "0.1.0"

    public static let usage = """
        quotabar-tray — QuotaBar as a StatusNotifierItem tray icon

        USAGE
          quotabar-tray [options]

        OPTIONS
          --interval <seconds>   Seconds between refreshes (default 900,
                                 clamped to 30…86400)
          --install-autostart    Write the systemd user unit and exit
          --remove-autostart     Remove the systemd user unit and exit
          --version              Print the version and exit
          --help                 Print this message and exit

        The tray needs a session bus with a StatusNotifierWatcher on it. KDE
        Plasma provides one; on GNOME it comes from the AppIndicator extension.
        The `quotabar` command needs neither and works anywhere.
        """

    public static func parse(_ arguments: [String]) -> TrayArguments {
        var parsed = TrayArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                parsed.help = true
            case "--version":
                parsed.version = true
            case "--install-autostart":
                parsed.installAutostart = true
            case "--remove-autostart":
                parsed.removeAutostart = true
            case "--interval":
                index += 1
                guard index < arguments.count, let seconds = Double(arguments[index]),
                      seconds.isFinite else {
                    // A bad value is not silently the default: that hides a typo
                    // behind behaviour that looks deliberate.
                    parsed.unknown.append("--interval needs a number of seconds")
                    index += 1
                    continue
                }
                parsed.interval = clamp(seconds)
            default:
                parsed.unknown.append(argument)
            }
            index += 1
        }
        return parsed
    }

    /// Clamped rather than rejected: an out-of-range interval is a preference
    /// stated badly, not a reason to refuse to start.
    public static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, minimumInterval), maximumInterval)
    }
}
