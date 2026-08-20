import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Small persistence seam so the same caching and notification-dedup code runs on
/// both platforms. macOS keeps using `UserDefaults` (preserving existing keys and
/// therefore existing user settings); Linux writes an XDG JSON file, because
/// `UserDefaults` on swift-corelibs-foundation has no dependable backing store.
public protocol StateStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
    func integer(forKey key: String) -> Int?
    func setInteger(_ value: Int?, forKey key: String)
}

public enum StateStoreFactory {
    public static func makeDefault() -> StateStore {
        #if os(macOS)
        return UserDefaultsStateStore()
        #else
        return JSONFileStateStore()
        #endif
    }
}

public final class UserDefaultsStateStore: StateStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func setData(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
    public func integer(forKey key: String) -> Int? { defaults.object(forKey: key) as? Int }
    public func setInteger(_ value: Int?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// JSON-backed store at `${XDG_CONFIG_HOME:-~/.config}/quotabar/state.json`.
/// `Data` values are base64-encoded so the file stays valid JSON.
///
/// A `--watch` process and a one-shot invocation can run at once, so writes
/// re-read the file under an exclusive lock and apply only the keys this instance
/// actually changed. Without that, a long-lived watcher would rewrite its
/// start-of-process snapshot over the other process's keys and, in particular,
/// discard the notification dedup map — re-delivering alerts already shown.
public final class JSONFileStateStore: StateStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var contents: [String: JSONValue]
    private var written: Set<String> = []

    /// Named per platform rather than "macOS or else", so a future Windows
    /// front-end does not silently inherit XDG paths.
    public static func defaultURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base: URL
        #if os(Windows)
        if let appData = environment["APPDATA"], !appData.isEmpty {
            base = URL(fileURLWithPath: appData, isDirectory: true)
        } else {
            base = home.appendingPathComponent("AppData", isDirectory: true)
                .appendingPathComponent("Roaming", isDirectory: true)
        }
        #else
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".config", isDirectory: true)
        }
        #endif
        return base.appendingPathComponent("quotabar", isDirectory: true).appendingPathComponent("state.json")
    }

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        contents = Self.read(self.url)
    }

    public func data(forKey key: String) -> Data? {
        lock.withLock {
            guard case .string(let encoded) = contents[key] else { return nil }
            return Data(base64Encoded: encoded)
        }
    }

    public func setData(_ data: Data?, forKey key: String) {
        lock.withLock {
            contents[key] = data.map { .string($0.base64EncodedString()) }
            written.insert(key)
            persistLocked()
        }
    }

    public func integer(forKey key: String) -> Int? {
        lock.withLock {
            guard case .int(let value) = contents[key] else { return nil }
            return value
        }
    }

    public func setInteger(_ value: Int?, forKey key: String) {
        lock.withLock {
            contents[key] = value.map { .int($0) }
            written.insert(key)
            persistLocked()
        }
    }

    private static func read(_ url: URL) -> [String: JSONValue] {
        (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
    }

    /// Best effort: a state file we cannot write costs a cached snapshot, never a
    /// refresh. Callers keep working with in-memory values.
    private func persistLocked() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        withFileLock {
            var merged = Self.read(url)
            for key in written { merged[key] = contents[key] }
            guard let encoded = try? JSONEncoder().encode(merged) else { return }
            try? encoded.write(to: url, options: .atomic)
            // Adopt the other process's keys so later reads are not stale.
            contents = merged
        }
    }

    /// Advisory lock on a sidecar file — the state file itself is replaced by an
    /// atomic rename, which would leave each writer holding a different inode.
    private func withFileLock(_ body: () -> Void) {
        #if os(Windows)
        // `flock` is POSIX-only; `LockFileEx` is the equivalent and belongs with a
        // Windows front-end. The read-merge-write above already prevents the
        // stale-snapshot clobber; the lock only closes the interleaving window.
        body()
        #else
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return body() }
        defer { flock(descriptor, LOCK_UN) }
        body()
        #endif
    }

    private enum JSONValue: Codable {
        case string(String), int(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) { self = .int(value) }
            else { self = .string(try container.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            }
        }
    }
}
