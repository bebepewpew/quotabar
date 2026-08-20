import Foundation
import Combine

@MainActor
final class QuotaStore: ObservableObject {
    @Published var snapshots: [QuotaSnapshot]
    @Published private(set) var installedProviders: [Provider]
    @Published private(set) var isDiscoveringTools = true
    @Published var isRefreshing = false
    @Published var menuBarSelections: [QuotaSelection] {
        didSet {
            if let data = try? JSONEncoder().encode(menuBarSelections) { defaults.set(data, forKey: Self.menuBarKey) }
        }
    }
    @Published var refreshIntervalMinutes: Int {
        didSet {
            guard refreshIntervalMinutes != oldValue else { return }
            defaults.set(refreshIntervalMinutes, forKey: Self.intervalKey)
            if hasStarted { scheduleRefreshes() }
        }
    }
    private var schedulerTask: Task<Void, Never>?
    private var hasStarted = false
    private let defaults: UserDefaults
    private var persistedSnapshots: [Provider: QuotaSnapshot]
    private static let cacheKey = "QuotaBar.cachedSnapshots.v1"
    private static let intervalKey = "QuotaBar.refreshIntervalMinutes"
    private static let menuBarKey = "QuotaBar.menuBarSelections.v1"
    static let refreshIntervals = [0, 5, 15, 30, 60]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        installedProviders = []
        snapshots = []
        let savedInterval = defaults.object(forKey: Self.intervalKey) as? Int
        refreshIntervalMinutes = Self.refreshIntervals.contains(savedInterval ?? 15) ? (savedInterval ?? 15) : 15
        menuBarSelections = defaults.data(forKey: Self.menuBarKey)
            .flatMap { try? JSONDecoder().decode([QuotaSelection].self, from: $0) }
            .map { Array($0.prefix(3)) } ?? []
        let cached = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode([QuotaSnapshot].self, from: $0) } ?? []
        persistedSnapshots = Dictionary(cached.map { ($0.provider, $0) }, uniquingKeysWith: { _, newest in newest })
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let values = await withTaskGroup(of: QuotaSnapshot.self) { group in
                for provider in installedProviders {
                    group.addTask { await Self.loadAsync(provider) }
                }
                var output: [QuotaSnapshot] = []
                for await value in group { output.append(value) }
                return output.sorted {
                    (Provider.allCases.firstIndex(of: $0.provider) ?? 0) < (Provider.allCases.firstIndex(of: $1.provider) ?? 0)
                }
            }
            let previous = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })
            snapshots = values.map { fresh in
                guard !fresh.probeSucceeded, let old = previous[fresh.provider], !old.windows.isEmpty else { return fresh }
                var retained = old
                retained.error = fresh.error.map { "Refresh failed: \($0)" }
                retained.probeSucceeded = false
                return retained
            }
            migrateMenuBarSelections()
            persistSuccessfulSnapshots()
            isRefreshing = false
            let successful = values.filter { $0.error == nil && !$0.windows.isEmpty }
            Task { await QuotaNotifier.shared.evaluate(successful) }
        }
    }

    func startScheduler() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            let providers = await Self.discoverProviders()
            installedProviders = providers
            snapshots = providers.map { persistedSnapshots[$0] ?? .loading($0) }
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
            return (selection, window?.usedPercent, Self.preferredBadge(for: selection))
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

    private func persistSuccessfulSnapshots() {
        for snapshot in snapshots where snapshot.probeSucceeded {
            guard !snapshot.windows.isEmpty else {
                persistedSnapshots.removeValue(forKey: snapshot.provider)
                continue
            }
            var cached = snapshot
            cached.error = nil
            persistedSnapshots[snapshot.provider] = cached
        }
        guard let data = try? JSONEncoder().encode(Array(persistedSnapshots.values)) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }

    private func migrateMenuBarSelections() {
        menuBarSelections = menuBarSelections.map { saved in
            guard let window = snapshots.first(where: { $0.provider == saved.provider })?.windows.first(where: {
                $0.key == saved.windowKey || $0.label == saved.windowLabel
            }) else { return saved }
            return QuotaSelection(provider: saved.provider, windowKey: window.key, windowLabel: window.label)
        }
    }

    nonisolated private static func load(_ provider: Provider) -> QuotaSnapshot {
        do {
            switch provider {
            case .codex: return try CodexProbe().fetch()
            case .claude: return try ClaudePrintProbe().fetch()
            case .gemini: return try GeminiTerminalProbe().fetch()
            }
        } catch { return .init(provider: provider, error: error.localizedDescription, probeSucceeded: false) }
    }

    nonisolated static func preferredBadge(for selection: QuotaSelection) -> String {
        let value = "\(selection.windowKey) \(selection.windowLabel)".lowercased()
        if selection.provider != .gemini { return value.contains("week") ? "W" : "S" }
        if value.contains("flash-lite") || value.contains("flash lite") { return "L" }
        if value.contains("flash") { return "F" }
        if value.contains("pro") { return "P" }
        return "G"
    }

    nonisolated private static func loadAsync(_ provider: Provider) async -> QuotaSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: load(provider))
            }
        }
    }

    nonisolated private static func discoverProviders() async -> [Provider] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let installed = Provider.allCases.filter { provider in
                    let executable = switch provider { case .gemini: "gemini"; case .claude: "claude"; case .codex: "codex" }
                    return CommandRunner.find(executable) != nil
                }
                continuation.resume(returning: installed)
            }
        }
    }
}
