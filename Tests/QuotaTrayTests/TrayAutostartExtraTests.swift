import Foundation
import XCTest
@testable import QuotaTray
import QuotaCore

/// A `systemctl` stand-in that fails on one nominated call, so a partly applied
/// install can be inspected. Like the recorder in `TrayAutostartTests`, nothing
/// here starts a process.
private final class ScriptedRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []
    private let failingCall: Int

    /// `failingCall` is 1-based: 1 fails `daemon-reload`, 2 fails `enable`.
    init(failingCall: Int) { self.failingCall = failingCall }

    var calls: [[String]] { lock.withLock { storage } }

    var runner: TrayAutostart.Runner {
        { [self] arguments in
            let call = lock.withLock { () -> Int in
                storage.append(arguments)
                return storage.count
            }
            if call == failingCall { throw ScriptedFailure() }
        }
    }
}

private struct ScriptedFailure: Error {}

/// Records what discovery was asked for without touching the machine's PATH.
private final class LocateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let result: String?

    init(result: String?) { self.result = result }

    var names: [String] { lock.withLock { storage } }

    var locate: @Sendable (String) -> String? {
        { [self] name in
            lock.withLock { storage.append(name) }
            return result
        }
    }
}

/// The branches `TrayAutostartTests` leaves alone: escapes no path in that suite
/// contains, an install whose `systemctl` call fails part way through, and the
/// production runner's "systemctl is not installed" answer.
final class TrayAutostartExtraTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-autostart-extra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        try super.tearDownWithError()
    }

    // MARK: - Unit text

    /// A tab or a carriage return in the path is as capable of ending the
    /// `ExecStart=` line as the newline the sibling suite covers: systemd treats
    /// a bare CR as a line ending, and a tab would split the command.
    func testUnitTextEscapesTabsAndCarriageReturns() {
        let text = TrayAutostart.unitText(execPath: "/home/a\tb/quota\rbar")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let execStart = lines.filter { $0.hasPrefix("ExecStart") }
        XCTAssertEqual(execStart.count, 1, "the whole path stays on one line")
        XCTAssertEqual(execStart.first, #"ExecStart="/home/a\tb/quota\rbar""#)

        // The escapes are two characters each; no control character survives into
        // the unit, where it could end the directive.
        XCTAssertFalse(text.unicodeScalars.contains("\r"))
        XCTAssertFalse(text.unicodeScalars.contains("\t"))
    }

    // MARK: - Install failures

    /// `install` writes the unit before it talks to systemd, and a failing call
    /// stops the sequence there. The file is deliberately left behind: re-running
    /// install is the documented repair, and it overwrites.
    func testInstallStopsAtTheFailingSystemctlCallAndKeepsTheWrittenUnit() throws {
        let expected = [["--user", "daemon-reload"],
                        ["--user", "enable", "--now", TrayAutostart.unitName]]

        for failingCall in 1...2 {
            // A home of its own per attempt, so the second one starts with nothing
            // installed rather than inheriting the first one's unit.
            let sandbox = home.appendingPathComponent("attempt-\(failingCall)", isDirectory: true)
            let runner = ScriptedRunner(failingCall: failingCall)

            XCTAssertThrowsError(try TrayAutostart.install(execPath: "/usr/local/bin/quotabar",
                                                          environment: [:], home: sandbox,
                                                          runner: runner.runner)) { error in
                XCTAssertTrue(error is ScriptedFailure, "the runner's error reaches the caller, got \(error)")
            }

            let url = TrayAutostart.unitURL(environment: [:], home: sandbox)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                           TrayAutostart.unitText(execPath: "/usr/local/bin/quotabar"))
            XCTAssertTrue(TrayAutostart.isInstalled(environment: [:], home: sandbox))
            XCTAssertEqual(runner.calls, Array(expected.prefix(failingCall)),
                           "nothing is attempted after call \(failingCall) fails")
        }
    }

    // MARK: - The production runner

    /// The real runner's own lookup: with no `systemctl` to find it reports the
    /// binary as missing and never reaches `CommandRunner.run`.
    func testSystemctlRunnerReportsSystemctlMissingWithoutStartingAnything() {
        let recorder = LocateRecorder(result: nil)
        let runner = TrayAutostart.makeSystemctlRunner(locate: recorder.locate)

        XCTAssertThrowsError(try runner(["--user", "daemon-reload"])) { error in
            guard case .missing(let name)? = error as? ProbeError else {
                return XCTFail("expected ProbeError.missing, got \(error)")
            }
            XCTAssertEqual(name, "systemctl")
            XCTAssertEqual((error as? ProbeError)?.errorDescription, "systemctl is not installed")
        }

        // Looked up by bare name, so PATH and the explicit install locations both
        // apply — not hard-coded to one of them.
        XCTAssertEqual(recorder.names, ["systemctl"])
    }
}
