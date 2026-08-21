import Foundation
import Combine
import QuotaCore

/// SwiftUI-facing shell around `QuotaCore.QuotaEngine`. Everything that does not
/// need `@Published` or `@MainActor` now lives in the shared core so the Linux CLI
/// runs the same discovery, probing and retention logic.
@MainActor
final class QuotaStore: ObservableObject {
    @Published var snapshots: [QuotaSnapshot]
    @Published private(set) var installedProviders: [Provider]
    @Published private(set) var isDiscoveringTools = true
    @Published var isRefreshing = false
    @Published var menuBarSelections: [QuotaSelection] {
        didSet {
            if let data = try? JSONEncoder().encode(menuBarSelections) { store.setData(data, forKey: Self.menuBarKey) }
        }
    }
    @Published var refreshIntervalMinutes: Int {
        didSet {
            guard refreshIntervalMinutes != oldValue else { return }
            store.setInteger(refreshIntervalMinutes, forKey: Self.intervalKey)
            if hasStarted { scheduleRefreshes() }
        }
    }
    /// Recorded usage for the sparkline strip and the advisor panel. Recomputed
    /// after every refresh rather than held live, so the app never keeps three
    /// months of samples resident.
    @Published private(set) var recommendations: [Recommendation] = []
    @Published private(set) var recentUsage: [HistorySeriesID: [Double?]] = [:]
    /// The span the sparklines cover, so the caption can say what it is.
    static let sparklineSpan: TimeInterval = 7 * 86_400

    private var schedulerTask: Task<Void, Never>?
    private var hasStarted = false
    private let store: StateStore
    private let cache: SnapshotCache
    private let history: FileHistoryStore
    private let recorder: UsageRecorder
    private static let intervalKey = "QuotaBar.refreshIntervalMinutes"
    private static let menuBarKey = "QuotaBar.menuBarSelections.v1"
    static let refreshIntervals = QuotaEngine.refreshIntervals

    init(store: StateStore = StateStoreFactory.makeDefault()) {
        self.store = store
        cache = SnapshotCache(store: store)
        history = FileHistoryStore(store: store)
        recorder = UsageRecorder(store: history)
        installedProviders = []
        snapshots = []
        let savedInterval = store.integer(forKey: Self.intervalKey)
        refreshIntervalMinutes = Self.refreshIntervals.contains(savedInterval ?? 15) ? (savedInterval ?? 15) : 15
        menuBarSelections = store.data(forKey: Self.menuBarKey)
            .flatMap { try? JSONDecoder().decode([QuotaSelection].self, from: $0) }
            .map { Array($0.prefix(3)) } ?? []
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let values = await QuotaEngine.refresh(installedProviders)
            snapshots = QuotaEngine.retainingLastGood(fresh: values, previous: snapshots)
            migrateMenuBarSelections()
            cache.update(with: snapshots)
            // `values`, not `snapshots`: a retained snapshot is the previous
            // reading served again, and recording it would draw a flat line the
            // user never actually used.
            let successful = values.filter { $0.error == nil && !$0.windows.isEmpty }
            await reloadHistory(recording: successful)
            isRefreshing = false
            Task { await QuotaNotifier.shared.evaluate(successful) }
            Task { [recommendations] in await QuotaNotifier.shared.evaluate(projections: recommendations) }
        }
    }

    /// Records the refresh and recomputes what the UI shows from it. The file
    /// work happens off the main actor; only the results land back on it.
    private func reloadHistory(recording successful: [QuotaSnapshot]) async {
        let recorder = self.recorder
        let history = self.history
        let span = Self.sparklineSpan
        let current = snapshots
        let computed = await Task.detached(priority: .utility) { () -> ([Recommendation], [HistorySeriesID: [Double?]]) in
            recorder.record(successful)
            let now = Date()
            let all = history.read().samples
            let advice = Advisor.recommendations(
                for: Advisor.inputs(history: all, snapshots: current, now: now), now: now)
            let from = now.addingTimeInterval(-span)
            let strips = Dictionary(grouping: all.filter { $0.at >= from }, by: \.series)
                .mapValues { samples in
                    QuotaFormatting.buckets(samples.sorted { $0.at < $1.at }
                        .map { (at: $0.at, usedPercent: $0.usedPercent) },
                                            from: from, to: now, count: 32)
                }
            return (advice, strips)
        }.value
        recommendations = computed.0
        recentUsage = computed.1
    }

    /// Deletes every recorded sample. Surfaced in Settings so the privacy promise
    /// in the README has a button behind it.
    func clearHistory() {
        history.removeAll()
        recommendations = []
        recentUsage = [:]
    }

    func startScheduler() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            let providers = await QuotaEngine.discoverProviders()
            installedProviders = providers
            snapshots = providers.map { cache.snapshot(for: $0) ?? .loading($0) }
            isDiscoveringTools = false
            refresh()
            scheduleRefreshes()
        }
    }

    var availableMenuBarSelections: [QuotaSelection] {
        snapshots.flatMap { snapshot in snapshot.windows.map { QuotaSelection(provider: snapshot.provider, windowKey: $0.key, windowLabel: $0.label) } }
    }

    /// Includes saved choices that are temporarily absent from a probe result so
    /// model-specific toolbar preferences do not disappear during a partial refresh.
    var menuBarSelectionOptions: [QuotaSelection] {
        var options = availableMenuBarSelections
        for selection in menuBarSelections where !options.contains(selection) {
            options.append(selection)
        }
        return options
    }

    func isMenuBarSelectionAvailable(_ selection: QuotaSelection) -> Bool {
        availableMenuBarSelections.contains(selection)
    }

    var menuBarIndicators: [MenuBarQuota] {
        let base = menuBarSelections.map { selection in
            (selection, selection.window(in: snapshots)?.usedPercent, QuotaBadge.preferred(for: selection))
        }
        // Provider symbols already distinguish identical window badges across
        // providers. Number only collisions within the same provider.
        let groups = Dictionary(grouping: base.indices, by: { "\(base[$0].0.provider.id)|\(base[$0].2)" })
        return base.enumerated().map { index, item in
            let collisionKey = "\(item.0.provider.id)|\(item.2)"
            return MenuBarQuota(selection: item.0, usedPercent: item.1,
                                badge: (groups[collisionKey]?.count ?? 0) > 1 ? "\(index + 1)" : item.2)
        }
    }

    func setMenuBarSelection(_ selection: QuotaSelection, enabled: Bool) {
        if enabled {
            guard menuBarSelections.count < 3, !menuBarSelections.contains(selection) else { return }
            menuBarSelections.append(selection)
        } else {
            menuBarSelections.removeAll { $0 == selection }
        }
    }

    private func scheduleRefreshes() {
        schedulerTask?.cancel()
        schedulerTask = nil
        guard refreshIntervalMinutes > 0 else { return }
        let interval = refreshIntervalMinutes
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval * 60))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    /// Refreshes the stored display label of each saved selection from the latest
    /// probe result. Matching is on the window key alone, and the key is never
    /// rewritten — the result is persisted by `menuBarSelections.didSet`, so a
    /// selection bound to the wrong window here would outlive the render that
    /// produced it. Internal so the persisted half is directly testable.
    func migrateMenuBarSelections() {
        menuBarSelections = menuBarSelections.map { $0.refreshingLabel(in: snapshots) }
    }
}
