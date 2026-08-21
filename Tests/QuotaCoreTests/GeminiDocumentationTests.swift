import XCTest
import Foundation
@testable import QuotaCore

/// The privacy section of `README.md` states exactly what QuotaBar types into a
/// Gemini session the user has authenticated, so it is checked against the
/// shipped expect script instead of being maintained by hand. It claimed the
/// probe "sends only `/stats`" for as long as the script also drove `/model` and
/// a Ctrl-C, which is the kind of drift a reader deciding whether to trust the
/// tool has no way to catch.
final class GeminiDocumentationTests: XCTestCase {
    /// Every distinct payload the expect script types into the session.
    /// `expectScript` is a non-raw literal, so a `send -- "\\r"` in the Swift
    /// source is a backslash and an `r` here, which is what Tcl escapes.
    private func sentPayloads() throws -> Set<String> {
        let script = GeminiTerminalProbe.expectScript(binary: "/tmp/gemini")
        let regex = try NSRegularExpression(pattern: #"send -- "([^"]*)""#)
        let matches = regex.matches(in: script, range: NSRange(script.startIndex..., in: script))
        let payloads = matches.compactMap { match in
            Range(match.range(at: 1), in: script).map { String(script[$0]) }
        }
        XCTAssertFalse(payloads.isEmpty, "no `send --` found; the payload pattern no longer matches the script")
        return Set(payloads)
    }

    private func repositoryDocument(_ name: String) throws -> String {
        // …/Tests/QuotaCoreTests/GeminiDocumentationTests.swift → repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw XCTSkip("\(name) is not readable at \(url.path); the tests are running away from the checkout")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func section(_ heading: String, in markdown: String) throws -> String {
        let start = try XCTUnwrap(markdown.range(of: "\n\(heading)\n"), "no `\(heading)` heading").upperBound
        let body = markdown[start...]
        let end = body.range(of: "\n## ")?.lowerBound ?? body.endIndex
        return String(body[..<end])
    }

    func testReadmePrivacySectionNamesEveryInputTheGeminiProbeSends() throws {
        let privacy = try section("## Privacy and behavior", in: try repositoryDocument("README.md"))
        // The wording the README uses for each keystroke. A payload the script
        // gains without an entry here fails the equality below rather than
        // quietly widening what QuotaBar types while the promise stays put.
        let wording = ["/stats": "`/stats`", "/model": "`/model`", #"\r"#: "Enter", #"\003"#: "Ctrl-C"]
        XCTAssertEqual(try sentPayloads(), Set(wording.keys))
        for (payload, phrase) in wording.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(privacy.contains(phrase),
                          "the privacy section never mentions \(phrase), which the probe sends as \(payload)")
        }
        XCTAssertFalse(privacy.contains("only `/stats`"),
                       "the privacy section still claims /stats is the only input")
    }

    func testReadmeProviderBulletNamesBothGeminiViews() throws {
        let readme = try repositoryDocument("README.md")
        let start = try XCTUnwrap(readme.range(of: "- **Gemini CLI:**"), "no Gemini provider bullet").lowerBound
        let rest = readme[start...]
        let bullet = String(rest[..<(rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex)])
        XCTAssertTrue(bullet.contains("`/stats`"), "the Gemini bullet no longer names /stats: \(bullet)")
        XCTAssertTrue(bullet.contains("`/model`"), "the Gemini bullet names only one view: \(bullet)")
    }

    /// `AGENTS.md` is canonical, so its constraint has to describe the script
    /// that ships rather than the one that shipped first.
    func testCanonicalConstraintNamesBothGeminiViews() throws {
        let constraints = try section("## Implementation constraints", in: try repositoryDocument("AGENTS.md"))
        XCTAssertTrue(constraints.contains("`/stats`"), "the Gemini constraint no longer names /stats")
        XCTAssertTrue(constraints.contains("`/model`"), "the Gemini constraint names only one view")
    }
}
