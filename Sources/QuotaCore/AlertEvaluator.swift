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

/// Decides which threshold notifications are due and remembers which have already
/// been delivered. Shared by the macOS `UserNotifications` sink and the Linux
/// `notify-send` sink so both platforms alert identically.
public actor AlertEvaluator {
    /// Bumped from `.v2` when the identifier moved off `window.label` onto the
    /// stable `window.key`. Every v2 entry was composed from display text, so it
    /// cannot be matched against a v3 identifier; the old blob is abandoned
    /// deliberately rather than left to mismatch silently. The one visible
    /// consequence is that a window already over a threshold alerts once more on
    /// the first run after upgrading.
    public static let deliveredKey = "QuotaBar.deliveredQuotaNotifications.v3"

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
        Self.alerts(for: snapshots, now: now).filter { delivered[$0.identifier] == nil }
    }

    public func markDelivered(_ alert: QuotaAlert, at now: Date = Date()) {
        delivered[alert.identifier] = now
        trimAndPersist()
    }

    public func hasDelivered(_ identifier: String) -> Bool { delivered[identifier] != nil }

    /// Pure threshold evaluation, dedup aside. Snapshots carrying an error are
    /// skipped: a stale cached value must not raise a fresh alarm.
    public static func alerts(for snapshots: [QuotaSnapshot], now: Date = Date()) -> [QuotaAlert] {
        snapshots.filter { $0.error == nil }.flatMap { snapshot in
            snapshot.windows.compactMap { window -> QuotaAlert? in
                guard let level = AlertLevel(usedPercent: window.usedPercent) else { return nil }
                return QuotaAlert(
                    identifier: identifier(provider: snapshot.provider, window: window, level: level),
                    provider: snapshot.provider,
                    level: level,
                    title: "\(snapshot.provider.rawValue) quota is \(level.title)",
                    body: body(for: window, now: now)
                )
            }
        }
    }

    /// Composed from `window.key`, not `window.label`: the key is stable identity
    /// and the label is display data a vendor can reword in any release. Keying on
    /// the label made a reworded window look brand new — re-alerting at 80% and 95%
    /// though its key never moved — and made two windows whose labels collided
    /// share one entry, silencing the second.
    ///
    /// The reset joins it as clamped whole seconds. Every window at 80% or above
    /// is named here, so identity has to exist even for one whose reset instant
    /// is further out than an `Int` can hold rather than trapping on it.
    public static func identifier(provider: Provider, window: QuotaWindow, level: AlertLevel) -> String {
        let period = window.resetAt.map { String(QuotaTime.epochSeconds($0)) } ?? "no-reset"
        return "quota.\(provider.id).\(window.key).\(period).\(level.rawValue)"
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
        for alert in Self.projectedAlerts(for: projections) where delivered[alert.identifier] == nil {
            if await sink.deliver(alert) { markDelivered(alert, at: now) }
        }
    }

    /// Turns `projectedExhaustion` recommendations into alerts.
    ///
    /// The identifier is keyed on the cycle the forecast is about, not on the
    /// forecast itself. A projection is recomputed every refresh and would
    /// otherwise re-fire every fifteen minutes for the same window.
    public static func projectedAlerts(for recommendations: [Recommendation]) -> [QuotaAlert] {
        recommendations.filter { $0.kind == .projectedExhaustion }.map { recommendation in
            QuotaAlert(
                identifier: "quota.\(recommendation.series.provider.id).\(recommendation.series.windowKey)."
                    + "\(cyclePeriod(of: recommendation)).\(AlertLevel.projected.rawValue)",
                provider: recommendation.series.provider,
                level: .projected,
                title: "\(recommendation.series.provider.rawValue) quota is \(AlertLevel.projected.title)",
                body: recommendation.evidence.joined(separator: ", ") + ".")
        }
    }

    /// The reset the forecast belongs to, so one cycle raises one alert. The
    /// advisor only emits this kind when there is a reset to compare against.
    private static func cyclePeriod(of recommendation: Recommendation) -> String {
        recommendation.cycleResetAt.map { String(QuotaTime.epochSeconds($0)) } ?? "no-reset"
    }
}
