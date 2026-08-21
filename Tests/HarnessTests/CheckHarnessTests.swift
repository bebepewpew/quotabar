import XCTest
import Foundation

/// `scripts/check-harness` is the gate that fails a pull request which drops a
/// guide a wrapper points at, or lands half a role. Every defect it looks for is
/// otherwise silent — `scripts/install-codex-skills` copies whole directories,
/// so a skill missing its manifest installs perfectly and never surfaces — so
/// the check is only worth having if it genuinely goes red, which is what these
/// tests assert: a synthetic harness that passes, then the same harness with one
/// piece removed each time.
final class CheckHarnessTests: XCTestCase {
    /// The checkout this test was compiled from. `#filePath` is the only handle
    /// on it that does not depend on the working directory the suite is run in.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/HarnessTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    private static var script: URL { repositoryRoot.appendingPathComponent("scripts/check-harness") }

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-check-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        try super.tearDownWithError()
    }

    // MARK: - The repository itself

    func testScriptIsExecutable() {
        // The macOS policy job asserts this with `test -x`; losing the bit is a
        // one-character diff nobody reviews, and the script then cannot run.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.script.path),
                      "scripts/check-harness must stay executable")
    }

    func testThisRepositoryPassesTheCheck() throws {
        let result = try runCheck(on: Self.repositoryRoot)
        XCTAssertEqual(result.status, 0,
                       "the harness in this checkout drifted:\n\(result.errorOutput)")
        XCTAssertTrue(result.output.contains("structurally consistent"), result.output)
    }

    func testPolicyJobRunsTheCheck() throws {
        // A green suite proves the script works, not that anything runs it. This
        // is the wire between the two: without a line in the policy job, a
        // harness-only pull request reaches no job that would notice.
        let workflow = try String(contentsOf: Self.repositoryRoot
            .appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let commands = workflow.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(commands.contains("test -x scripts/check-harness"),
                      "the policy job must assert scripts/check-harness is executable")
        XCTAssertTrue(commands.contains("scripts/check-harness"),
                      "the policy job must run scripts/check-harness")
    }

    // MARK: - A synthetic harness

    func testCleanHarnessIsAccepted() throws {
        let root = try makeHarness()
        let result = try runCheck(on: root)
        XCTAssertEqual(result.status, 0, result.errorOutput)
    }

    func testMissingGuideIsReportedByPath() throws {
        let root = try makeHarness()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("docs/agent-guides/example-guide.md"))

        let result = try runCheck(on: root)
        XCTAssertEqual(result.status, 1, result.errorOutput)
        XCTAssertTrue(result.errorOutput.contains("missing guide: docs/agent-guides/example-guide.md"),
                      result.errorOutput)
    }

    func testCodexSkillWithoutItsManifestIsReportedByRole() throws {
        let root = try makeHarness()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(".codex/skills/quotabar-example/agents/openai.yaml"))

        let result = try runCheck(on: root)
        XCTAssertEqual(result.status, 1, result.errorOutput)
        XCTAssertTrue(result.errorOutput.contains("no manifest: quotabar-example"),
                      result.errorOutput)
    }

    func testAgentWithoutACodexSkillIsReportedByRole() throws {
        let root = try makeHarness()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(".codex/skills/quotabar-example"))

        let result = try runCheck(on: root)
        XCTAssertEqual(result.status, 1, result.errorOutput)
        XCTAssertTrue(result.errorOutput.contains("no Codex skill: quotabar-example"),
                      result.errorOutput)
    }

    func testRoleMissingFromTheRosterIsReported() throws {
        let root = try makeHarness()
        try "Only `quotabar-tool` is listed here.\n"
            .write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let result = try runCheck(on: root)
        XCTAssertEqual(result.status, 1, result.errorOutput)
        XCTAssertTrue(result.errorOutput.contains("not in the AGENTS.md roster: quotabar-example"),
                      result.errorOutput)
    }

    func testASkillWithoutAnAgentTwinStaysQuiet() throws {
        // `quotabar-dev` and `quotabar-fixtures` are skills, not roles, so the
        // asymmetry is deliberate and the check must not invent work for it.
        let root = try makeHarness()
        let result = try runCheck(on: root)
        XCTAssertEqual(result.status, 0, result.errorOutput)
        XCTAssertFalse(result.errorOutput.contains("quotabar-tool"), result.errorOutput)
    }

    func testEveryProblemIsReportedNotJustTheFirst() throws {
        let root = try makeHarness()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("docs/agent-guides/example-guide.md"))
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(".codex/skills/quotabar-tool/agents/openai.yaml"))

        let result = try runCheck(on: root)
        XCTAssertEqual(result.status, 1, result.errorOutput)
        XCTAssertTrue(result.errorOutput.contains("missing guide: docs/agent-guides/example-guide.md"),
                      result.errorOutput)
        XCTAssertTrue(result.errorOutput.contains("no manifest: quotabar-tool"), result.errorOutput)
        XCTAssertTrue(result.errorOutput.contains("2 structural problem(s)"), result.errorOutput)
    }

    func testAWorktreeParkedInsideTheHarnessIsIgnored() throws {
        // The parallel runners drop throwaway checkouts in `.claude/worktrees`.
        // A stale branch there references guides of its own, and must not fail
        // the tree it was cut from.
        let root = try makeHarness()
        let stale = root.appendingPathComponent(".claude/worktrees/wf-1/.claude/agents")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try "Read docs/agent-guides/deleted-guide.md first.\n"
            .write(to: stale.appendingPathComponent("quotabar-ghost.md"),
                   atomically: true, encoding: .utf8)

        let result = try runCheck(on: root)
        XCTAssertEqual(result.status, 0, result.errorOutput)
    }

    func testATreeThatIsNotACheckoutIsRefusedRatherThanFailed() throws {
        // Exit 2, not 1: "I could not check this" must not read as "the harness
        // is broken", or running the gate from the wrong directory looks like
        // drift in every role at once.
        let result = try runCheck(on: scratch)
        XCTAssertEqual(result.status, 2, result.errorOutput)
        XCTAssertTrue(result.errorOutput.contains("no AGENTS.md"), result.errorOutput)
    }

    // MARK: - Helpers

    /// The smallest tree the check considers a harness: one role present on both
    /// sides with its manifest and a roster line, one Codex-only skill, and one
    /// guide referenced by full path from a wrapper.
    private func makeHarness() throws -> URL {
        let root = scratch.appendingPathComponent("harness-\(UUID().uuidString)")
        let files: [String: String] = [
            "AGENTS.md": "Roles: `quotabar-example`. Skills: `quotabar-tool`.\n",
            "docs/agent-guides/example-guide.md": "The guide.\n",
            ".claude/agents/quotabar-example.md": "Read docs/agent-guides/example-guide.md first.\n",
            ".codex/skills/quotabar-example/SKILL.md": "Read docs/agent-guides/example-guide.md first.\n",
            ".codex/skills/quotabar-example/agents/openai.yaml": "name: quotabar-example\n",
            ".codex/skills/quotabar-tool/SKILL.md": "A skill, not a role.\n",
            ".codex/skills/quotabar-tool/agents/openai.yaml": "name: quotabar-tool\n"
        ]
        for (path, contents) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private struct CheckResult {
        var status: Int32
        var output: String
        var errorOutput: String
    }

    /// Runs the script against `root`. Output goes to files rather than pipes:
    /// nothing here needs to interleave with the child, and a file cannot fill
    /// up and wedge it.
    private func runCheck(on root: URL) throws -> CheckResult {
        let outPath = scratch.appendingPathComponent("stdout-\(UUID().uuidString)")
        let errPath = scratch.appendingPathComponent("stderr-\(UUID().uuidString)")
        for path in [outPath, errPath] {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }

        let outHandle = try FileHandle(forWritingTo: outPath)
        let errHandle = try FileHandle(forWritingTo: errPath)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = Self.script
        process.arguments = [root.path]
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()

        return CheckResult(status: process.terminationStatus,
                           output: (try? String(contentsOf: outPath, encoding: .utf8)) ?? "",
                           errorOutput: (try? String(contentsOf: errPath, encoding: .utf8)) ?? "")
    }
}
