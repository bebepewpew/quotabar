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

    /// One row per sample it is handed — `quotabar history` hands it the `--since`
    /// window rather than the whole log. Fields are numbers, keys and timestamps
    /// only: nothing here needs quoting, and the header names what each column is.
    public static func csv(samples: [UsageSample]) -> String {
        let rows = samples.sorted { $0.at < $1.at }.map { sample in
            [sample.series.provider.slug,
             sample.series.windowKey,
             iso(sample.at),
             String(format: "%.2f", sample.usedPercent),
             sample.resetAt.map(iso) ?? ""].joined(separator: ",")
        }
        return (["provider,window_key,at,used_percent,reset_at"] + rows).joined(separator: "\n")
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
