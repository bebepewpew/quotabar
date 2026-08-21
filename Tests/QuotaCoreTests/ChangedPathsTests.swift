import XCTest
import Foundation
import QuotaCore

/// The `changes` job in `.github/workflows/ci.yml` decides whether a pull
/// request holds a macOS runner, a Linux container and CodeQL. Its third bucket
/// — "Not classified, so building" — is a one-shot signal that a path family
/// needs a line in the case statement, so it only says anything while it stays
/// empty for the paths this repository actually contains.
///
/// These tests do not pattern-match on the YAML. They lift the step's `run:`
/// block straight out of it and execute it under `bash` with a stub `git`, so
/// what is asserted is the code GitHub runs. A family left unclassified, or
/// classified into the wrong bucket, fails the suite instead of printing into a
/// log nobody reads.
final class ChangedPathsTests: XCTestCase {
    private var scratch = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-changed-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - The four families that fell through

    /// `Resources/` is the macOS app bundle's payload: `release.yml` stamps the
    /// version into `Info.plist` and reads it back out of the signed app, and
    /// the `quotabar` wrapper copies both the plist and the icon in.
    func testResourcesBuildAndAreClassified() throws {
        for path in ["Resources/Info.plist", "Resources/AppIcon.png", "Resources/AppIcon.icns",
                     "Resources/AppIcon.iconset/icon_16x16@2x.png"] {
            let result = try classify([path])
            XCTAssertTrue(result.code, "\(path) should still ask for the build")
            assertClassified(result, path)
        }
    }

    /// Beside the two Codex scripts it sits next to. Nothing compiles it and the
    /// policy job already asserts it is executable, for every change.
    func testInstallHooksSkipsTheBuild() throws {
        let result = try classify(["scripts/install-hooks"])
        XCTAssertFalse(result.code, "scripts/install-hooks reaches no compiler")
        assertClassified(result, "scripts/install-hooks")
    }

    /// Release inputs. Only `release.yml` reads them, and a macOS build says
    /// nothing about a Dockerfile or an nfpm description.
    func testPackagingAndTheDockerContextSkipTheBuild() throws {
        for path in ["packaging/Dockerfile", "packaging/nfpm.yaml",
                     "packaging/homebrew/quotabar.rb", ".dockerignore"] {
            let result = try classify([path])
            XCTAssertFalse(result.code, "\(path) reaches no compiler")
            assertClassified(result, path)
        }
    }

    /// The families as they exist on disk rather than as a list written here,
    /// so a thirteenth icon or a fourth packaging file is covered the day it
    /// lands instead of the day someone remembers this test.
    func testEveryFileInThoseFamiliesIsClassified() throws {
        var paths = try trackedFiles(under: "Resources") + trackedFiles(under: "packaging")
        paths += ["scripts/install-hooks", ".dockerignore"]
        XCTAssertGreaterThan(paths.count, 4, "the families are empty, so this proves nothing")

        let result = try classify(paths)
        XCTAssertTrue(result.code, "Resources/ is in the change, so the build is needed")
        assertClassified(result, "the packaging, resource and hook families")
    }

    // MARK: - The buckets that were already right

    func testCompiledAndPipelinePathsBuild() throws {
        for path in ["Sources/QuotaCore/CommandRunner.swift", "Tests/QuotaCoreTests/ChangedPathsTests.swift",
                     "Package.swift", "Package.resolved", "quotabar", "scripts/coverage",
                     ".github/workflows/ci.yml"] {
            let result = try classify([path])
            XCTAssertTrue(result.code, "\(path) should ask for the build")
            assertClassified(result, path)
            XCTAssertTrue(result.output.contains(path), "the build reason should name \(path):\n\(result.output)")
        }
    }

    func testProseAndRepositoryFurnitureSkip() throws {
        for path in ["docs/agent-guides/ci-and-delivery.md", ".claude/agents/quotabar-developer.md",
                     ".codex/skills/quotabar-developer/SKILL.md", ".github/ISSUE_TEMPLATE/task.yml",
                     ".githooks/pre-push", "README.md", "LICENSE", ".gitignore", ".gitattributes",
                     "scripts/install-codex-skills", "scripts/codex-parallel",
                     ".github/CODEOWNERS", ".github/dependabot.yml", ".github/release.yml"] {
            let result = try classify([path])
            XCTAssertFalse(result.code, "\(path) reaches no compiler")
            assertClassified(result, path)
        }
    }

    /// The bucket has to keep working, or classifying these four families would
    /// have bought silence rather than a signal.
    func testAnUnrecognisedPathStillBuildsAndNamesItself() throws {
        let result = try classify(["mystery/widget.json"])
        XCTAssertTrue(result.code, "an unknown path builds rather than being guessed away")
        XCTAssertTrue(result.output.contains("Not classified"), "the bucket went quiet:\n\(result.output)")
        XCTAssertTrue(result.output.contains("mystery/widget.json"),
                      "an unclassified path must be named:\n\(result.output)")
    }

    func testOneBuildingPathIsEnoughInAMixedChange() throws {
        let result = try classify(["README.md", "packaging/nfpm.yaml", "Resources/Info.plist"])
        XCTAssertTrue(result.code)
        assertClassified(result, "a mixed change")
    }

    func testAChangeOfOnlySkippedPathsSkips() throws {
        let result = try classify(["docs/container.md", "scripts/install-hooks", "packaging/Dockerfile",
                                   ".dockerignore"])
        XCTAssertFalse(result.code, "nothing in that change compiles")
        assertClassified(result, "a skip-only change")
    }

    // MARK: - Driving the real step

    private func assertClassified(_ result: (code: Bool, output: String), _ subject: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.output.contains("Not classified"),
                       "\(subject) is unclassified; add a line to the case in ci.yml:\n\(result.output)",
                       file: file, line: line)
    }

    /// Runs the workflow step over `paths` and reports the `code` output it
    /// wrote plus everything it printed.
    private func classify(_ paths: [String]) throws -> (code: Bool, output: String) {
        let bash = try systemBinary("bash")
        let script = try Self.stepScript()

        let workspace = scratch.appendingPathComponent(UUID().uuidString)
        let bin = workspace.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let diff = workspace.appendingPathComponent("diff")
        try Data(paths.map { $0 + "\n" }.joined().utf8).write(to: diff)

        // The step's only external command is `git diff --name-only`. A stub
        // that prints the fixture keeps the assertions off this checkout's
        // history — which a linked worktree mounted into the Swift container
        // does not even carry.
        let git = bin.appendingPathComponent("git")
        try Data("#!/bin/sh\nexec cat \(Self.shellQuoted(diff.path))\n".utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

        let outputs = workspace.appendingPathComponent("github-output")
        try Data().write(to: outputs)

        let runner = workspace.appendingPathComponent("run.sh")
        try Data("""
        EVENT=pull_request
        BASE_SHA=0000000000000000000000000000000000000000
        RUNNER_TEMP=\(Self.shellQuoted(workspace.path))
        GITHUB_OUTPUT=\(Self.shellQuoted(outputs.path))
        PATH=\(Self.shellQuoted(bin.path)):$PATH
        export EVENT BASE_SHA RUNNER_TEMP GITHUB_OUTPUT PATH

        \(script)
        """.utf8).write(to: runner)

        let printed = String(decoding: try CommandRunner.run(bash, [runner.path], timeout: 30),
                             as: UTF8.self)
        let recorded = try String(contentsOf: outputs, encoding: .utf8)
        let decision = try XCTUnwrap(recorded.split(whereSeparator: \.isNewline)
                                             .last(where: { $0.hasPrefix("code=") }),
                                     "the step wrote no code= output:\n\(recorded)\n\(printed)")
        XCTAssertTrue(decision == "code=true" || decision == "code=false", "unexpected output \(decision)")
        return (decision == "code=true", printed)
    }

    /// The `run:` block of the "Decide whether the build is needed" step,
    /// dedented so `bash` can execute it as written.
    private static func stepScript() throws -> String {
        let workflow = repositoryRoot.appendingPathComponent(".github/workflows/ci.yml")
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: workflow.path),
                          "ci.yml is not reachable from \(#filePath)")
        let lines = try String(contentsOf: workflow, encoding: .utf8).components(separatedBy: "\n")

        let step = try XCTUnwrap(lines.firstIndex { $0.contains("name: Decide whether the build is needed") },
                                 "the changes job no longer has that step")
        let key = try XCTUnwrap(lines[step...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "run: |" },
                                "that step no longer has a literal run block")
        let keyIndent = indentation(of: lines[key])

        var body: [String] = []
        var bodyIndent: Int?
        for line in lines[(key + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { body.append(""); continue }
            let width = indentation(of: line)
            if width <= keyIndent { break }
            bodyIndent = bodyIndent ?? width
            body.append(String(line.dropFirst(min(bodyIndent ?? width, width))))
        }

        let script = body.joined(separator: "\n")
        XCTAssertTrue(script.contains("unclassified="), "the wrong block was lifted out of ci.yml:\n\(script)")
        return script
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// Single-quoted for `bash`. `CommandRunner.tclQuoted` is the wrong tool —
    /// it quotes for Tcl — and these are paths this test just made, but a string
    /// reaching a shell is still quoted rather than trusted.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Repository-relative paths of the regular files under `directory`.
    private func trackedFiles(under directory: String) throws -> [String] {
        let root = Self.repositoryRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walker.compactMap { entry in
            guard let relative = entry as? String else { return nil }
            var isDirectory: ObjCBool = false
            let full = root.appendingPathComponent(relative).path
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return "\(directory)/\(relative)"
        }.sorted()
    }

    /// The checkout this test was compiled from, found by walking up to the
    /// package manifest rather than trusting the working directory.
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.isReadableFile(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    private func systemBinary(_ name: String) throws -> String {
        let candidates = ["/bin/\(name)", "/usr/bin/\(name)"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("\(name) is not installed at a standard location on this machine")
        }
        return path
    }
}
