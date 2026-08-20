import Foundation
import XCTest
@testable import QuotaTray
import QuotaCore

/// Stands in for `systemctl`. Nothing here starts a process, so the suite is safe
/// on a build machine that has no systemd, no session bus, and no desktop.
private final class RecordingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []
    private let failure: Error?

    init(failure: Error? = nil) { self.failure = failure }

    var calls: [[String]] { lock.withLock { storage } }

    var runner: TrayAutostart.Runner {
        { [self] arguments in
            lock.withLock { storage.append(arguments) }
            if let failure { throw failure }
        }
    }
}

private struct RunnerFailure: Error {}

final class TrayAutostartTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-autostart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        try super.tearDownWithError()
    }

    // MARK: - Unit text

    func testUnitTextStartsWithTheDesktopSessionAndRestartsOnFailure() {
        let text = TrayAutostart.unitText(execPath: "/usr/local/bin/quotabar")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertTrue(lines.contains("[Unit]"))
        XCTAssertTrue(lines.contains("[Service]"))
        XCTAssertTrue(lines.contains("[Install]"))
        XCTAssertTrue(lines.contains("Type=simple"))
        XCTAssertTrue(lines.contains(#"ExecStart="/usr/local/bin/quotabar""#))
        XCTAssertTrue(lines.contains("Restart=on-failure"))
        XCTAssertTrue(lines.contains("RestartSec=5"))

        // A user unit belongs to a desktop session, not to the machine.
        XCTAssertTrue(lines.contains("WantedBy=default.target"))
        XCTAssertFalse(text.contains("multi-user.target"))
        XCTAssertTrue(lines.contains("After=graphical-session.target"))
        XCTAssertTrue(lines.contains("PartOf=graphical-session.target"))

        // WantedBy has to be under [Install]; systemd ignores it anywhere else.
        if let install = lines.firstIndex(of: "[Install]"),
           let wantedBy = lines.firstIndex(of: "WantedBy=default.target") {
            XCTAssertGreaterThan(wantedBy, install)
        } else {
            XCTFail("expected a [Install] section containing WantedBy=default.target")
        }

        XCTAssertTrue(text.hasSuffix("\n"), "unit files end with a newline")
    }

    func testUnitTextQuotesPathsThatCouldOtherwiseEndTheDirective() {
        let hostile = "/home/a b/\"quota\"\nExecStartPost=/bin/rm -rf ~\n/bar%h\\baz"
        let text = TrayAutostart.unitText(execPath: hostile)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let execStart = lines.filter { $0.hasPrefix("ExecStart") }
        XCTAssertEqual(execStart.count, 1, "the whole path stays on one line")
        XCTAssertEqual(execStart.first,
                       #"ExecStart="/home/a b/\"quota\"\nExecStartPost=/bin/rm -rf ~\n/bar%%h\\baz""#)
        XCTAssertFalse(lines.contains { $0.hasPrefix("ExecStartPost=") })
    }

    // MARK: - Unit location

    func testUnitURLUsesXDGConfigHomeWhenSet() {
        let url = TrayAutostart.unitURL(environment: ["XDG_CONFIG_HOME": "/xdg/config"],
                                        home: URL(fileURLWithPath: "/home/tester", isDirectory: true))
        XCTAssertEqual(url.path, "/xdg/config/systemd/user/quotabar-tray.service")
    }

    func testUnitURLFallsBackToDotConfigWhenXDGConfigHomeIsUnsetOrEmpty() {
        let home = URL(fileURLWithPath: "/home/tester", isDirectory: true)
        let expected = "/home/tester/.config/systemd/user/quotabar-tray.service"

        XCTAssertEqual(TrayAutostart.unitURL(environment: [:], home: home).path, expected)
        XCTAssertEqual(TrayAutostart.unitURL(environment: ["XDG_CONFIG_HOME": ""], home: home).path, expected)
        // Unrelated variables must not be mistaken for it.
        XCTAssertEqual(TrayAutostart.unitURL(environment: ["XDG_DATA_HOME": "/xdg/data"], home: home).path, expected)
    }

    func testUnitURLIgnoresTheRealMachine() {
        let url = TrayAutostart.unitURL(environment: ["XDG_CONFIG_HOME": "/xdg/config"],
                                        home: URL(fileURLWithPath: "/home/tester", isDirectory: true))
        let real = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(url.path.hasPrefix(real), "resolution came from the injected values, not \(real)")
        XCTAssertEqual(url.lastPathComponent, TrayAutostart.unitName)
    }

    // MARK: - Install and remove

    func testInstallWritesTheUnitAndEnablesItThroughTheRunner() throws {
        let recorder = RecordingRunner()
        let url = try TrayAutostart.install(execPath: "/usr/local/bin/quotabar",
                                            environment: [:], home: home, runner: recorder.runner)

        XCTAssertEqual(url, TrayAutostart.unitURL(environment: [:], home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       TrayAutostart.unitText(execPath: "/usr/local/bin/quotabar"))
        XCTAssertTrue(TrayAutostart.isInstalled(environment: [:], home: home))

        XCTAssertEqual(recorder.calls, [["--user", "daemon-reload"],
                                        ["--user", "enable", "--now", "quotabar-tray.service"]])
    }

    func testInstallHonoursXDGConfigHome() throws {
        let recorder = RecordingRunner()
        let xdg = home.appendingPathComponent("elsewhere", isDirectory: true)
        let url = try TrayAutostart.install(execPath: "/usr/local/bin/quotabar",
                                            environment: ["XDG_CONFIG_HOME": xdg.path],
                                            home: home, runner: recorder.runner)

        XCTAssertEqual(url.path, xdg.appendingPathComponent("systemd/user/quotabar-tray.service").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".config/systemd/user/quotabar-tray.service").path))
    }

    func testInstallOverwritesAnExistingUnit() throws {
        let recorder = RecordingRunner()
        try TrayAutostart.install(execPath: "/old/quotabar", environment: [:], home: home, runner: recorder.runner)
        let url = try TrayAutostart.install(execPath: "/new/quotabar", environment: [:], home: home,
                                            runner: recorder.runner)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       TrayAutostart.unitText(execPath: "/new/quotabar"))
        XCTAssertEqual(recorder.calls.count, 4)
    }

    func testRemoveDisablesTheUnitThenDeletesIt() throws {
        let installer = RecordingRunner()
        let url = try TrayAutostart.install(execPath: "/usr/local/bin/quotabar",
                                            environment: [:], home: home, runner: installer.runner)

        let recorder = RecordingRunner()
        let removed = try TrayAutostart.remove(environment: [:], home: home, runner: recorder.runner)

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(TrayAutostart.isInstalled(environment: [:], home: home))
        XCTAssertEqual(recorder.calls, [["--user", "disable", "--now", "quotabar-tray.service"],
                                        ["--user", "daemon-reload"]])
    }

    func testRemoveWithNothingInstalledLeavesTheRunnerAlone() throws {
        let recorder = RecordingRunner()
        let removed = try TrayAutostart.remove(environment: [:], home: home, runner: recorder.runner)

        XCTAssertFalse(removed)
        XCTAssertEqual(recorder.calls, [])
    }

    func testRemoveKeepsTheUnitWhenDisablingFails() throws {
        let url = try TrayAutostart.install(execPath: "/usr/local/bin/quotabar", environment: [:],
                                            home: home, runner: RecordingRunner().runner)

        let recorder = RecordingRunner(failure: RunnerFailure())
        XCTAssertThrowsError(try TrayAutostart.remove(environment: [:], home: home, runner: recorder.runner))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a failed disable must not leave systemd enabled with no unit file")
        XCTAssertEqual(recorder.calls, [["--user", "disable", "--now", "quotabar-tray.service"]])
    }

    func testIsInstalledIsFalseBeforeAnythingIsWritten() {
        XCTAssertFalse(TrayAutostart.isInstalled(environment: [:], home: home))
    }
}
