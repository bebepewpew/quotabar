import XCTest
import Foundation

/// The container build recipe in `docs/container.md` is documentation that gets
/// executed rather than read: someone pastes the block into a shell. It shipped
/// once in a form that could not work — it offered `./quotabar build`, which
/// passes SwiftPM no configuration and so writes `.build/debug/`, and then
/// copied `.build/release/quotabar` into the image context.
///
/// No compiled code can catch that, so it is checked here: the guide has to list
/// the same commands `packaging/Dockerfile` records, and it has to build the
/// configuration it copies from. The checks read the two files rather than
/// hard-coding the recipe, so a deliberate change to it stays a one-line edit.
final class PackagingDocsTests: XCTestCase {

    // MARK: - The checks

    /// Acceptance: the guide and the Dockerfile list the same commands.
    func testGuideRecipeListsTheSameCommandsAsTheDockerfile() throws {
        let guide = try buildRecipeFromGuide()
        let dockerfile = try buildRecipeFromDockerfile()

        // A parse that silently found nothing would make every other assertion
        // here vacuous, so the shape is asserted before the contents.
        XCTAssertEqual(guide.count, 3, "docs/container.md recipe: \(guide)")
        XCTAssertEqual(dockerfile.count, 3, "packaging/Dockerfile recipe: \(dockerfile)")
        XCTAssertEqual(guide, dockerfile,
                       "docs/container.md and packaging/Dockerfile must list the same commands")
    }

    /// Acceptance: running the block top to bottom produces `dist/quotabar`.
    /// A copy out of `.build/release/` needs a build that selected release;
    /// SwiftPM's default is debug, which is exactly the bug this guards.
    func testGuideRecipeBuildsTheConfigurationItCopiesFrom() throws {
        let recipe = try buildRecipeFromGuide()
        let copied = Set(recipe.flatMap(buildConfigurationsReferenced(by:)))
        XCTAssertEqual(copied, ["release"],
                       "the recipe should stage the release binary: \(recipe)")

        let builds = recipe.filter(isBuildCommand)
        XCTAssertFalse(builds.isEmpty, "the recipe builds nothing: \(recipe)")
        for build in builds {
            let configuration = selectedConfiguration(of: build) ?? "debug"
            XCTAssertTrue(copied.contains(configuration),
                          "`\(build)` builds \(configuration), but the recipe copies from "
                            + copied.sorted().map { ".build/\($0)/" }.joined(separator: ", "))
        }
    }

    /// Acceptance: a `./quotabar` alternative carries the release flags or is
    /// gone. The wrapper's `build` action forwards its arguments unchanged and
    /// adds none, so without them it is a debug build.
    func testEveryWrapperBuildInTheGuideAsksForAStaticReleaseBuild() throws {
        let guide = collapsingWhitespace(in: try contents(of: "docs/container.md"))
        let invocations = guide.components(separatedBy: "./quotabar build").dropFirst()
        for rest in invocations {
            XCTAssertTrue(rest.hasPrefix(" -c release --static-swift-stdlib"),
                          "`./quotabar build` in docs/container.md must carry "
                            + "`-c release --static-swift-stdlib`, but is followed by "
                            + "`\(rest.prefix(40))`")
        }
    }

    // MARK: - Reading the two files

    private func contents(of relativePath: String) throws -> String {
        // #filePath is Tests/QuotaCoreTests/<this file> inside the checkout.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        let data = try XCTUnwrap(FileManager.default.contents(atPath: url.path),
                                 "cannot read \(url.path)")
        return String(decoding: data, as: UTF8.self)
    }

    /// The `$ `-prefixed lines of the first console block under
    /// "## Building it yourself".
    private func buildRecipeFromGuide() throws -> [String] {
        let lines = try contents(of: "docs/container.md").components(separatedBy: "\n")
        let heading = try XCTUnwrap(lines.firstIndex(of: "## Building it yourself"),
                                    "docs/container.md lost its build section")
        let fence = try XCTUnwrap(lines[heading...].firstIndex { $0.hasPrefix("```console") },
                                  "the build section has no console block")

        var commands: [String] = []
        for line in lines[(fence + 1)...] {
            if line.hasPrefix("```") { return commands }
            if line.hasPrefix("$ ") { commands.append(command(from: String(line.dropFirst(2)))) }
        }
        XCTFail("the console block after \"## Building it yourself\" is unterminated")
        return commands
    }

    /// The indented commands in the Dockerfile comment that records the recipe.
    private func buildRecipeFromDockerfile() throws -> [String] {
        let lines = try contents(of: "packaging/Dockerfile").components(separatedBy: "\n")
        let marker = try XCTUnwrap(
            lines.firstIndex { $0.hasPrefix("# Build with the staged binary as the context") },
            "packaging/Dockerfile no longer records the recipe")

        var commands: [String] = []
        for line in lines[(marker + 1)...] {
            // The blank comment lines around the block are `#` on its own.
            if line == "#" { if commands.isEmpty { continue } else { break } }
            guard line.hasPrefix("#   ") else { break }
            commands.append(command(from: String(line.dropFirst(1))))
        }
        return commands
    }

    // MARK: - Reading one command

    /// One shell command with its indentation and any trailing prose comment
    /// removed. A comment is only recognised after two spaces, so the `#` of a
    /// command's own argument would survive.
    private func command(from line: String) -> String {
        var text = line
        if let comment = text.range(of: "  #") { text = String(text[..<comment.lowerBound]) }
        return collapsingWhitespace(in: text).trimmingCharacters(in: .whitespaces)
    }

    private func collapsingWhitespace(in text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func isBuildCommand(_ command: String) -> Bool {
        command.contains("swift build") || command.contains("./quotabar build")
    }

    /// Every `.build/<configuration>/` a command names.
    private func buildConfigurationsReferenced(by command: String) -> [String] {
        command.components(separatedBy: ".build/").dropFirst().compactMap {
            $0.split(separator: "/").first.map(String.init)
        }
    }

    /// The configuration a build command selects, or `nil` for SwiftPM's
    /// default. The wrapper forwards these through untouched.
    private func selectedConfiguration(of command: String) -> String? {
        let words = command.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated()
        where word == "-c" || word == "--configuration" {
            if index + 1 < words.count { return words[index + 1] }
        }
        if let inline = words.first(where: { $0.hasPrefix("--configuration=") }) {
            return String(inline.dropFirst("--configuration=".count))
        }
        return nil
    }
}
