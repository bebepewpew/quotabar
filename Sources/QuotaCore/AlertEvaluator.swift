import Foundation

public enum AlertLevel: String, Sendable, CaseIterable {
    case warning, critical
    /// Not a threshold on the current reading but on where it is heading: the
    /// window is on course to run out before it resets. Only the advisor raises
    /// it, so `init?(usedPercent:)` never returns it.
    case projected

    public init?(usedPercent: Double) {
        if usedPercent >= 95 { self = .critical }
        else if usedPercent >= 80 { self = .warning }
        else { return nil }
    }

    public var title: String {
        switch self {
        case .critical: "almost exhausted"
        case .warning: "running low"
        case .projected: "on course to run out early"
        }
    }
}

public struct QuotaAlert: Sendable, Equatable {
    public let identifier: String
    public let provider: Provider
    public let level: AlertLevel
    public let title: String
    public let body: String
}

/// Everything one alert is deduplicated on, kept apart from the string so the
/// evaluator can also ask about the reset period next door.
///
/// The reset contributes the one-hour period it falls in, not the second it names.
/// Gemini's `resetAt` is `now +` an interval reparsed from relative text such as
/// `Resets: 10:01 AM (16h 14m)` on every probe, so it lands on a different second
/// every time and an identifier built from that second never matched the one
/// stored fifteen minutes earlier. `UsageAnalysis.isCycleBoundary` absorbs the
/// same drift with the same one-hour floor.
struct AlertIdentity: Sendable {
    /// One period of reset drift, the floor `UsageAnalysis.isCycleBoundary` uses.
    static let period: TimeInterval = 3_600

    /// Provider and window key: stable identity, never the label.
    let prefix: String
    /// Which one-hour period the reset falls in, or `nil` for a window that
    /// reports no reset at all.
    let periodIndex: Int?
    let level: AlertLevel

    init(provider: Provider, windowKey: String, resetAt: Date?, level: AlertLevel) {
        prefix = "quota.\(provider.id).\(windowKey)"
        periodIndex = resetAt.map(Self.periodIndex(of:))
        self.level = level
    }

    /// The identifier for this alert, or for the one `offsetBy` periods away.
    func identifier(offsetBy periods: Int = 0) -> String {
        let component = periodIndex.map { String(($0 + periods) * Int(Self.period)) } ?? "no-reset"
        return "\(prefix).\(component).\(level.rawValue)"
    }

    /// Identifiers that all mean "this cycle has already been alerted about".
    ///
    /// Drift of up to an hour can still straddle a period boundary, which would
    /// otherwise raise a second alert for one cycle, so a delivery recorded for
    /// either neighbouring period counts. Nothing real resets that soon: the
    /// shortest quota window any supported provider publishes is five hours, so
    /// a genuine reset always moves the period by more than one.
    var deliveredIdentifiers: [String] {
        guard periodIndex != nil else { return [identifier()] }
        return [identifier(), identifier(offsetBy: -1), identifier(offsetBy: 1)]
    }

    /// The reset floored to a whole period.
    ///
    /// Clamped because the reset is derived from untrusted CLI output: a probe
    /// that reads `resets in 99999999999999d` produces an enormous or infinite
    /// interval, and converting that straight to `Int` traps.
    private static func periodIndex(of reset: Date) -> Int {
        let periods = (reset.timeIntervalSince1970 / period).rounded(.down)
        guard periods.isFinite else { return 0 }
        return Int(min(max(periods, -1_000_000_000), 1_000_000_000))
    }
}

/// Decides which threshold notifications are due and remembers which have already
/// been delivered. Shared by the macOS `UserNotifications` sink and the Linux
/// `notify-send` sink so both platforms alert identically.
public actor AlertEvaluator {
    /// Bumped from `.v3` when the reset component of the identifier moved off the
    /// exact epoch second onto the one-hour period of `AlertIdentity`. Every v3
    /// entry names a second, so it can never match a v4 identifier; the old blob
    /// is abandoned deliberately, exactly as the v2 blob was when the identifier
    /// moved off `window.label` onto `window.key`. Dropping it also discards the
    /// entries the drifting identifier churned out, which were on course to evict
    /// live Claude and Codex entries through the trim. The one visible consequence
    /// is that a window already over a threshold alerts once more on the first run
    /// after upgrading.
    public static let deliveredKey = "QuotaBar.deliveredQuotaNotifications.v4"

    private let store: StateStore
    private var delivered: [String: Date]

    public init(store: StateStore = StateStoreFactory.makeDefault()) {
        self.store = store
        delivered = store.data(forKey: Self.deliveredKey)
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }

    /// Alerts crossing a threshold that have not been delivered for this provider,
    /// window, reset period and level yet.
    public func pending(for snapshots: [QuotaSnapshot], now: Date = Date()) -> [QuotaAlert] {
        Self.evaluate(snapshots, now: now).filter { !isDelivered($0.identity) }.map(\.alert)
    }

    public func markDelivered(_ alert: QuotaAlert, at now: Date = Date()) {
        delivered[alert.identifier] = now
        trimAndPersist()
    }

    public func hasDelivered(_ identifier: String) -> Bool { delivered[identifier] != nil }

    /// Whether this cycle has already been alerted about, counting a delivery
    /// recorded for a reset one period away as the same cycle.
    private func isDelivered(_ identity: AlertIdentity) -> Bool {
        identity.deliveredIdentifiers.contains { delivered[$0] != nil }
    }

    /// Pure threshold evaluation, dedup aside. Snapshots carrying an error are
    /// skipped: a stale cached value must not raise a fresh alarm.
    public static func alerts(for snapshots: [QuotaSnapshot], now: Date = Date()) -> [QuotaAlert] {
        evaluate(snapshots, now: now).map(\.alert)
    }

    /// The alerts plus what each is deduplicated on, which `pending(for:now:)`
    /// needs and callers of `alerts(for:now:)` do not.
    static func evaluate(_ snapshots: [QuotaSnapshot],
                         now: Date = Date()) -> [(alert: QuotaAlert, identity: AlertIdentity)] {
        snapshots.filter { $0.error == nil }.flatMap { snapshot in
            snapshot.windows.compactMap { window -> (alert: QuotaAlert, identity: AlertIdentity)? in
                guard let level = AlertLevel(usedPercent: window.usedPercent) else { return nil }
                let identity = AlertIdentity(provider: snapshot.provider, windowKey: window.key,
                                             resetAt: window.resetAt, level: level)
                return (QuotaAlert(
                    identifier: identity.identifier(),
                    provider: snapshot.provider,
                    level: level,
                    title: "\(snapshot.provider.rawValue) quota is \(level.title)",
                    body: body(for: window, now: now)
                ), identity)
            }
        }
    }

    /// Composed from `window.key`, not `window.label`: the key is stable identity
    /// and the label is display data a vendor can reword in any release. Keying on
    /// the label made a reworded window look brand new — re-alerting at 80% and 95%
    /// though its key never moved — and made two windows whose labels collided
    /// share one entry, silencing the second.
    ///
    /// The reset contributes the one-hour period it falls in rather than its exact
    /// second, so a reset a provider recomputes on every probe still names one
    /// cycle. See `AlertIdentity`.
    public static func identifier(provider: Provider, window: QuotaWindow, level: AlertLevel) -> String {
        AlertIdentity(provider: provider, windowKey: window.key,
                      resetAt: window.resetAt, level: level).identifier()
    }

    private static func body(for window: QuotaWindow, now: Date) -> String {
        let usage = QuotaFormatting.percent(window.usedPercent)
        guard let reset = window.resetAt else { return "\(window.label) limit is \(usage) used." }
        return "\(window.label) limit is \(usage) used and resets \(QuotaFormatting.relativeReset(reset, from: now))."
    }

    private func trimAndPersist() {
        if delivered.count > 500 {
            delivered = Dictionary(uniqueKeysWithValues:
                delivered.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(delivered) else { return }
        store.setData(data, forKey: Self.deliveredKey)
    }
}

/// Where a front-end actually shows an alert.
public protocol QuotaNotificationSink: Sendable {
    /// Returns `true` when the alert reached the user; only then is it recorded as
    /// delivered, so a failed notification is retried on the next refresh.
    func deliver(_ alert: QuotaAlert) async -> Bool
}

extension AlertEvaluator {
    /// Evaluate, deliver through `sink`, and record what landed.
    public func dispatch(_ snapshots: [QuotaSnapshot], through sink: some QuotaNotificationSink,
                         now: Date = Date()) async {
        for alert in pending(for: snapshots, now: now) where await sink.deliver(alert) {
            markDelivered(alert, at: now)
        }
    }

    /// The advisor's forecasts as alerts, deduplicated and delivered exactly like
    /// the threshold ones.
    public func dispatch(projections: [Recommendation], through sink: some QuotaNotificationSink,
                         now: Date = Date()) async {
        for (alert, identity) in Self.evaluate(projections: projections) where !isDelivered(identity) {
            if await sink.deliver(alert) { markDelivered(alert, at: now) }
        }
    }

    /// Turns `projectedExhaustion` recommendations into alerts.
    ///
    /// The identifier is keyed on the cycle the forecast is about, not on the
    /// forecast itself. A projection is recomputed every refresh and would
    /// otherwise re-fire every fifteen minutes for the same window.
    public static func projectedAlerts(for recommendations: [Recommendation]) -> [QuotaAlert] {
        evaluate(projections: recommendations).map(\.alert)
    }

    /// The forecast alerts plus what each is deduplicated on. The cycle a forecast
    /// is about is identified by its reset period, for the same reason the
    /// threshold path is: the advisor reads a reset the probe recomputed.
    static func evaluate(projections: [Recommendation]) -> [(alert: QuotaAlert, identity: AlertIdentity)] {
        projections.filter { $0.kind == .projectedExhaustion }.map { recommendation in
            let identity = AlertIdentity(provider: recommendation.series.provider,
                                         windowKey: recommendation.series.windowKey,
                                         resetAt: recommendation.cycleResetAt,
                                         level: .projected)
            return (QuotaAlert(
                identifier: identity.identifier(),
                provider: recommendation.series.provider,
                level: .projected,
                title: "\(recommendation.series.provider.rawValue) quota is \(AlertLevel.projected.title)",
                body: recommendation.evidence.joined(separator: ", ") + "."), identity)
        }
    }
}
