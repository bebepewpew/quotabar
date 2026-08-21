import Foundation
import QuotaCore

/// The Linux answer to `LoginItemManager`: a systemd **user** unit, so the tray
/// starts with the desktop session rather than the machine.
public enum TrayAutostart {
    public static let unitName = "quotabar-tray.service"

    /// The arguments handed to `systemctl`, `--user` included, so the whole
    /// invocation is visible at the seam and a test can assert on it. This is the
    /// only place `install`/`remove` would start a process, so injecting a
    /// recorder keeps the suite from ever shelling out.
    public typealias Runner = @Sendable (_ arguments: [String]) throws -> Void

    /// Contents of the unit that launches `execPath`.
    public static func unitText(execPath: String) -> String {
        """
        [Unit]
        Description=QuotaBar quota tray icon
        # The tray needs the session bus and a StatusNotifierItem host, so it is
        # ordered after the graphical session and stops together with it.
        PartOf=graphical-session.target
        After=graphical-session.target

        [Service]
        Type=simple
        ExecStart=\(quoted(execPath))
        Restart=on-failure
        RestartSec=5

        [Install]
        # default.target, not the system-wide boot target: this is a user unit and
        # starts with one person's desktop session, never with the machine.
        WantedBy=default.target

        """
    }

    /// `${XDG_CONFIG_HOME:-~/.config}/systemd/user/quotabar-tray.service`.
    /// The environment and home are injected so tests never depend on the
    /// machine they run on.
    public static func unitURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        // Same rule as `JSONFileStateStore.defaultURL()`, so both files land under
        // the same configuration root.
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("systemd", isDirectory: true)
            .appendingPathComponent("user", isDirectory: true)
            .appendingPathComponent(unitName)
    }

    /// Whether a unit file is already in place.
    public static func isInstalled(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: unitURL(environment: environment, home: home).path)
    }

    /// Writes the unit and enables it for the current user. Returns where it was
    /// written. Overwrites an existing unit, so re-running after the executable
    /// moves is the repair.
    @discardableResult
    public static func install(execPath: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               fileManager: FileManager = .default,
                               runner: Runner = TrayAutostart.systemctlRunner) throws -> URL {
        let url = unitURL(environment: environment, home: home)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(unitText(execPath: execPath).utf8).write(to: url, options: .atomic)
        try runner(["--user", "daemon-reload"])
        try runner(["--user", "enable", "--now", unitName])
        return url
    }

    /// Disables the unit and deletes it, reporting whether there was one. Nothing
    /// installed means nothing to disable, so `runner` is left alone rather than
    /// asked to fail on a unit systemd has never heard of.
    @discardableResult
    public static func remove(environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              fileManager: FileManager = .default,
                              runner: Runner = TrayAutostart.systemctlRunner) throws -> Bool {
        let url = unitURL(environment: environment, home: home)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        // Disable while the unit file is still readable; systemd needs it to work
        // out which symlinks to undo.
        try runner(["--user", "disable", "--now", unitName])
        try fileManager.removeItem(at: url)
        try runner(["--user", "daemon-reload"])
        return true
    }

    /// The production runner. `CommandRunner` bounds the child by a deadline and
    /// gives it its own process group, so a hung `systemctl` cannot outlive us.
    public static let systemctlRunner: Runner = makeSystemctlRunner(locate: CommandRunner.find)

    /// The body of `systemctlRunner`, with binary discovery injected. A machine
    /// running the suite usually does have a real `systemctl`, so the
    /// "not installed" answer is only reachable — and only assertable — through
    /// this seam, and asserting it here never starts a process.
    static func makeSystemctlRunner(locate: @escaping @Sendable (String) -> String?) -> Runner {
        { arguments in
            guard let executable = locate("systemctl") else {
                throw ProbeError.missing("systemctl")
            }
            _ = try CommandRunner.run(executable, arguments, timeout: 10)
        }
    }

    /// systemd's own quoting. An unquoted path with a space would split into an
    /// executable plus arguments, and a newline in one would end the `ExecStart=`
    /// line entirely — letting anything after it become a directive of its own. A
    /// bare `%` is a specifier prefix and has to be doubled to survive.
    static func quoted(_ path: String) -> String {
        var escaped = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "%": escaped += "%%"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}
