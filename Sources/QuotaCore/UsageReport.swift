import Foundation

/// Renders history and advice as text, CSV and JSON.
///
/// In `QuotaCore` rather than the CLI for two reasons: the CLI is a separate
/// executable the test binary does not link, so nothing written there is covered;
/// and the Linux front-end will want the same words the terminal uses.
public enum UsageReport {
    public static let defaultSparklineWidth = 24

    // MARK: - History, text

    public static func history(samples: [UsageSample], from: Date, to: Date,
                               labels: [HistorySeriesID: String] = [:],
                               width: Int = defaultSparklineWidth,
                               diagnostic: String? = nil) -> String {
        guard !samples.isEmpty else {
            return diagnostic.map { "No usage recorded yet. (\($0))" }
                ?? "No usage recorded yet. QuotaBar records a sample every time it refreshes."
        }
        let grouped = Dictionary(grouping: samples, by: \.series)
            .sorted { UsageAnalysis.order($0.key) < UsageAnalysis.order($1.key) }

        let names = grouped.map { name(for: $0.key, labels: labels) }
        let nameWidth = names.map(\.count).max() ?? 0

        var lines = grouped.enumerated().map { index, entry -> String in
            let ordered = entry.value.sorted { $0.at < $1.at }
            let cells = QuotaFormatting.buckets(ordered.map { (at: $0.at, usedPercent: $0.usedPercent) },
                                                from: from, to: to, count: width)
            let latest = ordered.last?.usedPercent ?? 0
            let peak = ordered.map(\.usedPercent).max() ?? 0
            return "\(pad(names[index], nameWidth))  \(QuotaFormatting.sparkline(cells))"
                + "  now \(leftPad(QuotaFormatting.percent(latest), 6))"
                + "  peak \(leftPad(QuotaFormatting.percent(peak), 6))"
                + "  \(ordered.count) samples"
        }
        lines.append(footer(from: from, to: to, width: width))
        if let diagnostic { lines.append(diagnostic) }
        return lines.joined(separator: "\n")
    }

    /// Says how wide one cell is, because a sparkline without a scale invites
    /// reading a 90-day chart as if it were a day.
    private static func footer(from: Date, to: Date, width: Int) -> String {
        let span = max(to.timeIntervalSince(from), 0)
        let per = width > 0 ? span / Double(width) : 0
        return "\(spanText(span)) to \(day(to)) · each cell \(spanText(per))"
    }

    // MARK: - Cycles, text

    public static func cycles(_ summaries: [CycleSummary],
                              labels: [HistorySeriesID: String] = [:]) -> String {
        let complete = summaries.filter(\.isComplete)
        guard !complete.isEmpty else {
            return "No complete cycles recorded yet. A cycle is complete once QuotaBar "
                + "has seen both the reset that started it and the one that ended it."
        }
        return Dictionary(grouping: complete, by: \.series)
            .sorted { UsageAnalysis.order($0.key) < UsageAnalysis.order($1.key) }
            .map { series, entries in
                let rows = entries.sorted { $0.startedAt < $1.startedAt }.map { cycle in
                    "  \(day(cycle.startedAt)) → \(day(cycle.endedAt))"
                        + "   peak \(leftPad(QuotaFormatting.percent(cycle.peakPercent), 6))"
                        + "   observed \(leftPad(QuotaFormatting.percent(cycle.observedFraction * 100), 5))"
                        + "   \(cycle.sampleCount) samples"
                }
                return ([name(for: series, labels: labels)] + rows).joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    // MARK: - Advice, text

    public static func advice(_ recommendations: [Recommendation]) -> String {
        guard !recommendations.isEmpty else {
            return "Nothing to suggest. Every window QuotaBar has watched is comfortably inside its limit."
        }
        return recommendations.map { recommendation in
            ([  "\(badge(recommendation.severity))  \(recommendation.headline)"]
                + recommendation.evidence.map { "        · \($0)" })
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Fixed-width so the evidence lines under it align.
    public static func badge(_ severity: Recommendation.Severity) -> String {
        switch severity {
        case .critical: "CRITICAL   "
        case .warning: "WARNING    "
        case .opportunity: "OPPORTUNITY"
        case .info: "INFO       "
        }
    }

    // MARK: - CSV

    /// The one column set both CSV writers below emit, so a recorded snapshot and
    /// an export of the history it went into land in the same table.
    public static let csvHeader = "provider,window_key,at,used_percent,reset_at"

    /// One row per stored sample. The header names what each column is.
    public static func csv(samples: [UsageSample]) -> String {
        let rows = samples.sorted { $0.at < $1.at }.map { sample in
            [sample.series.provider.slug,
             csvField(sample.series.windowKey),
             iso(sample.at),
             percentField(sample.usedPercent),
             sample.resetAt.map(iso) ?? ""].joined(separator: ",")
        }
        return ([csvHeader] + rows).joined(separator: "\n")
    }

    /// One row per window of a live status snapshot, in `csvHeader`'s columns, so
    /// a cron job can append `quotabar --format csv` to the same file it exports
    /// history into instead of flattening `--json` itself.
    ///
    /// `at` is each snapshot's own `updatedAt` rather than the time of the call: a
    /// reading retained after a failed refresh is stale, and the row has to say so
    /// rather than restamp it as current. A window with no known reset leaves that
    /// cell empty — a placeholder date would be read as a real one. A provider that
    /// reported no window contributes no row, because there is no number to record;
    /// the CLI has already named it on stderr and exits non-zero.
    ///
    /// `includeHeader` is false for every cycle of a `--watch` stream after the
    /// first, so a header lands once at the top instead of between the rows.
    public static func csv(snapshots: [QuotaSnapshot], includeHeader: Bool = true) -> String {
        let rows = snapshots.flatMap { snapshot in
            snapshot.windows.map { window in
                [snapshot.provider.slug,
                 csvField(window.key),
                 iso(snapshot.updatedAt),
                 percentField(window.usedPercent),
                 window.resetAt.map(iso) ?? ""].joined(separator: ",")
            }
        }
        return ((includeHeader ? [csvHeader] : []) + rows).joined(separator: "\n")
    }

    /// Quotes a cell only when it has to be. Every other column is a provider
    /// slug, a formatted number or an ISO timestamp, but a window key arrives from
    /// a cache file that anything could have written, and a comma or a newline in
    /// one would otherwise split the row in two.
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Two decimals, clamped. History records are clamped as they are read, but a
    /// snapshot arrives from a cache file that anything could have written, and an
    /// out-of-range or non-finite percentage must not reach a column a spreadsheet
    /// reads as a number. Nothing survivable can be inferred from `nan`, so it
    /// records as zero, the same reading a missing number would give.
    private static func percentField(_ value: Double) -> String {
        guard value.isFinite else { return "0.00" }
        return String(format: "%.2f", min(max(value, 0), 100))
    }

    // MARK: - JSON

    public struct HistoryPayload: Encodable, Sendable {
        public struct Point: Encodable, Sendable {
            public let at: Date
            public let usedPercent: Double
            public let resetAt: Date?
        }
        public struct Series: Encodable, Sendable {
            public let provider: String
            public let windowKey: String
            public let windowLabel: String
            public let points: [Point]
        }
        public struct Cycle: Encodable, Sendable {
            public let provider: String
            public let windowKey: String
            public let startedAt: Date
            public let endedAt: Date
            public let peakPercent: Double
            public let observedFraction: Double
            public let sampleCount: Int
            public let isComplete: Bool
        }
        public let from: Date
        public let to: Date
        public let series: [Series]
        public let cycles: [Cycle]
        public let damagedRecords: Int
    }

    public static func historyPayload(samples: [UsageSample], cycles summaries: [CycleSummary],
                                      from: Date, to: Date,
                                      labels: [HistorySeriesID: String] = [:],
                                      damagedRecords: Int = 0) -> HistoryPayload {
        let series = Dictionary(grouping: samples, by: \.series)
            .sorted { UsageAnalysis.order($0.key) < UsageAnalysis.order($1.key) }
            .map { key, values in
                HistoryPayload.Series(
                    provider: key.provider.slug,
                    windowKey: key.windowKey,
                    windowLabel: labels[key] ?? key.windowKey,
                    points: values.sorted { $0.at < $1.at }.map {
                        HistoryPayload.Point(at: $0.at, usedPercent: $0.usedPercent, resetAt: $0.resetAt)
                    })
            }
        let cycles = summaries.map {
            HistoryPayload.Cycle(provider: $0.series.provider.slug, windowKey: $0.series.windowKey,
                                 startedAt: $0.startedAt, endedAt: $0.endedAt,
                                 peakPercent: $0.peakPercent, observedFraction: $0.observedFraction,
                                 sampleCount: $0.sampleCount, isComplete: $0.isComplete)
        }
        return HistoryPayload(from: from, to: to, series: series, cycles: cycles,
                              damagedRecords: damagedRecords)
    }

    public struct AdvicePayload: Encodable, Sendable {
        public struct Item: Encodable, Sendable {
            public let kind: String
            public let severity: String
            public let provider: String
            public let windowKey: String
            public let windowLabel: String
            public let headline: String
            public let evidence: [String]
        }
        public let recommendations: [Item]
    }

    public static func advicePayload(_ recommendations: [Recommendation]) -> AdvicePayload {
        AdvicePayload(recommendations: recommendations.map {
            AdvicePayload.Item(kind: $0.kind.rawValue, severity: $0.severity.rawValue,
                               provider: $0.series.provider.slug, windowKey: $0.series.windowKey,
                               windowLabel: $0.windowLabel, headline: $0.headline, evidence: $0.evidence)
        })
    }

    // MARK: - Helpers

    static func name(for series: HistorySeriesID, labels: [HistorySeriesID: String]) -> String {
        "\(series.provider.rawValue) \(labels[series] ?? series.windowKey)"
    }

    /// Coarse, locale-free span text. `RelativeDateTimeFormatter` is absent from
    /// swift-corelibs-foundation, which is why `QuotaFormatting` hand-rolls its
    /// reset wording too.
    static func spanText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<90: "\(Int(seconds.rounded()))s"
        case ..<5_400: "\(Int((seconds / 60).rounded()))m"
        // A day reads as "1d", not "24h": the footer describes chart cells, and
        // a week-wide chart is easier to reason about in days.
        case ..<86_400: "\(Int((seconds / 3_600).rounded()))h"
        default: "\(Int((seconds / 86_400).rounded()))d"
        }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value + String(repeating: " ", count: max(0, width - value.count))
    }

    private static func leftPad(_ value: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - value.count)) + value
    }
}
