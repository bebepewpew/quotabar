import XCTest
import Foundation

/// The release workflow's shell, executed rather than eyeballed.
///
/// Two steps in `.github/workflows/release.yml` decide what happens when a
/// release run failed *after* its tag was pushed: the `version` job, which must
/// refuse to bump from a tag whose release never published, and the tag step in
/// the `release` job, which must treat its own re-run as a no-op so that failed
/// run can be resumed. Both are shell that no Swift code calls, so these tests
/// lift each `run:` block straight out of the workflow and execute it under bash
/// with `git` and `gh` stubbed onto `PATH`. Nothing here touches the network, a
/// real repository, or the machine's own git configuration.
final class ReleaseWorkflowTests: XCTestCase {
    private var scratch = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-release-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - version: the next version, and the release that has to exist first

    func testDerivesTheNextPatchWhenThePreviousReleaseWasPublished() throws {
        let run = try runVersionStep(bump: "patch", tags: ["v0.2.0"], published: ["v0.2.0"])

        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertEqual(run.outputs["version"], "0.2.1")
        XCTAssertEqual(run.outputs["tag"], "v0.2.1")
        XCTAssertEqual(run.outputs["previous"], "v0.2.0")
    }

    func testDerivesTheNextMinorAndMajorFromTheSameTag() throws {
        let minor = try runVersionStep(bump: "minor", tags: ["v0.2.3"], published: ["v0.2.3"])
        XCTAssertEqual(minor.status, 0, minor.output)
        XCTAssertEqual(minor.outputs["tag"], "v0.3.0")

        let major = try runVersionStep(bump: "major", tags: ["v0.2.3"], published: ["v0.2.3"])
        XCTAssertEqual(major.status, 0, major.output)
        XCTAssertEqual(major.outputs["tag"], "v1.0.0")
    }

    /// The bug this file exists for. A run that pushed `v0.2.0` and then failed
    /// leaves the tag with no release behind it; dispatching `patch` again used
    /// to cut `v0.2.1` on top, leave `v0.2.0` half-released, and hand the new
    /// version an empty changelog.
    func testRefusesToBumpFromATagWhoseReleaseNeverPublished() throws {
        let run = try runVersionStep(bump: "patch", tags: ["v0.2.0"], published: [])

        XCTAssertNotEqual(run.status, 0, "a tag with no published release must stop the run")
        XCTAssertTrue(run.output.contains("v0.2.0 is tagged but has no published GitHub release"),
                      run.output)
        // The named recovery, on one line so it is quotable from the log.
        XCTAssertTrue(run.output.contains("\"Re-run failed jobs\""), run.output)
        XCTAssertTrue(run.outputs.isEmpty, "no version may be published from a half-released tag")
    }

    /// `gh release view` succeeds for a draft, so asking only whether the lookup
    /// worked would wave one through. A draft is not published.
    func testRefusesToBumpFromATagWhoseReleaseIsStillADraft() throws {
        let run = try runVersionStep(bump: "patch", tags: ["v0.2.0"], published: [], drafts: ["v0.2.0"])

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("no published GitHub release"), run.output)
        XCTAssertTrue(run.outputs.isEmpty)
    }

    /// The first release of all: there is no previous tag, so there is nothing
    /// to ask GitHub about and the guard must not invent a lookup.
    func testStartsAtTheFirstVersionWithoutLookingForAPreviousRelease() throws {
        let run = try runVersionStep(bump: "patch", tags: [], published: [])

        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertEqual(run.outputs["tag"], "v0.1.0")
        XCTAssertEqual(run.outputs["previous"], "")
        XCTAssertFalse(run.calls.contains { $0.hasPrefix("gh ") }, run.calls.joined(separator: "\n"))
    }

    /// Pre-existing behaviour, kept: the tags come back sorted `-v:refname`, so
    /// a prerelease sorts above the plain version and stops the run instead of
    /// being bumped from silently.
    func testRefusesAPrereleaseTagOnTop() throws {
        let run = try runVersionStep(bump: "patch", tags: ["v1.0.0-rc.1", "v0.9.0"], published: ["v0.9.0"])

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("is not a plain vMAJOR.MINOR.PATCH tag"), run.output)
        XCTAssertFalse(run.calls.contains { $0.hasPrefix("gh ") },
                       "a tag that cannot be parsed is not worth a release lookup")
    }

    /// Pre-existing behaviour, kept: the stub answers `git tag --list` in the
    /// order it is given, so this pins the duplicate-tag guard rather than the
    /// sort in front of it.
    func testRefusesToCutAVersionThatIsAlreadyTagged() throws {
        let run = try runVersionStep(bump: "patch", tags: ["v0.2.0", "v0.2.1"], published: ["v0.2.0"])

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("tag v0.2.1 already exists"), run.output)
        XCTAssertTrue(run.outputs.isEmpty)
    }

    func testRejectsABumpTheDispatchInputShouldNeverCarry() throws {
        let run = try runVersionStep(bump: "patch; touch owned", tags: ["v0.2.0"], published: ["v0.2.0"])

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("unsupported bump"), run.output)
        XCTAssertTrue(run.calls.isEmpty, "an unsupported bump reaches neither git nor gh")
    }

    // MARK: - release: tagging, and re-running the job that already tagged

    func testCreatesAndPushesTheTagWhenItDoesNotExistYet() throws {
        let run = try runTagStep(remoteTag: nil)

        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertTrue(run.calls.contains { $0.hasPrefix("git tag -a v0.2.0 ") }, run.calls.joined(separator: "\n"))
        XCTAssertTrue(run.calls.contains("git push origin refs/tags/v0.2.0"), run.calls.joined(separator: "\n"))
    }

    /// Resuming a release with "Re-run failed jobs" replays this step against a
    /// tag that is already pushed. It has to be a proven no-op: creating the tag
    /// again produces a second annotated object, and pushing that is rejected.
    func testLeavesATagThatAlreadyPointsAtTheReleasedCommitAlone() throws {
        let run = try runTagStep(remoteTag: "v0.2.0", remoteSHA: "abc123")

        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("already points at abc123"), run.output)
        XCTAssertFalse(run.calls.contains { $0.hasPrefix("git tag ") }, run.calls.joined(separator: "\n"))
        XCTAssertFalse(run.calls.contains { $0.hasPrefix("git push ") }, run.calls.joined(separator: "\n"))
    }

    /// A tag that moved is not this run's to reconcile: signatures and
    /// provenance are bound to the commit it named.
    func testRefusesATagThatResolvesToAnotherCommit() throws {
        let run = try runTagStep(remoteTag: "v0.2.0", remoteSHA: "0ther00")

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("v0.2.0 already resolves to 0ther00"), run.output)
        XCTAssertFalse(run.calls.contains { $0.hasPrefix("git push ") }, run.calls.joined(separator: "\n"))
    }

    func testRefusesToTagADirtyCheckout() throws {
        let run = try runTagStep(remoteTag: nil, dirty: " M Sources/QuotaCore/Models.swift")

        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("refusing to tag a dirty checkout"), run.output)
        XCTAssertFalse(run.calls.contains { $0.hasPrefix("git push ") }, run.calls.joined(separator: "\n"))
        XCTAssertFalse(run.calls.contains { $0.hasPrefix("git ls-remote ") },
                       "a dirty checkout is refused before anything reaches the network")
    }

    // MARK: - Driving a workflow step

    private struct StepRun {
        /// stdout and stderr together, the way the job log interleaves them.
        let output: String
        let status: Int32
        /// One line per stubbed `git`/`gh` invocation, in order.
        let calls: [String]
        /// Whatever the step appended to `$GITHUB_OUTPUT`.
        let outputs: [String: String]
    }

    private func runVersionStep(bump: String,
                                tags: [String],
                                published: [String],
                                drafts: [String] = [],
                                file: StaticString = #filePath,
                                line: UInt = #line) throws -> StepRun {
        let outputFile = scratch.appendingPathComponent("github-output")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        return try runStep(named: "Derive the next semantic version",
                           environment: [
                               "BUMP": bump,
                               "GITHUB_OUTPUT": outputFile.path,
                               "GITHUB_REPOSITORY": "bebepewpew/quotabar",
                               "GH_TOKEN": "stub-token",
                               "STUB_TAGS": tags.joined(separator: "\n"),
                               "STUB_PUBLISHED": published.joined(separator: " "),
                               "STUB_DRAFTS": drafts.joined(separator: " ")
                           ],
                           outputFile: outputFile,
                           file: file,
                           line: line)
    }

    private func runTagStep(remoteTag: String?,
                            remoteSHA: String = "abc123",
                            dirty: String = "",
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> StepRun {
        try runStep(named: "Create the annotated tag",
                    environment: [
                        "TAG": "v0.2.0",
                        "VERSION": "0.2.0",
                        "GITHUB_SHA": "abc123",
                        "GITHUB_REPOSITORY": "bebepewpew/quotabar",
                        "STUB_REMOTE_TAG": remoteTag ?? "",
                        "STUB_REMOTE_SHA": remoteSHA,
                        "STUB_DIRTY": dirty
                    ],
                    outputFile: nil,
                    file: file,
                    line: line)
    }

    private func runStep(named name: String,
                         environment: [String: String],
                         outputFile: URL?,
                         file: StaticString,
                         line: UInt) throws -> StepRun {
        let bash = try bashPath()
        let script = scratch.appendingPathComponent("step.sh")
        try Data(try runBlock(ofStepNamed: name, file: file, line: line).utf8).write(to: script)

        let binDirectory = scratch.appendingPathComponent("bin")
        try install(Self.gitStub, as: "git", in: binDirectory)
        try install(Self.ghStub, as: "gh", in: binDirectory)
        let log = scratch.appendingPathComponent("calls")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        var childEnvironment = environment
        childEnvironment["STUB_LOG"] = log.path
        childEnvironment["HOME"] = scratch.path
        // The stubs shadow `git` and `gh`; the rest of PATH is only there for
        // the POSIX tools the step itself runs, `grep` and `cut`.
        childEnvironment["PATH"] = "\(binDirectory.path):/usr/bin:/bin"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bash)
        process.arguments = [script.path]
        process.environment = childEnvironment
        process.currentDirectoryURL = scratch
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let recorded = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var outputs: [String: String] = [:]
        if let outputFile, let written = try? String(contentsOf: outputFile, encoding: .utf8) {
            for entry in written.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let separator = entry.firstIndex(of: "=") else { continue }
                outputs[String(entry[entry.startIndex..<separator])] = String(entry[entry.index(after: separator)...])
            }
        }
        return StepRun(output: String(decoding: data, as: UTF8.self),
                       status: process.terminationStatus,
                       calls: recorded,
                       outputs: outputs)
    }

    // MARK: - Reading the workflow

    /// Lifts a step's literal `run: |` block out of the workflow and undents it.
    /// Deliberately not a YAML parse: the point is to execute the exact text the
    /// runner would, and a step that has been renamed or reshaped should fail
    /// here loudly rather than quietly stop being covered.
    private func runBlock(ofStepNamed name: String, file: StaticString, line: UInt) throws -> String {
        let root = URL(fileURLWithPath: #filePath)      // Tests/QuotaCoreTests/<this file>
            .deletingLastPathComponent()                // Tests/QuotaCoreTests
            .deletingLastPathComponent()                // Tests
            .deletingLastPathComponent()                // the checkout
        let workflow = root.appendingPathComponent(".github/workflows/release.yml")
        let source = try XCTUnwrap(try? String(contentsOf: workflow, encoding: .utf8),
                                   "no release workflow at \(workflow.path)",
                                   file: file, line: line)

        let lines = source.components(separatedBy: "\n")
        let header = "- name: \(name)"
        let start = try XCTUnwrap(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == header },
                                  "release.yml has no step named \(name)",
                                  file: file, line: line)
        let runLine = try XCTUnwrap(lines[start...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "run: |" },
                                    "the step \(name) no longer holds a literal run block",
                                    file: file, line: line)
        let indent = lines[runLine].prefix { $0 == " " }.count

        var body: [String] = []
        for text in lines[(runLine + 1)...] {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                body.append("")
                continue
            }
            guard text.prefix(while: { $0 == " " }).count > indent else { break }
            body.append(String(text.dropFirst(indent + 2)))
        }
        return body.joined(separator: "\n") + "\n"
    }

    // MARK: - Stubs

    /// Answers the four things the two steps ask git, and records every call.
    /// `STUB_TAGS` comes back in the order it was given, so a test decides what
    /// `--sort=-v:refname` would have produced.
    private static let gitStub = """
    #!/bin/sh
    printf 'git %s\\n' "$*" >> "$STUB_LOG"
    case "$1" in
      tag)
        if [ "$2" = "--list" ]; then
          if [ -n "${STUB_TAGS:-}" ]; then printf '%s\\n' "$STUB_TAGS"; fi
        fi
        exit 0
        ;;
      rev-parse)
        wanted="${4#refs/tags/}"
        for tag in ${STUB_TAGS:-}; do
          if [ "$tag" = "$wanted" ]; then exit 0; fi
        done
        exit 1
        ;;
      status)
        if [ -n "${STUB_DIRTY:-}" ]; then printf '%s\\n' "$STUB_DIRTY"; fi
        exit 0
        ;;
      ls-remote)
        wanted="${3%^\\{\\}}"
        wanted="${wanted#refs/tags/}"
        if [ -n "${STUB_REMOTE_TAG:-}" ] && [ "$wanted" = "$STUB_REMOTE_TAG" ]; then
          printf '%s\\trefs/tags/%s^{}\\n' "$STUB_REMOTE_SHA" "$wanted"
        fi
        exit 0
        ;;
    esac
    exit 0
    """

    /// `gh release view <tag> --json isDraft --jq .isDraft`: `false` for a
    /// published release, `true` for a draft, and gh's own failure for a tag
    /// with no release at all.
    private static let ghStub = """
    #!/bin/sh
    printf 'gh %s\\n' "$*" >> "$STUB_LOG"
    if [ "$1" = "release" ] && [ "$2" = "view" ]; then
      for tag in ${STUB_PUBLISHED:-}; do
        if [ "$tag" = "$3" ]; then echo false; exit 0; fi
      done
      for tag in ${STUB_DRAFTS:-}; do
        if [ "$tag" = "$3" ]; then echo true; exit 0; fi
      done
      echo "release not found" >&2
      exit 1
    fi
    echo "unexpected gh invocation: $*" >&2
    exit 1
    """

    private func install(_ contents: String, as name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data((contents + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func bashPath() throws -> String {
        let candidates = ["/bin/bash", "/usr/bin/bash"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("bash is not installed at a standard location on this machine")
        }
        return path
    }
}
