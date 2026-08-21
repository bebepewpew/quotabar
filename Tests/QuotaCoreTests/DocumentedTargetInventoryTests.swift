import XCTest
import Foundation

/// Checks the target inventory the documentation states against the one
/// `Package.swift` actually declares.
///
/// `AGENTS.md` is the canonical file a contributor or an agent reads first to
/// decide which target a change belongs in, and the README's Modules table is
/// the same list for someone arriving from GitHub. Both had gone stale: the
/// package grew `QuotaTray` and then `QuotaTrayApp` while the prose still said
/// three targets and named none of them.
///
/// This lives in the test suite rather than the CI policy script deliberately.
/// The regression it catches is *adding or renaming a target*, which always
/// touches `Package.swift` or `Sources/` and therefore always runs the build
/// jobs; a documentation-only change skips them, so a check placed here cannot
/// be the one that guards prose edits alone.
final class DocumentedTargetInventoryTests: XCTestCase {

    /// `#filePath` is the compile-time path of this file, and the suite is
    /// always built from the checkout it tests, so walking up out of
    /// `Tests/QuotaCoreTests/` reaches the repository root on macOS, on Linux
    /// and inside the container the wrapper mounts.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let numberWords = ["zero", "one", "two", "three", "four", "five",
                                      "six", "seven", "eight", "nine", "ten"]

    // MARK: - Helpers

    private func repositoryText(_ name: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws -> String {
        let url = Self.repositoryRoot.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read \(url.path) as UTF-8.", file: file, line: line)
            throw CocoaError(.fileReadNoSuchFile)
        }
        return text
    }

    /// Every target `Package.swift` declares that ships code, in declaration
    /// order. Test targets are excluded: they are not part of the inventory a
    /// contributor chooses between, and nothing installs them.
    ///
    /// The platform-conditional targets are found too, because the manifest is
    /// read as text rather than evaluated — `QuotaBar` exists only on macOS and
    /// `QuotaTrayApp` only on Linux, and the documentation has to name both
    /// whichever host the suite runs on.
    private func declaredShippingTargets(in manifest: String) -> [String] {
        var names: [String] = []
        for line in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.contains(".testTarget(") else { continue }
            for marker in [".target(name: \"", ".executableTarget(name: \""] {
                guard let start = line.range(of: marker),
                      let end = line[start.upperBound...].firstIndex(of: "\"") else { continue }
                names.append(String(line[start.upperBound..<end]))
            }
        }
        return names
    }

    /// The body of a Markdown section, from its heading to the next heading at
    /// the same level or above.
    private func section(_ heading: String, of document: String) -> String? {
        guard let start = document.range(of: heading + "\n") else { return nil }
        let level = heading.prefix(while: { $0 == "#" }).count
        let rest = document[start.upperBound...]
        for candidate in 1...level {
            let terminator = "\n" + String(repeating: "#", count: candidate) + " "
            if let end = rest.range(of: terminator) {
                return String(rest[..<end.lowerBound])
            }
        }
        return String(rest)
    }

    // MARK: - The manifest itself

    func testManifestParsingFindsTheKnownTargets() throws {
        let targets = declaredShippingTargets(in: try repositoryText("Package.swift"))

        // A sanity check on the parser, not a fourth copy of the inventory: if
        // this ever fails the reader below is looking at nothing and the
        // documentation checks would pass vacuously.
        XCTAssertTrue(targets.contains("QuotaCore"),
                      "Parsed \(targets) out of Package.swift, which does not look like this package.")
        XCTAssertTrue(targets.contains("QuotaBarCLI"),
                      "Parsed \(targets) out of Package.swift, which does not look like this package.")
        XCTAssertFalse(targets.contains { $0.hasSuffix("Tests") },
                       "Test targets are not part of the shipped inventory: \(targets).")
    }

    // MARK: - AGENTS.md

    func testAgentsProjectSectionNamesEveryTarget() throws {
        let targets = declaredShippingTargets(in: try repositoryText("Package.swift"))
        let agents = try repositoryText("AGENTS.md")
        let project = try XCTUnwrap(section("## Project", of: agents),
                                    "AGENTS.md no longer has a `## Project` section.")

        for target in targets {
            XCTAssertTrue(project.contains("`\(target)`"),
                          """
                          AGENTS.md's Project section does not name `\(target)`, which Package.swift \
                          declares. It is the first file every contributor and agent reads to decide \
                          which target a change belongs in, so the inventory has to be complete.
                          """)
        }
    }

    func testAgentsProjectSectionStatesTheRightTargetCount() throws {
        let targets = declaredShippingTargets(in: try repositoryText("Package.swift"))
        let agents = try repositoryText("AGENTS.md")
        let project = try XCTUnwrap(section("## Project", of: agents),
                                    "AGENTS.md no longer has a `## Project` section.")

        XCTAssertTrue(targets.count < Self.numberWords.count,
                      "Extend numberWords: the package now has \(targets.count) targets.")
        let expected = Self.numberWords[targets.count]
        XCTAssertTrue(project.contains("\(expected) targets"),
                      """
                      AGENTS.md's Project section should say "\(expected) targets"; Package.swift \
                      declares \(targets.count): \(targets.joined(separator: ", ")).
                      """)

        for (count, word) in Self.numberWords.enumerated() where count != targets.count {
            XCTAssertFalse(project.contains("\(word) targets"),
                           """
                           AGENTS.md's Project section says "\(word) targets" but Package.swift \
                           declares \(targets.count). A per-platform subset needs wording that does \
                           not read as the total.
                           """)
        }
    }

    // MARK: - README.md

    func testReadmeModulesTableHasARowForEveryTarget() throws {
        let targets = declaredShippingTargets(in: try repositoryText("Package.swift"))
        let readme = try repositoryText("README.md")
        let modules = try XCTUnwrap(section("### Modules", of: readme),
                                    "README.md no longer has a `### Modules` section.")

        for target in targets {
            let row = modules
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first { $0.hasPrefix("| `\(target)` |") }
            guard let row else {
                XCTFail("""
                        README.md's Modules table has no row for `\(target)`, which Package.swift \
                        declares.
                        """)
                continue
            }

            // "| `Name` | Platforms | What it is |" splits into an empty leading
            // cell, three filled ones, and an empty trailing cell.
            let cells = row.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(cells.count, 5, "Malformed Modules row for `\(target)`: \(row)")
            XCTAssertFalse(cells.dropFirst().prefix(3).contains(where: \.isEmpty),
                           "The Modules row for `\(target)` leaves a cell empty: \(row)")
        }
    }
}
