import Foundation
import QuotaCore

enum Output {
    private enum ANSI: String {
        case reset = "\u{1B}[0m", yellow = "\u{1B}[33m", red = "\u{1B}[31m", dim = "\u{1B}[2m"
    }

    static func render(_ snapshots: [QuotaSnapshot], format: Arguments.Format,
                       now: Date = Date(), color: Bool) throws -> String {
        switch format {
        case .text: return text(snapshots, now: now, color: color)
        case .json: return try json(snapshots)
        case .waybar: return try waybar(snapshots, now: now)
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(snapshots), as: UTF8.self)
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
