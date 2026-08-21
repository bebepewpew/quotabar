import XCTest
@testable import QuotaCore

/// Everywhere else the suite asserts the *text* of the Gemini expect script.
/// These run it.
///
/// The property the script exists for — that Enter is never pressed on a slash
/// command until Gemini has proved its command registry is loaded — is a
/// property of running it, and reading the script instead is how the bug
/// survived. The stand-in below is faithful exactly where the script looks: raw
/// keystrokes, a composer placeholder that paints long before the registry is
/// ready, a suggestion row only the loaded registry can render, and the two
/// views the parser reads. Whether the registry is loaded is a function of the
/// clock rather than of what has been typed, so Enter arriving early spends a
/// model turn the way the real CLI does.
///
/// `expect` is not in the Linux test container, so these skip there and run on
/// macOS, where it ships with the system.
final class GeminiExpectScriptTests: XCTestCase {
    private var scratch = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-gemini-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A registry that finishes loading well after the composer has painted is
    /// the ordinary slow start, and it has to end in a reading rather than in a
    /// prompt sent to the model.
    func testRunsBothCommandsOnceTheRegistryHasLoaded() throws {
        let stub = try stubCLI(registryDelayMilliseconds: 1_500)
        let transcript = try SystemProbeRunner().runExpect(GeminiTerminalProbe.expectScript(binary: stub.path),
                                                          timeout: 60, currentDirectory: nil)

        XCTAssertFalse(transcript.contains("STUB_SPENT_A_MODEL_TURN"),
                       "the script submitted a command the registry had not registered:\n\(transcript)")
        XCTAssertTrue(transcript.contains("STUB_RAN_STATS"), "/stats never ran:\n\(transcript)")
        XCTAssertTrue(transcript.contains("STUB_RAN_MODEL"), "/model never ran:\n\(transcript)")
        XCTAssertNil(GeminiTerminalProbe.failure(in: transcript))

        let snapshot = try GeminiTerminalProbe.parse(transcript, now: Date())
        XCTAssertEqual(snapshot.windows.map(\.label), ["Flash", "Pro"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 1])
    }

    /// The registry never loads. The script has to give up without pressing
    /// Enter: a refresh that reports why costs the user nothing, and a refresh
    /// that spends a model turn costs them the quota it went to measure.
    func testSpendsNoModelTurnWhenTheRegistryNeverLoads() throws {
        let stub = try stubCLI(registryDelayMilliseconds: 0, everLoads: false)
        let transcript = try SystemProbeRunner().runExpect(GeminiTerminalProbe.expectScript(binary: stub.path),
                                                          timeout: 60, currentDirectory: nil)

        XCTAssertFalse(transcript.contains("STUB_SPENT_A_MODEL_TURN"),
                       "the script pressed Enter with no proof the command would run:\n\(transcript)")
        XCTAssertTrue(transcript.contains("QUOTABAR_NOT_READY"), "the script gave no reason:\n\(transcript)")
        XCTAssertEqual(GeminiTerminalProbe.failure(in: transcript)?.errorDescription,
                       "Gemini had not loaded its slash commands yet, so QuotaBar stopped instead of sending /stats to the model. Refresh again in a moment.")
    }

    /// A Gemini CLI that behaves like the real one where the probe looks.
    private func stubCLI(registryDelayMilliseconds delay: Int, everLoads: Bool = true) throws -> URL {
        guard let expect = CommandRunner.find("expect") else {
            throw XCTSkip("expect is not installed, so the script cannot be run here")
        }
        let url = scratch.appendingPathComponent("gemini")
        try stub(expect: expect, delay: delay, everLoads: everLoads).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func stub(expect: String, delay: Int, everLoads: Bool) -> String {
        // Raw, so every backslash below belongs to Tcl rather than to Swift.
        #"""
        #!\#(expect) -f
        catch {exec stty raw -echo <@stdin}
        fconfigure stdout -buffering none -translation binary
        fconfigure stdin -blocking 0 -buffering none -translation binary
        set ready_at [expr {[clock milliseconds] + \#(delay)}]
        set ever_loads \#(everLoads ? 1 : 0)
        proc emit {text} { puts -nonewline "$text\r\n" }
        proc loaded {} {
            global ready_at ever_loads
            if {!$ever_loads} { return 0 }
            return [expr {[clock milliseconds] >= $ready_at}]
        }
        proc describe {command} {
            if {$command eq "/stats"} { return "Check session stats. Usage: /stats \[session|model|tools\]" }
            return "Manage model configuration"
        }
        emit "Gemini CLI 0.43.0"
        emit "Type your message or @path/to/file"
        set typed ""
        set shown ""
        while {1} {
            if {[eof stdin]} { exit 0 }
            set c [read stdin 1]
            if {$c eq ""} {
                # Nothing waiting. Paint the suggestion row if the registry has
                # loaded since the command was typed, the way a redraw would.
                foreach command {/stats /model} {
                    if {[string match "*$command" $typed] && $shown ne $command && [loaded]} {
                        set shown $command
                        emit "$command   [describe $command]"
                    }
                }
                after 20
                continue
            }
            if {$c eq "\003"} { exit 0 }
            if {$c ne "\r" && $c ne "\n"} {
                append typed $c
                continue
            }
            # Enter. handleSlashCommand only runs the command once the registry
            # is loaded; before that the text goes to the model as a prompt.
            if {![loaded]} {
                emit "STUB_SPENT_A_MODEL_TURN"
            } elseif {[string match "*/stats*" $typed]} {
                emit "STUB_RAN_STATS"
                emit "Session Stats"
                emit "Interaction Summary"
                emit "Type your message or @path/to/file"
            } elseif {[string match "*/model*" $typed]} {
                emit "STUB_RAN_MODEL"
                emit "Model usage"
                emit "Flash ~~~~~ 0% Resets: 10:05 AM (16h 18m)"
                emit "Pro ~~~~~ 1% Resets: 10:01 AM (16h 14m)"
                emit "(Press Esc to close)"
            } else {
                emit "STUB_SPENT_A_MODEL_TURN"
            }
            set typed ""
            set shown ""
        }
        """#
    }
}
