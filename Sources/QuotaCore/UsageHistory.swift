import Foundation

/// One quota cycle reconstructed from the samples that fell inside it.
///
/// A cycle is the span between two resets. Providers do not report cycle
/// identity, only a level and a reset time, so cycles are inferred — see
/// `UsageAnalysis.isCycleBoundary(previous:current:)`.
public struct CycleSummary: Sendable, Equatable {
    public let series: HistorySeriesID
    public let startedAt: Date
    public let endedAt: Date
    public let peakPercent: Double
    /// How much of the cycle we actually watched, 0…1. A closed laptop makes
    /// this small, and every recommendation is gated on it.
    public let observedFraction: Double
    public let sampleCount: Int
    /// Both boundaries observed. The first cycle in a history is not complete —
    /// we joined it partway through and cannot know what its peak was.
    public let isComplete: Bool

    public init(series: HistorySeriesID, startedAt: Date, endedAt: Date, peakPercent: Double,
                observedFraction: Double, sampleCount: Int, isComplete: Bool) {
        self.series = series
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.peakPercent = peakPercent
        self.observedFraction = observedFraction
        self.sampleCount = sampleCount
        self.isComplete = isComplete
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// The arithmetic over stored samples: which ones are worth keeping, where one
/// cycle ends and the next begins, and how fast the current one is burning.
///
/// Every function here is pure and takes `now` explicitly, so the whole of it is
/// testable without a clock or a file.
public enum UsageAnalysis {
    /// A reading has to move at least this far to be worth storing. Providers
    /// report one decimal place, so this is two reportable steps.
    public static let deadbandPercent = 0.5
    /// Store something at least this often even when nothing moved, so a flat
    /// stretch is distinguishable from an interval where nothing was sampled.
    public static let heartbeat: TimeInterval = 3_600
    /// How long one sample vouches for. Twice the heartbeat, so the deadband
    /// suppressing a repeat reading never looks like a gap in coverage.
    public static let coverageCredit: TimeInterval = 7_200

    // MARK: - Admission

    /// Whether `candidate` is worth appending given the last stored reading.
    ///
    /// Usage only rises inside a cycle, so the last stored value is always at
    /// least as large as anything the deadband suppressed — dropping repeats can
    /// never lose a peak.
    public static func isAdmissible(_ candidate: UsageSample, after previous: UsageSample?) -> Bool {
        guard let previous else { return true }
        // A sample that is not newer than the last one cannot extend the series.
        guard candidate.at > previous.at else { return false }
        if abs(candidate.usedPercent - previous.usedPercent) >= deadbandPercent { return true }
        if candidate.at.timeIntervalSince(previous.at) >= heartbeat { return true }
        return isCycleBoundary(previous: previous, current: candidate)
    }

    // MARK: - Cycle boundaries

    /// Whether the window reset between these two readings.
    ///
    /// `resetAt` alone cannot answer this. Gemini's is parsed from text like
    /// "resets in 5h" into `now + interval`, so it drifts by up to the printed
    /// granularity on every probe and is never equal twice.
    public static func isCycleBoundary(previous: UsageSample, current: UsageSample) -> Bool {
        // 1. Usage fell far enough that it cannot be rounding or a rolling
        //    window decaying. Both conditions, or a drop from 100 to 60 would
        //    read as a reset.
        if current.usedPercent <= previous.usedPercent - 5,
           current.usedPercent <= previous.usedPercent * 0.5 { return true }

        if let previousReset = previous.resetAt {
            // 2. The reset moved forward by more than the time it replaced. The
            //    one-hour floor absorbs Gemini's drift; every real window is at
            //    least five hours, so a true reset always clears it.
            if let currentReset = current.resetAt {
                let remaining = previousReset.timeIntervalSince(previous.at)
                let tolerance = max(3_600, remaining * 0.5)
                if currentReset.timeIntervalSince(previousReset) > tolerance { return true }
            }
            // 3. We are past the reset we last knew about. This is the only rule
            //    that fires for a window that sat at 0% across its own reset,
            //    where there is no drop to observe.
            if current.at > previousReset.addingTimeInterval(60) { return true }
        }
        return false
    }

    // MARK: - Segmentation

    /// Splits samples into cycles, newest last, for every series present.
    public static func cycles(for samples: [UsageSample]) -> [CycleSummary] {
        Dictionary(grouping: samples, by: \.series)
            .sorted { order($0.key) < order($1.key) }
            .flatMap { cycles(forOneSeries: $0.value.sorted { $0.at < $1.at }) }
    }

    private static func cycles(forOneSeries samples: [UsageSample]) -> [CycleSummary] {
        guard !samples.isEmpty else { return [] }
        var summaries: [CycleSummary] = []
        var current: [UsageSample] = []
        // The end of the previous cycle, which is the only trustworthy start for
        // the next one: the first sample of a cycle may arrive long after it began.
        var knownStart: Date?

        for sample in samples {
            if let last = current.last, isCycleBoundary(previous: last, current: sample) {
                let closed = closingInstant(last: last, next: sample)
                summaries.append(summarise(current, start: knownStart, end: closed,
                                           isComplete: knownStart != nil))
                knownStart = closed
                current = []
            }
            current.append(sample)
        }
        if let last = current.last {
            // Still running: no closing boundary, so never complete.
            summaries.append(summarise(current, start: knownStart, end: last.at, isComplete: false))
        }
        return summaries
    }

    /// When the cycle actually ended. The provider's own reset time is the best
    /// answer, clamped between the readings that bracket it so a stale or absurd
    /// value cannot push a cycle boundary outside the samples that produced it.
    private static func closingInstant(last: UsageSample, next: UsageSample) -> Date {
        guard let reset = last.resetAt else { return next.at }
        return min(max(reset, last.at), next.at)
    }

    private static func summarise(_ samples: [UsageSample], start: Date?, end: Date,
                                  isComplete: Bool) -> CycleSummary {
        let first = samples[0]
        let startedAt = start ?? first.at
        let span = max(end.timeIntervalSince(startedAt), 1)

        // Each sample vouches for the time until the next one, capped: a reading
        // an hour old still describes the window, one from last Tuesday does not.
        // Time before the first sample is vouched for by nobody and scores zero,
        // which is what makes a cycle we joined late read as poorly observed.
        var covered: TimeInterval = 0
        for (index, sample) in samples.enumerated() {
            let next = index + 1 < samples.count ? samples[index + 1].at : end
            covered += min(max(next.timeIntervalSince(sample.at), 0), coverageCredit)
        }

        return CycleSummary(series: first.series,
                            startedAt: startedAt,
                            endedAt: end,
                            peakPercent: samples.map(\.usedPercent).max() ?? 0,
                            observedFraction: min(1, covered / span),
                            sampleCount: samples.count,
                            isComplete: isComplete)
    }

    // MARK: - Burn rate

    /// Percentage points consumed per hour, or nil when there is not enough to
    /// say. Theil–Sen — the median of every pairwise slope — because the deadband
    /// turns usage into steps and plateaus, and a single step dominates least
    /// squares while barely moving a median.
    public static func burnRate(_ samples: [UsageSample], now: Date,
                                window: TimeInterval = 3 * 3_600,
                                maximumSamples: Int = 32) -> Double? {
        let recent = samples.filter { $0.at > now.addingTimeInterval(-window) && $0.at <= now }
            .sorted { $0.at < $1.at }
            .suffix(maximumSamples)
        guard recent.count >= 2 else { return nil }

        var slopes: [Double] = []
        for (offset, earlier) in recent.enumerated() {
            for later in recent.dropFirst(offset + 1) {
                let hours = later.at.timeIntervalSince(earlier.at) / 3_600
                guard hours > 0 else { continue }
                slopes.append((later.usedPercent - earlier.usedPercent) / hours)
            }
        }
        return median(slopes)
    }

    /// When the window is on course to hit 100%, or nil when it is not moving.
    public static func projectedExhaustion(from latest: UsageSample, burnRatePerHour: Double) -> Date? {
        guard burnRatePerHour > 0, latest.usedPercent < 100 else { return nil }
        let hours = (100 - latest.usedPercent) / burnRatePerHour
        guard hours.isFinite, hours >= 0 else { return nil }
        return latest.at.addingTimeInterval(hours * 3_600)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// The percentile of a set of readings, nearest-rank. Used for "even the
    /// busiest cycle stayed low", where the mean would let one quiet week hide a
    /// busy one.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    /// Stable ordering for series, so every list this module produces is
    /// reproducible: provider declaration order, then window key.
    static func order(_ series: HistorySeriesID) -> String {
        let index = Provider.allCases.firstIndex(of: series.provider) ?? 0
        return "\(index)|\(series.windowKey)"
    }
}

// MARK: - Recording

/// Turns refreshed snapshots into stored samples.
///
/// Front-end agnostic on purpose: the macOS app, `quotabar --watch`, a one-shot
/// invocation and a future Linux tray all call `record` after a refresh and get
/// the same deadband, the same retention and the same file.
public final class UsageRecorder: @unchecked Sendable {
    private let store: any HistoryStore
    private let horizon: TimeInterval
    private let lock = NSLock()
    private var heads: [HistorySeriesID: UsageSample]?

    public init(store: any HistoryStore, horizon: TimeInterval = FileHistoryStore.defaultHorizon) {
        self.store = store
        self.horizon = horizon
    }

    public convenience init(stateStore: StateStore = StateStoreFactory.makeDefault()) {
        self.init(store: FileHistoryStore(store: stateStore))
    }

    /// Records what is worth recording and reports how many samples landed.
    ///
    /// Snapshots carrying an error are dropped here rather than at the call site.
    /// `QuotaEngine.retainingLastGood` re-serves the previous windows when a probe
    /// fails, and storing those would write a flat line the user never actually
    /// used — inflating coverage and understating the burn rate.
    @discardableResult
    public func record(_ snapshots: [QuotaSnapshot], now: Date = Date()) -> Int {
        let candidates = Self.samples(from: snapshots, now: now)
        guard !candidates.isEmpty else { return 0 }

        let admitted: [UsageSample] = lock.withLock {
            var known = heads ?? store.heads()
            var keep: [UsageSample] = []
            for candidate in candidates where UsageAnalysis.isAdmissible(candidate, after: known[candidate.series]) {
                known[candidate.series] = candidate
                keep.append(candidate)
            }
            heads = known
            return keep
        }
        guard !admitted.isEmpty else { return 0 }

        let written = store.append(admitted)
        // Retention runs after the append and only when the file has actually
        // aged, so the common refresh costs one write and one header read.
        if store.needsCompaction(now: now, horizon: horizon) {
            store.compact(now: now, horizon: horizon)
        }
        return written
    }

    /// One timestamp for the whole batch. A refresh probes every provider
    /// concurrently and finishes within seconds, so aligning the series on one
    /// instant is both more accurate than per-snapshot times and what lets
    /// buckets and cycle spans line up across providers.
    static func samples(from snapshots: [QuotaSnapshot], now: Date) -> [UsageSample] {
        snapshots
            .filter { $0.probeSucceeded && $0.error == nil && !$0.windows.isEmpty }
            .flatMap { snapshot in
                snapshot.windows.map { window in
                    UsageSample(series: HistorySeriesID(provider: snapshot.provider, windowKey: window.key),
                                at: now,
                                usedPercent: window.usedPercent,
                                resetAt: window.resetAt)
                }
            }
    }
}
