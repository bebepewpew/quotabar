import XCTest
import Foundation
@testable import QuotaCore

/// Covers the value types in `Models.swift`: the per-provider constants, the
/// window-key derivation that gives a quota window its identity, and the custom
/// `Decodable` implementations that keep persisted state readable across
/// versions. Storage keys and decoding have to stay backward compatible, so the
/// decoder tests deliberately feed payloads with missing and null fields.
final class ModelsTests: XCTestCase {

    // MARK: - Provider

    func testProviderExposesEveryCaseConstant() {
        XCTAssertEqual(Provider.allCases, [.gemini, .claude, .codex])

        XCTAssertEqual(Provider.gemini.rawValue, "Gemini CLI")
        XCTAssertEqual(Provider.claude.rawValue, "Claude Code")
        XCTAssertEqual(Provider.codex.rawValue, "Codex")

        XCTAssertEqual(Provider.gemini.id, "Gemini CLI")
        XCTAssertEqual(Provider.claude.id, "Claude Code")
        XCTAssertEqual(Provider.codex.id, "Codex")

        XCTAssertEqual(Provider.gemini.executableName, "gemini")
        XCTAssertEqual(Provider.claude.executableName, "claude")
        XCTAssertEqual(Provider.codex.executableName, "codex")

        XCTAssertEqual(Provider.gemini.symbol, "sparkles")
        XCTAssertEqual(Provider.claude.symbol, "brain.head.profile")
        XCTAssertEqual(Provider.codex.symbol, "chevron.left.forwardslash.chevron.right")

        XCTAssertEqual(Provider.gemini.tint, "4F7DF3")
        XCTAssertEqual(Provider.claude.tint, "D97757")
        XCTAssertEqual(Provider.codex.tint, "10A37F")
    }

    /// `--provider` matches on the slug, so it must stay a lowercase token that
    /// is unique across providers and identical to the probed executable.
    func testProviderSlugsAreLowercaseUniqueAndMatchTheExecutable() {
        for provider in Provider.allCases {
            XCTAssertEqual(provider.slug, provider.executableName, "\(provider) slug drifted from its executable")
            XCTAssertEqual(provider.slug, provider.slug.lowercased())
            XCTAssertFalse(provider.slug.isEmpty)
            XCTAssertFalse(provider.symbol.isEmpty)
            XCTAssertEqual(provider.tint.count, 6, "\(provider) tint is not a 6-digit hex string")
            XCTAssertTrue(provider.tint.allSatisfy(\.isHexDigit), "\(provider) tint is not hexadecimal")
        }
        XCTAssertEqual(Set(Provider.allCases.map(\.slug)).count, Provider.allCases.count)
        XCTAssertEqual(Set(Provider.allCases.map(\.symbol)).count, Provider.allCases.count)
        XCTAssertEqual(Set(Provider.allCases.map(\.tint)).count, Provider.allCases.count)
    }

    func testProviderRoundTripsThroughItsRawValue() throws {
        for provider in Provider.allCases {
            let data = try JSONEncoder().encode(provider)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(provider.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(Provider.self, from: data), provider)
        }
    }

    // MARK: - QuotaWindow.key(for:)

    /// Window keys are identity; labels are display data. Punctuation, spacing
    /// and case must all collapse to the same key, and non-ASCII letters and
    /// digits have to survive rather than being flattened into separators.
    func testWindowKeyDerivationFromAwkwardLabels() {
        let cases: [(label: String, key: String)] = [
            ("Session", "session"),
            ("5-hour limit", "5-hour-limit"),
            ("5 hour limit", "5-hour-limit"),
            ("5_hour_limit", "5-hour-limit"),
            ("  5   HOUR   limit  ", "5-hour-limit"),
            ("Weekly limit (all models)", "weekly-limit-all-models"),
            ("Weekly — all models", "weekly-all-models"),
            ("gemini-2.5-pro", "gemini-2-5-pro"),
            ("Flash Lite", "flash-lite"),
            ("100%", "100"),
            ("---weekly---", "weekly"),
            ("!@#$%^&*()", ""),
            ("", ""),
            ("   ", ""),
            ("———", ""),
            ("🚀 Pro", "pro"),
            ("Пределы 5 часов", "пределы-5-часов"),
            ("Résumé/Quota", "résumé-quota"),
            ("5時間", "5時間"),
            ("週次\tクォータ", "週次-クォータ"),
            ("tab\tand\nnewline", "tab-and-newline")
        ]
        for (label, key) in cases {
            XCTAssertEqual(QuotaWindow.key(for: label), key, "label \(label.debugDescription)")
        }
    }

    /// The derived key has to be stable under the label churn a provider CLI is
    /// allowed to produce between releases.
    func testWindowKeyIsStableAcrossLabelPunctuationChurn() {
        let variants = ["Weekly limit", "weekly  limit", "WEEKLY-LIMIT", "Weekly, limit!", "  weekly / limit  "]
        XCTAssertEqual(Set(variants.map(QuotaWindow.key(for:))).count, 1)
        XCTAssertEqual(QuotaWindow.key(for: variants[0]), "weekly-limit")
    }

    func testWindowKeyNeverStartsOrEndsWithASeparator() {
        for label in ["(session)", "-session-", " session ", "***session***"] {
            let key = QuotaWindow.key(for: label)
            XCTAssertEqual(key, "session", "label \(label.debugDescription)")
            XCTAssertFalse(key.hasPrefix("-"))
            XCTAssertFalse(key.hasSuffix("-"))
        }
    }

    // MARK: - QuotaWindow

    func testWindowDerivesKeyFromLabelAndHonoursAnExplicitOne() {
        let derived = QuotaWindow(label: "Weekly limit (all models)", usedPercent: 12, resetAt: nil)
        XCTAssertEqual(derived.key, "weekly-limit-all-models")
        XCTAssertEqual(derived.id, derived.key)
        XCTAssertNil(derived.resetAt)

        let explicit = QuotaWindow(key: "gemini-2.5-pro", label: "Pro", usedPercent: 3, resetAt: nil)
        XCTAssertEqual(explicit.key, "gemini-2.5-pro", "an explicit key must not be re-derived from the label")
        XCTAssertEqual(explicit.id, "gemini-2.5-pro")
    }

    func testWindowDecodesWithKeyPresentAbsentAndNull() throws {
        let decoder = JSONDecoder()

        let present = try decoder.decode(QuotaWindow.self, from: Data("""
        {"key":"gemini-2.5-pro","label":"Pro","usedPercent":41.5,"resetAt":700000000}
        """.utf8))
        XCTAssertEqual(present.key, "gemini-2.5-pro")
        XCTAssertEqual(present.label, "Pro")
        XCTAssertEqual(present.usedPercent, 41.5)
        XCTAssertEqual(present.resetAt, Date(timeIntervalSinceReferenceDate: 700_000_000))

        // A payload written before windows carried a key: derive it from the label.
        let absent = try decoder.decode(QuotaWindow.self, from: Data("""
        {"label":"5-hour limit","usedPercent":0}
        """.utf8))
        XCTAssertEqual(absent.key, "5-hour-limit")
        XCTAssertNil(absent.resetAt)

        let null = try decoder.decode(QuotaWindow.self, from: Data("""
        {"key":null,"label":"Weekly limit","usedPercent":100,"resetAt":null}
        """.utf8))
        XCTAssertEqual(null.key, "weekly-limit")
        XCTAssertEqual(null.usedPercent, 100)
        XCTAssertNil(null.resetAt)
    }

    func testWindowDecodingRequiresLabelAndUsedPercent() {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(QuotaWindow.self, from: Data(#"{"usedPercent":10}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(QuotaWindow.self, from: Data(#"{"label":"Session"}"#.utf8)))
    }

    func testWindowSurvivesAnEncodeDecodeRoundTrip() throws {
        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        let original = QuotaWindow(label: "Weekly limit (all models)", usedPercent: 66.5, resetAt: reset)
        let restored = try JSONDecoder().decode(QuotaWindow.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.key, original.key)
        XCTAssertEqual(restored.label, original.label)
        XCTAssertEqual(restored.usedPercent, original.usedPercent)
        XCTAssertEqual(try XCTUnwrap(restored.resetAt).timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - QuotaSelection

    func testSelectionDerivesKeyAndIdentity() {
        let derived = QuotaSelection(provider: .gemini, windowLabel: "Flash Lite")
        XCTAssertEqual(derived.windowKey, "flash-lite")
        XCTAssertEqual(derived.windowLabel, "Flash Lite")
        XCTAssertEqual(derived.id, "Gemini CLI|flash-lite")

        let explicit = QuotaSelection(provider: .codex, windowKey: "weekly", windowLabel: "Weekly limit")
        XCTAssertEqual(explicit.windowKey, "weekly")
        XCTAssertEqual(explicit.id, "Codex|weekly")

        let unicode = QuotaSelection(provider: .claude, windowLabel: "5時間 — セッション")
        XCTAssertEqual(unicode.windowKey, "5時間-セッション")
        XCTAssertEqual(unicode.id, "Claude Code|5時間-セッション")
    }

    func testSelectionEqualityAndHashing() {
        let a = QuotaSelection(provider: .codex, windowLabel: "Weekly limit")
        let b = QuotaSelection(provider: .codex, windowKey: "weekly-limit", windowLabel: "Weekly limit")
        let other = QuotaSelection(provider: .claude, windowLabel: "Weekly limit")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, other)
        XCTAssertEqual(Set([a, b, other]).count, 2)
    }

    func testSelectionDecodesWithWindowKeyPresentAbsentAndNull() throws {
        let decoder = JSONDecoder()

        let present = try decoder.decode(QuotaSelection.self, from: Data("""
        {"provider":"Codex","windowKey":"weekly","windowLabel":"Weekly limit"}
        """.utf8))
        XCTAssertEqual(present.provider, .codex)
        XCTAssertEqual(present.windowKey, "weekly")
        XCTAssertEqual(present.id, "Codex|weekly")

        // Selections persisted before windowKey existed derive it from the label.
        let absent = try decoder.decode(QuotaSelection.self, from: Data("""
        {"provider":"Gemini CLI","windowLabel":"Flash Lite"}
        """.utf8))
        XCTAssertEqual(absent.windowKey, "flash-lite")

        let null = try decoder.decode(QuotaSelection.self, from: Data("""
        {"provider":"Claude Code","windowKey":null,"windowLabel":"5-hour limit"}
        """.utf8))
        XCTAssertEqual(null.windowKey, "5-hour-limit")
    }

    func testSelectionDecodingRejectsUnknownProviderAndMissingLabel() {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(QuotaSelection.self, from: Data("""
        {"provider":"Nope","windowLabel":"Session"}
        """.utf8)))
        XCTAssertThrowsError(try decoder.decode(QuotaSelection.self, from: Data("""
        {"provider":"Codex"}
        """.utf8)))
    }

    func testSelectionSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = QuotaSelection(provider: .gemini, windowLabel: "Weekly — all models")
        let restored = try JSONDecoder().decode(QuotaSelection.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.id, original.id)
    }

    // MARK: - MenuBarQuota

    func testMenuBarQuotaTakesItsIdentityFromTheSelection() {
        let selection = QuotaSelection(provider: .gemini, windowLabel: "Flash Lite")
        let quota = MenuBarQuota(selection: selection, usedPercent: 42, badge: "L")
        XCTAssertEqual(quota.id, selection.id)
        XCTAssertEqual(quota.id, "Gemini CLI|flash-lite")
        XCTAssertEqual(quota.usedPercent, 42)
        XCTAssertEqual(quota.badge, "L")

        let unavailable = MenuBarQuota(selection: selection, usedPercent: nil, badge: "L")
        XCTAssertNil(unavailable.usedPercent)
    }

    // MARK: - QuotaSnapshot

    func testSnapshotLoadingPlaceholder() {
        for provider in Provider.allCases {
            let snapshot = QuotaSnapshot.loading(provider)
            XCTAssertEqual(snapshot.provider, provider)
            XCTAssertEqual(snapshot.id, provider)
            XCTAssertTrue(snapshot.windows.isEmpty)
            XCTAssertNil(snapshot.plan)
            XCTAssertNil(snapshot.error)
            XCTAssertTrue(snapshot.probeSucceeded, "a placeholder must not look like a failed probe")
            XCTAssertEqual(snapshot.updatedAt.timeIntervalSinceNow, 0, accuracy: 5)
        }
    }

    func testSnapshotDecodesAFullPayload() throws {
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data("""
        {"provider":"Codex","windows":[{"key":"session","label":"Session","usedPercent":23,"resetAt":700000000}],
         "plan":"plus","error":"Refresh failed: timed out","probeSucceeded":false,"updatedAt":700000000}
        """.utf8))
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.id, .codex)
        XCTAssertEqual(snapshot.windows.map(\.key), ["session"])
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.error, "Refresh failed: timed out")
        XCTAssertFalse(snapshot.probeSucceeded)
        XCTAssertEqual(snapshot.updatedAt, Date(timeIntervalSinceReferenceDate: 700_000_000))
    }

    /// A payload from an older build carries the provider and nothing else. It
    /// has to decode as an empty, successful snapshot rather than throwing.
    func testSnapshotDecodesWithEveryOptionalFieldAbsent() throws {
        let before = Date()
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(#"{"provider":"Gemini CLI"}"#.utf8))
        XCTAssertEqual(snapshot.provider, .gemini)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.error)
        XCTAssertTrue(snapshot.probeSucceeded)
        XCTAssertGreaterThanOrEqual(snapshot.updatedAt.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
    }

    func testSnapshotDecodesWithEveryOptionalFieldNull() throws {
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data("""
        {"provider":"Claude Code","windows":null,"plan":null,"error":null,"probeSucceeded":null,"updatedAt":null}
        """.utf8))
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.error)
        XCTAssertTrue(snapshot.probeSucceeded, "an absent flag means the probe succeeded")
        XCTAssertEqual(snapshot.updatedAt.timeIntervalSinceNow, 0, accuracy: 5)
    }

    func testSnapshotDecodingRequiresAKnownProvider() {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(QuotaSnapshot.self, from: Data(#"{"windows":[]}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(QuotaSnapshot.self, from: Data(#"{"provider":"codex"}"#.utf8)),
                             "the raw value is the display name, not the slug")
    }

    func testSnapshotSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = QuotaSnapshot(provider: .gemini,
                                     windows: [QuotaWindow(label: "Flash Lite", usedPercent: 7.5, resetAt: Date(timeIntervalSince1970: 2_000_000_000)),
                                               QuotaWindow(label: "Pro", usedPercent: 0, resetAt: nil)],
                                     plan: "free", error: nil, probeSucceeded: true,
                                     updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let restored = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.provider, .gemini)
        XCTAssertEqual(restored.windows.map(\.key), ["flash-lite", "pro"])
        XCTAssertEqual(restored.windows.map(\.usedPercent), [7.5, 0])
        XCTAssertNil(restored.windows[1].resetAt)
        XCTAssertEqual(restored.plan, "free")
        XCTAssertNil(restored.error)
        XCTAssertTrue(restored.probeSucceeded)
        XCTAssertEqual(restored.updatedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }
}
