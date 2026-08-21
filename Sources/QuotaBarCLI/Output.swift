import Foundation
import QuotaCore

enum Output {
    private enum ANSI: String {
        case reset = "\u{1B}[0m", yellow = "\u{1B}[33m", red = "\u{1B}[31m", dim = "\u{1B}[2m"
        case green = "\u{1B}[32m"
    }

    static func render(_ snapshots: [QuotaSnapshot], format: Arguments.Format,
                       now: Date = Date(), color: Bool) throws -> String {
        switch format {
        case .text: return text(snapshots, now: now, color: color)
        case .json: return try json(snapshots)
        case .waybar: return try waybar(snapshots, now: now)
        // `Arguments.validate` rejects csv for status, so this is unreachable;
        // falling back to text keeps the switch honest without inventing a format.
        case .csv: return text(snapshots, now: now, color: color)
        }
    }

    static func text(_ snapshots: [QuotaSnapshot], now: Date = Date(), color: Bool) -> String {
        let rows = QuotaFormatting.rows(for: snapshots, now: now)
        guard !rows.isEmpty else {
            return "No supported CLI found. Install codex, claude or gemini and authenticate it."
        }
        let providerWidth = rows.map(\.provider.rawValue.count).max() ?? 0
        let windowWidth = rows.map(\.window.count).max() ?? 0
        let percentWidth = rows.map(\.percentText.count).max() ?? 0

        return rows.map { row in
            let head = "\(pad(row.provider.rawValue, providerWidth))  \(pad(row.window, windowWidth))"
            guard let used = row.usedPercent else {
                return "\(head)  \(paint(row.error ?? "unavailable", with: .red, enabled: color))"
            }
            let percent = leftPad(row.percentText, percentWidth)
            let bar = QuotaFormatting.bar(used)
            let trailing = row.error.map { paint("  ⚠ \($0)", with: .red, enabled: color) }
                ?? (row.resetText.isEmpty ? "" : "  " + paint(row.resetText, with: .dim, enabled: color))
            return "\(head)  \(paint("\(percent)  \(bar)", with: tone(row.urgency), enabled: color))\(trailing)"
        }.joined(separator: "\n")
    }

    static func json(_ snapshots: [QuotaSnapshot]) throws -> String {
        String(decoding: try encoder().encode(snapshots), as: UTF8.self)
    }

    /// The one document a machine-readable consumer is still owed when no
    /// provider CLI is installed, so `--json` writes an empty array and waybar an
    /// `n/a` payload instead of zero bytes. `nil` for the formats a person reads:
    /// they already have the reason on stderr, in prose.
    static func emptyState(format: Arguments.Format) throws -> String? {
        switch format {
        // Not `json([])`: the pretty-printing encoder writes an empty array as
        // "[\n\n]", which reads as a truncated document. One line, on purpose.
        case .json: return "[]"
        case .waybar: return try waybar([])
        case .text, .csv: return nil
        }
    }

    /// `quotabar history`. Text and CSV come from `QuotaCore` so the terminal and
    /// a future Linux front-end word history the same way.
    static func history(_ result: HistoryReadResult, cycles: [CycleSummary],
                        labels: [HistorySeriesID: String], from: Date, to: Date,
                        arguments: Arguments) throws -> String {
        switch arguments.format {
        case .csv:
            return UsageReport.csv(samples: result.samples)
        case .json:
            let payload = UsageReport.historyPayload(samples: result.samples, cycles: cycles,
                                                     from: from, to: to, labels: labels,
                                                     damagedRecords: result.damagedRecords)
            return String(decoding: try encoder().encode(payload), as: UTF8.self)
        case .text, .waybar:
            return arguments.showCycles
                ? UsageReport.cycles(cycles, labels: labels)
                : UsageReport.history(samples: result.samples, from: from, to: to,
                                      labels: labels, diagnostic: result.diagnostic)
        }
    }

    static func advice(_ recommendations: [Recommendation], format: Arguments.Format,
                       color: Bool) throws -> String {
        guard format != .json else {
            return String(decoding: try encoder().encode(UsageReport.advicePayload(recommendations)),
                          as: UTF8.self)
        }
        guard color else { return UsageReport.advice(recommendations) }
        // Colour only the severity badge: the evidence lines are numbers the user
        // may want to copy, and escape codes travel with a copy.
        return UsageReport.advice(recommendations).split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let severity = Recommendation.Severity.allCases.first(where: {
                    line.hasPrefix(UsageReport.badge($0))
                }) else { return String(line) }
                let badge = UsageReport.badge(severity)
                return paint(badge, with: tone(severity), enabled: true) + line.dropFirst(badge.count)
            }
            .joined(separator: "\n")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func tone(_ severity: Recommendation.Severity) -> ANSI? {
        switch severity {
        case .critical: .red
        case .warning: .yellow
        case .opportunity: .green
        case .info: .dim
        }
    }

    static func waybar(_ snapshots: [QuotaSnapshot], now: Date = Date()) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = WaybarPayload(rows: QuotaFormatting.rows(for: snapshots, now: now))
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func tone(_ urgency: QuotaUrgency) -> ANSI? {
        switch urgency {
        case .normal: nil
        case .warning: .yellow
        case .critical: .red
        }
    }

    private static func paint(_ text: String, with color: ANSI?, enabled: Bool) -> String {
        guard enabled, let color else { return text }
        return color.rawValue + text + ANSI.reset.rawValue
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value + String(repeating: " ", count: max(0, width - value.count))
    }

    private static func leftPad(_ value: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - value.count)) + value
    }
}
