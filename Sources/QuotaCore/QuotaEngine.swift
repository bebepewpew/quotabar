import Foundation

/// Provider discovery, probing and last-good retention — everything the macOS
/// menu bar and the Linux CLI both need, with no UI framework attached.
public enum QuotaEngine {
    public static let refreshIntervals = [0, 5, 15, 30, 60]

    /// Produces one provider's snapshot, or throws the reason it could not.
    /// `QuotaEngine.probe` is the real implementation; tests substitute a stub so
    /// discovery, probing and retention can be exercised without a provider CLI.
    public typealias SnapshotLoader = @Sendable (Provider) throws -> QuotaSnapshot

    /// Resolves a CLI name to an executable path, or `nil` when it is not installed.
    /// `CommandRunner.find` is the real implementation.
    public typealias ExecutableLocator = @Sendable (String) -> String?

    /// The default `SnapshotLoader`: the provider's real probe, errors and all.
    public static func probe(_ provider: Provider) throws -> QuotaSnapshot {
        switch provider {
        case .codex: return try CodexProbe().fetch()
        case .claude: return try ClaudePrintProbe().fetch()
        case .gemini: return try GeminiTerminalProbe().fetch()
        }
    }

    public static func discoverProviders(
        locate: @escaping ExecutableLocator = { CommandRunner.find($0) }
    ) async -> [Provider] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Provider.allCases.filter {
                    locate($0.executableName) != nil
                })
            }
        }
    }

    public static func load(
        _ provider: Provider,
        using loader: SnapshotLoader = { try QuotaEngine.probe($0) }
    ) -> QuotaSnapshot {
        do {
            return try loader(provider)
        } catch {
            return .init(provider: provider, error: error.localizedDescription, probeSucceeded: false)
        }
    }

    /// Probes block on subprocesses, so they run off the cooperative pool.
    public static func loadAsync(
        _ provider: Provider,
        using loader: @escaping SnapshotLoader = { try QuotaEngine.probe($0) }
    ) async -> QuotaSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: load(provider, using: loader))
            }
        }
    }

    /// Probes every provider concurrently and returns snapshots in `Provider.allCases` order.
    public static func refresh(
        _ providers: [Provider],
        using loader: @escaping SnapshotLoader = { try QuotaEngine.probe($0) }
    ) async -> [QuotaSnapshot] {
        await withTaskGroup(of: QuotaSnapshot.self) { group in
            for provider in providers { group.addTask { await loadAsync(provider, using: loader) } }
            var output: [QuotaSnapshot] = []
            for await value in group { output.append(value) }
            return output.sorted {
                (Provider.allCases.firstIndex(of: $0.provider) ?? 0) < (Provider.allCases.firstIndex(of: $1.provider) ?? 0)
            }
        }
    }

    /// A failed refresh keeps the previous values and reports the failure alongside
    /// them, rather than blanking the provider.
    public static func retainingLastGood(fresh: [QuotaSnapshot], previous: [QuotaSnapshot]) -> [QuotaSnapshot] {
        let lookup = Dictionary(previous.map { ($0.provider, $0) }, uniquingKeysWith: { _, newest in newest })
        return fresh.map { snapshot in
            guard !snapshot.probeSucceeded, let old = lookup[snapshot.provider], !old.windows.isEmpty else { return snapshot }
            var retained = old
            retained.error = snapshot.error.map { "Refresh failed: \($0)" }
            retained.probeSucceeded = false
            return retained
        }
    }
}

public enum QuotaBadge {
    public static func preferred(for selection: QuotaSelection) -> String {
        preferred(for: selection.provider, window: "\(selection.windowKey) \(selection.windowLabel)")
    }

    public static func preferred(for provider: Provider, window: String) -> String {
        let value = window.lowercased()
        if provider != .gemini { return value.contains("week") ? "W" : "S" }
        if value.contains("flash-lite") || value.contains("flash lite") { return "L" }
        if value.contains("flash") { return "F" }
        if value.contains("pro") { return "P" }
        return "G"
    }
}

/// Last successful snapshot per provider, so a cold start shows numbers immediately.
public final class SnapshotCache: @unchecked Sendable {
    public static let key = "QuotaBar.cachedSnapshots.v1"

    private let store: StateStore
    private let lock = NSLock()
    private var cached: [Provider: QuotaSnapshot]

    public init(store: StateStore = StateStoreFactory.makeDefault()) {
        self.store = store
        let decoded = store.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([QuotaSnapshot].self, from: $0) } ?? []
        cached = Dictionary(decoded.map { ($0.provider, $0) }, uniquingKeysWith: { _, newest in newest })
    }

    public func snapshot(for provider: Provider) -> QuotaSnapshot? { lock.withLock { cached[provider] } }

    public func all() -> [QuotaSnapshot] {
        lock.withLock {
            cached.values.sorted {
                (Provider.allCases.firstIndex(of: $0.provider) ?? 0) < (Provider.allCases.firstIndex(of: $1.provider) ?? 0)
            }
        }
    }

    /// Stores successful snapshots and drops providers that now report nothing.
    public func update(with snapshots: [QuotaSnapshot]) {
        lock.withLock {
            for snapshot in snapshots where snapshot.probeSucceeded {
                guard !snapshot.windows.isEmpty else {
                    cached.removeValue(forKey: snapshot.provider)
                    continue
                }
                var entry = snapshot
                entry.error = nil
                cached[snapshot.provider] = entry
            }
            guard let data = try? JSONEncoder().encode(Array(cached.values)) else { return }
            store.setData(data, forKey: Self.key)
        }
    }
}
