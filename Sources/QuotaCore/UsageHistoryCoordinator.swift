import Foundation

/// What the history panel shows: the advisor's conclusions and the sparkline
/// cells behind them, recomputed together so both always describe the same read.
public struct UsageOverview: Sendable, Equatable {
    public let recommendations: [Recommendation]
    /// Bucketed percentages per series, oldest cell first, `nil` where the span
    /// holds no sample.
    public let strips: [HistorySeriesID: [Double?]]

    public static let empty = UsageOverview(recommendations: [], strips: [:])

    public init(recommendations: [Recommendation], strips: [HistorySeriesID: [Double?]]) {
        self.recommendations = recommendations
        self.strips = strips
    }
}

/// A token identifying how many times history has been cleared. A front-end
/// captures one before it starts a reload and compares it before it publishes
/// the result, so a clear that landed in between still wins.
public struct HistoryGeneration: Sendable, Equatable {
    fileprivate let clears: UInt64
    fileprivate init(clears: UInt64) { self.clears = clears }
}

/// Owns recording, reading back and deleting usage history for one front-end.
///
/// It exists because those three have to be ordered against each other. A
/// refresh appends and reads from a background task; the delete button is
/// pressed on the main actor. Without a common seam a clear that lands mid
/// refresh is republished from results computed before it, and the refresh goes
/// on to append samples into a file the user just deleted.
///
/// Everything here is blocking except `clear`'s synchronous half and
/// `generation`; run `reload` off the main actor.
public final class UsageHistoryCoordinator: @unchecked Sendable {
    /// How far back the sparklines reach.
    public static let sparklineSpan: TimeInterval = 7 * 86_400
    /// Cells in one sparkline.
    public static let sparklineBuckets = 32

    private let history: any HistoryStore
    private let recorder: UsageRecorder
    private let span: TimeInterval
    private let buckets: Int
    /// Serialises the record-and-read half of a reload against a removal, so a
    /// clear can never land between the append and the read that follows it.
    private let gate = NSLock()
    /// Guards `clears` only. Separate from `gate` because a clear has to be able
    /// to invalidate an in-flight reload without waiting for it to finish.
    private let counterLock = NSLock()
    private var clears: UInt64 = 0

    public init(history: any HistoryStore,
                recorder: UsageRecorder? = nil,
                span: TimeInterval = UsageHistoryCoordinator.sparklineSpan,
                buckets: Int = UsageHistoryCoordinator.sparklineBuckets) {
        self.history = history
        self.recorder = recorder ?? UsageRecorder(store: history)
        self.span = span
        self.buckets = buckets
    }

    /// The current generation. Cheap enough to read on the main actor.
    public var generation: HistoryGeneration {
        HistoryGeneration(clears: counterLock.withLock { clears })
    }

    /// Records the refresh and recomputes what the panel shows from everything
    /// stored, or returns `nil` when history was cleared after `generation` was
    /// captured.
    ///
    /// `nil` is not a failure; it means the caller asked about a history that no
    /// longer exists. Publishing the answer would put samples back on screen
    /// that the user just deleted, so the caller keeps its cleared state.
    ///
    /// Blocking: it reads the whole file. Call it off the main actor.
    public func reload(recording successful: [QuotaSnapshot],
                       snapshots: [QuotaSnapshot],
                       now: Date = Date(),
                       since generation: HistoryGeneration? = nil) -> UsageOverview? {
        let started = generation ?? self.generation
        let samples: [UsageSample]? = gate.withLock {
            // Checked inside the gate, where no removal can be running: a clear
            // that arrived while this reload waited for the lock has already
            // deleted the file, and recording now would put samples back into it.
            guard self.generation == started else { return nil }
            recorder.record(successful, now: now)
            return history.read().samples
        }
        guard let samples else { return nil }
        let overview = Self.overview(from: samples, snapshots: snapshots, now: now,
                                     span: span, buckets: buckets)
        // The advisor runs with the gate released, so a clear can still land
        // between the read and the return.
        return self.generation == started ? overview : nil
    }

    /// Deletes every recorded sample.
    ///
    /// Two halves, because they belong in two places. The synchronous half runs
    /// here, on whichever actor pressed the button: it bumps the generation, so
    /// a reload already in flight publishes nothing and one that has not
    /// recorded yet does not record at all. The returned half takes an exclusive
    /// file lock and unlinks, so a main-actor caller hands it to a detached task.
    ///
    /// Running the returned closure is not optional — dropping it invalidates
    /// the UI but leaves the file on disk.
    public func clear() -> @Sendable () -> Void {
        counterLock.withLock { clears &+= 1 }
        let gate = self.gate
        let history = self.history
        let recorder = self.recorder
        return {
            gate.withLock {
                history.removeAll()
                // The recorder's cached head describes a sample that no longer
                // exists; left in place, the deadband would drop the first
                // reading of the fresh history.
                recorder.forgetHeads()
            }
        }
    }

    /// The pure half: what a set of samples means, given the snapshots that name
    /// the windows. Split out so it can be checked without a store or a clock.
    public static func overview(from samples: [UsageSample], snapshots: [QuotaSnapshot],
                                now: Date, span: TimeInterval = sparklineSpan,
                                buckets: Int = sparklineBuckets) -> UsageOverview {
        let advice = Advisor.recommendations(
            for: Advisor.inputs(history: samples, snapshots: snapshots, now: now), now: now)
        let from = now.addingTimeInterval(-span)
        let strips = Dictionary(grouping: samples.filter { $0.at >= from }, by: \.series)
            .mapValues { series in
                QuotaFormatting.buckets(series.sorted { $0.at < $1.at }
                    .map { (at: $0.at, usedPercent: $0.usedPercent) },
                                        from: from, to: now, count: buckets)
            }
        return UsageOverview(recommendations: advice, strips: strips)
    }
}
