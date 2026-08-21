import Foundation

/// One thing worth telling the user about a subscription, derived only from
/// arithmetic over stored samples.
public struct Recommendation: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case projectedExhaustion, chronicallyExhausted, burstyUsage
        case underUtilized, idle, rebalance, insufficientData
    }

    public enum Severity: String, Sendable, CaseIterable {
        case critical, warning, opportunity, info
    }

    public let kind: Kind
    public let severity: Severity
    public let series: HistorySeriesID
    /// What the window is called right now. Display only — identity is the key.
    public let windowLabel: String
    public let headline: String
    /// The numbers behind the headline, already rendered. Never prose.
    public let evidence: [String]
    /// For `projectedExhaustion`, the reset the forecast is about. It identifies
    /// the cycle, so an alert raised for it fires once rather than on every
    /// refresh until the window resets.
    public let cycleResetAt: Date?

    public init(kind: Kind, severity: Severity, series: HistorySeriesID,
                windowLabel: String, headline: String, evidence: [String],
                cycleResetAt: Date? = nil) {
        self.kind = kind
        self.severity = severity
        self.series = series
        self.windowLabel = windowLabel
        self.headline = headline
        self.evidence = evidence
        self.cycleResetAt = cycleResetAt
    }
}

/// Everything the advisor knows about one quota window.
public struct AdvisorInput: Sendable {
    public let series: HistorySeriesID
    public let windowLabel: String
    /// Newest last. Incomplete and poorly observed cycles are filtered by the
    /// advisor, not by the caller.
    public let cycles: [CycleSummary]
    public let latest: UsageSample?
    public let burnRatePerHour: Double?

    public init(series: HistorySeriesID, windowLabel: String, cycles: [CycleSummary],
                latest: UsageSample?, burnRatePerHour: Double?) {
        self.series = series
        self.windowLabel = windowLabel
        self.cycles = cycles
        self.latest = latest
        self.burnRatePerHour = burnRatePerHour
    }
}

/// Fixed rules over completed cycles. No model, no network, no heuristics that
/// cannot be read off the source.
public enum Advisor {
    /// Below this many usable cycles the advisor says so rather than guessing.
    public static let minimumCycles = 4
    /// A cycle watched less than this much of the time understates its own peak,
    /// so it is not evidence of anything.
    public static let minimumCoverage = 0.6
    /// Only the most recent cycles count: a plan resized last month should not be
    /// judged on the quarter before it.
    public static let recentCycleCount = 8
    /// "Even the busiest recent cycle stayed at or under this" — the bar for
    /// calling a subscription oversized.
    public static let underUtilizedPeak = 40.0
    /// Effectively untouched.
    public static let idlePeak = 1.0
    public static let exhaustedPeak = 95.0
    /// How many of the recent cycles must have been exhausted to call it chronic.
    public static let exhaustedShare = 0.5
    /// Enough headroom elsewhere to be worth moving work to.
    public static let rebalanceHeadroom = 50.0
    /// A provider whose CLI has not reported for this long is not advised on at
    /// all — it was probably uninstalled.
    public static let staleAfterDays = 45.0

    /// How far back a refresh has to read for the advice it is able to give.
    ///
    /// `usableCycles` keeps the last `recentCycleCount` cycles and the longest
    /// window any provider reports is a week, so eight of those are eight weeks.
    /// One more covers the cycle currently in progress, and one more again the
    /// sample before the oldest kept cycle — without it that cycle has no
    /// observed start and stops counting as complete. Anything older is dropped
    /// by `usableCycles` anyway, and a series silent for `staleAfterDays` is not
    /// advised on at all, so reading past this only costs a `UsageSample` per
    /// record.
    public static let adviceLookback: TimeInterval = Double(recentCycleCount + 2) * 7 * 86_400

    /// How far back a projection has to read. A forecast is the latest reading
    /// plus a burn rate, and `UsageAnalysis.burnRate` ignores everything older
    /// than its own window — with no sample inside it there is no rate, and so
    /// no forecast.
    public static let forecastLookback: TimeInterval = UsageAnalysis.burnRateWindow

    /// Ranked, stable and deterministic: same inputs, same order, every run.
    public static func recommendations(for inputs: [AdvisorInput], now: Date = Date()) -> [Recommendation] {
        let live = inputs.filter { input in
            guard let latest = input.latest else { return false }
            return now.timeIntervalSince(latest.at) <= staleAfterDays * 86_400
        }

        var found = live.flatMap { perSeries($0, now: now) }
        found += bursty(in: live)
        found += rebalance(in: live)
        return found.sorted(by: precedes)
    }

    // MARK: - Per-series rules

    private static func perSeries(_ input: AdvisorInput, now: Date) -> [Recommendation] {
        var results: [Recommendation] = []
        if let projected = projectedExhaustion(input, now: now) { results.append(projected) }

        let usable = usableCycles(input.cycles)
        guard usable.count >= minimumCycles else {
            results.append(insufficientData(input, usable: usable.count))
            return results
        }
        let peaks = usable.map(\.peakPercent)

        let exhausted = peaks.filter { $0 >= exhaustedPeak }.count
        if Double(exhausted) >= Double(peaks.count) * exhaustedShare {
            results.append(Recommendation(
                kind: .chronicallyExhausted, severity: .critical, series: input.series,
                windowLabel: input.windowLabel,
                headline: "\(input.series.provider.rawValue) \(input.windowLabel) runs out most cycles",
                evidence: ["\(exhausted) of the last \(peaks.count) cycles reached \(QuotaFormatting.percent(exhaustedPeak)) or more",
                           "peak \(QuotaFormatting.percent(peaks.max() ?? 0)), median \(QuotaFormatting.percent(UsageAnalysis.median(peaks) ?? 0))"]))
            return results
        }

        // Idle before under-utilised: an untouched subscription is a stronger
        // statement than a lightly used one, and both would otherwise fire.
        if peaks.allSatisfy({ $0 <= idlePeak }) {
            results.append(Recommendation(
                kind: .idle, severity: .opportunity, series: input.series,
                windowLabel: input.windowLabel,
                headline: "\(input.series.provider.rawValue) \(input.windowLabel) has gone unused",
                evidence: ["\(peaks.count) cycles at or under \(QuotaFormatting.percent(idlePeak))",
                           "nothing recorded since \(formatted(usable.first?.startedAt))"]))
        } else if let ceiling = UsageAnalysis.percentile(peaks, 0.9), ceiling <= underUtilizedPeak {
            results.append(Recommendation(
                kind: .underUtilized, severity: .opportunity, series: input.series,
                windowLabel: input.windowLabel,
                headline: "\(input.series.provider.rawValue) \(input.windowLabel) looks oversized",
                evidence: ["even the busiest of the last \(peaks.count) cycles peaked at \(QuotaFormatting.percent(ceiling))",
                           "median peak \(QuotaFormatting.percent(UsageAnalysis.median(peaks) ?? 0))"]))
        }
        return results
    }

    private static func projectedExhaustion(_ input: AdvisorInput, now: Date) -> Recommendation? {
        guard let latest = input.latest, let rate = input.burnRatePerHour,
              let reset = latest.resetAt, reset > now,
              let eta = UsageAnalysis.projectedExhaustion(from: latest, burnRatePerHour: rate),
              eta < reset else { return nil }
        return Recommendation(
            kind: .projectedExhaustion, severity: .critical, series: input.series,
            windowLabel: input.windowLabel,
            headline: "\(input.series.provider.rawValue) \(input.windowLabel) is on course to run out before it resets",
            evidence: ["at \(QuotaFormatting.percent(latest.usedPercent)) and rising \(rounded(rate))%/h",
                       "projected to hit 100% \(QuotaFormatting.relativeReset(eta, from: now)), resetting \(QuotaFormatting.relativeReset(reset, from: now))"],
            cycleResetAt: reset)
    }

    /// The honest answer when there is not enough to judge. A gap in the record
    /// must never render as "all clear".
    private static func insufficientData(_ input: AdvisorInput, usable: Int) -> Recommendation {
        Recommendation(
            kind: .insufficientData, severity: .info, series: input.series,
            windowLabel: input.windowLabel,
            headline: "Not enough history yet for \(input.series.provider.rawValue) \(input.windowLabel)",
            evidence: ["\(usable) of \(minimumCycles) complete cycles observed",
                       "a cycle counts once it is watched for \(Int(minimumCoverage * 100))% of its length"])
    }

    // MARK: - Cross-series rules

    /// A session limit exhausted again and again while the weekly allowance goes
    /// spare is a scheduling problem, not a plan-size one — the advice is to
    /// spread the work out, not to spend more.
    private static func bursty(in inputs: [AdvisorInput]) -> [Recommendation] {
        Dictionary(grouping: inputs, by: \.series.provider)
            .sorted { order($0.key) < order($1.key) }
            .compactMap { _, group in
                guard let session = group.first(where: { !isWeekly($0.series.windowKey) }),
                      let weekly = group.first(where: { isWeekly($0.series.windowKey) }) else { return nil }
                let sessionPeaks = usableCycles(session.cycles).map(\.peakPercent)
                let weeklyPeaks = usableCycles(weekly.cycles).map(\.peakPercent)
                guard sessionPeaks.count >= minimumCycles, weeklyPeaks.count >= minimumCycles,
                      Double(sessionPeaks.filter { $0 >= exhaustedPeak }.count) >= Double(sessionPeaks.count) * exhaustedShare,
                      let weeklyCeiling = UsageAnalysis.percentile(weeklyPeaks, 0.9),
                      weeklyCeiling <= underUtilizedPeak else { return nil }
                return Recommendation(
                    kind: .burstyUsage, severity: .warning, series: session.series,
                    windowLabel: session.windowLabel,
                    headline: "\(session.series.provider.rawValue) usage is bursty, not oversubscribed",
                    evidence: ["\(session.windowLabel) hits its limit repeatedly",
                               "\(weekly.windowLabel) peaked at only \(QuotaFormatting.percent(weeklyCeiling))",
                               "spreading the same work out would fit the plan you already have"])
            }
    }

    /// Somewhere to send the next hour of work, decided on current readings alone
    /// so it is useful the moment a limit bites.
    private static func rebalance(in inputs: [AdvisorInput]) -> [Recommendation] {
        let readings = inputs.compactMap { input -> (AdvisorInput, UsageSample)? in
            guard let latest = input.latest else { return nil }
            return (input, latest)
        }
        return readings
            .filter { $0.1.usedPercent >= exhaustedPeak }
            .sorted { UsageAnalysis.order($0.0.series) < UsageAnalysis.order($1.0.series) }
            .compactMap { strained, _ in
                let alternatives = readings
                    .filter { $0.0.series.provider != strained.series.provider }
                    .filter { 100 - $0.1.usedPercent >= rebalanceHeadroom }
                    .sorted { $0.1.usedPercent < $1.1.usedPercent }
                guard let best = alternatives.first else { return nil }
                return Recommendation(
                    kind: .rebalance, severity: .info, series: strained.series,
                    windowLabel: strained.windowLabel,
                    headline: "\(best.0.series.provider.rawValue) has headroom while \(strained.series.provider.rawValue) is full",
                    evidence: ["\(strained.series.provider.rawValue) \(strained.windowLabel) is at \(QuotaFormatting.percent(strained.latest?.usedPercent ?? 0))",
                               "\(best.0.series.provider.rawValue) \(best.0.windowLabel) is at \(QuotaFormatting.percent(best.1.usedPercent))"])
            }
    }

    // MARK: - Helpers

    /// Complete, well-observed and recent. Everything else is not evidence.
    static func usableCycles(_ cycles: [CycleSummary]) -> [CycleSummary] {
        Array(cycles.filter { $0.isComplete && $0.observedFraction >= minimumCoverage }
            .suffix(recentCycleCount))
    }

    static func isWeekly(_ windowKey: String) -> Bool {
        windowKey.range(of: "week", options: .caseInsensitive) != nil
    }

    /// Critical first, then by kind, then by provider declaration order and
    /// window key, so two runs over the same data print the same list.
    static func precedes(_ lhs: Recommendation, _ rhs: Recommendation) -> Bool {
        let left = (rank(lhs.severity), rank(lhs.kind), UsageAnalysis.order(lhs.series))
        let right = (rank(rhs.severity), rank(rhs.kind), UsageAnalysis.order(rhs.series))
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
    }

    private static func rank(_ severity: Recommendation.Severity) -> Int {
        Recommendation.Severity.allCases.firstIndex(of: severity) ?? 0
    }

    private static func rank(_ kind: Recommendation.Kind) -> Int {
        Recommendation.Kind.allCases.firstIndex(of: kind) ?? 0
    }

    private static func order(_ provider: Provider) -> Int {
        Provider.allCases.firstIndex(of: provider) ?? 0
    }

    private static func rounded(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.05 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
    }

    private static func formatted(_ date: Date?) -> String {
        guard let date else { return "the start of the record" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Assembling the inputs

extension Advisor {
    /// The "on course to run out before it resets" findings for the windows that
    /// just reported.
    ///
    /// Reads back through the store the caller already has, over `forecastLookback`
    /// and no further: a projection cannot see past its own burn-rate window, so
    /// materialising three months of samples to compute one would be work thrown
    /// away.
    public static func projections(from store: any HistoryStore, for snapshots: [QuotaSnapshot],
                                   now: Date = Date()) -> [Recommendation] {
        let recent = store.read(from: now.addingTimeInterval(-forecastLookback), to: now).samples
        guard !recent.isEmpty else { return [] }
        return recommendations(for: inputs(history: recent, snapshots: snapshots, now: now), now: now)
            .filter { $0.kind == .projectedExhaustion }
    }

    /// Builds the advisor's view from stored history and the current snapshots.
    ///
    /// Labels come from the live snapshots because they are display data that
    /// changes; everything matched on is the window key.
    public static func inputs(history: [UsageSample], snapshots: [QuotaSnapshot],
                              now: Date = Date()) -> [AdvisorInput] {
        let cycles = Dictionary(grouping: UsageAnalysis.cycles(for: history), by: \.series)
        let samples = Dictionary(grouping: history, by: \.series)
        var labels: [HistorySeriesID: String] = [:]
        for snapshot in snapshots {
            for window in snapshot.windows {
                labels[HistorySeriesID(provider: snapshot.provider, windowKey: window.key)] = window.label
            }
        }

        let series = Set(cycles.keys).union(samples.keys).union(labels.keys)
        return series.sorted { UsageAnalysis.order($0) < UsageAnalysis.order($1) }.map { one in
            let mine = samples[one]?.sorted { $0.at < $1.at } ?? []
            return AdvisorInput(series: one,
                                windowLabel: labels[one] ?? one.windowKey,
                                cycles: cycles[one] ?? [],
                                latest: mine.last,
                                burnRatePerHour: UsageAnalysis.burnRate(mine, now: now))
        }
    }
}
