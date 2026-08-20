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
    private var schedulerTask: Task<Void, Never>?
    private var hasStarted = false
    private let store: StateStore
    private let cache: SnapshotCache
    private static let intervalKey = "QuotaBar.refreshIntervalMinutes"
    private static let menuBarKey = "QuotaBar.menuBarSelections.v1"
    static let refreshIntervals = QuotaEngine.refreshIntervals

    init(store: StateStore = StateStoreFactory.makeDefault()) {
        self.store = store
        cache = SnapshotCache(store: store)
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
            isRefreshing = false
            let successful = values.filter { $0.error == nil && !$0.windows.isEmpty }
            Task { await QuotaNotifier.shared.evaluate(successful) }
        }
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
            let window = snapshots.first(where: { $0.provider == selection.provider })?
                .windows.first(where: { $0.key == selection.windowKey || $0.label == selection.windowLabel })
            return (selection, window?.usedPercent, QuotaBadge.preferred(for: selection))
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

    private func migrateMenuBarSelections() {
        menuBarSelections = menuBarSelections.map { saved in
            guard let window = snapshots.first(where: { $0.provider == saved.provider })?.windows.first(where: {
                $0.key == saved.windowKey || $0.label == saved.windowLabel
            }) else { return saved }
            return QuotaSelection(provider: saved.provider, windowKey: window.key, windowLabel: window.label)
        }
    }
}
