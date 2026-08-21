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
///
/// For the same reason a value this build cannot interpret — a bool, a null, a
/// nested container, a key a newer build wrote — is carried through that write
/// verbatim instead of being dropped along with every other key in the file.
/// The accessors still report such a value as absent.
public final class JSONFileStateStore: StateStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var contents: [String: JSONValue]
    private var written: Set<String> = []

    /// Which per-user configuration convention `defaultURL()` follows. Named per
    /// platform rather than "macOS or else", so a future Windows front-end does
    /// not silently inherit XDG paths.
    enum ConfigurationBase: Sendable {
        /// `${XDG_CONFIG_HOME:-~/.config}`.
        case xdg
        /// `%APPDATA%`, falling back to `~/AppData/Roaming`.
        case windowsAppData
    }

    static var platformBase: ConfigurationBase {
        #if os(Windows)
        .windowsAppData
        #else
        .xdg
        #endif
    }

    public static func defaultURL() -> URL {
        defaultURL(environment: ProcessInfo.processInfo.environment,
                   home: FileManager.default.homeDirectoryForCurrentUser,
                   base: platformBase)
    }

    /// The resolution itself, taking the environment and the convention as
    /// arguments. Selecting the convention at runtime rather than with `#if`
    /// keeps both platforms' rules compiled — and therefore testable — wherever
    /// the suite happens to run.
    static func defaultURL(environment: [String: String], home: URL,
                           base convention: ConfigurationBase) -> URL {
        let base: URL
        switch convention {
        case .windowsAppData:
            if let appData = environment["APPDATA"], !appData.isEmpty {
                base = URL(fileURLWithPath: appData, isDirectory: true)
            } else {
                base = home.appendingPathComponent("AppData", isDirectory: true)
                    .appendingPathComponent("Roaming", isDirectory: true)
            }
        case .xdg:
            if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
                base = URL(fileURLWithPath: xdg, isDirectory: true)
            } else {
                base = home.appendingPathComponent(".config", isDirectory: true)
            }
        }
        return base.appendingPathComponent("quotabar", isDirectory: true).appendingPathComponent("state.json")
    }

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        contents = Self.read(self.url) ?? [:]
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

    /// The file as a dictionary, or `nil` when there is nothing to preserve:
    /// no file, or bytes that are not a JSON object at all. A JSON object is
    /// decoded whole even where this build cannot interpret the values, so one
    /// unrecognised entry never costs the rest of the file.
    private static func read(_ url: URL) -> [String: JSONValue]? {
        (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }
    }

    /// Best effort: a state file we cannot write costs a cached snapshot, never a
    /// refresh. Callers keep working with in-memory values.
    private func persistLocked() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        withFileLock {
            // A file that is not ours is not an empty one: fall back to what
            // this instance holds rather than writing back a file stripped of
            // every key it was carrying, the dedup map among them.
            var merged = Self.read(url) ?? contents
            for key in written { merged[key] = contents[key] }
            guard let encoded = try? JSONEncoder().encode(merged) else { return }
            try? encoded.write(to: url, options: .atomic)
            // Adopt the other process's keys so later reads are not stale.
            contents = merged
        }
    }

    /// Advisory lock on a sidecar file — the state file itself is replaced by an
    /// atomic rename, which would leave each writer holding a different inode.
    ///
    /// The read-merge-write above already prevents the stale-snapshot clobber on
    /// its own; the lock only closes the interleaving window. `FileLock` holds the
    /// implementation because the history log needs the same sidecar guarantee.
    private func withFileLock(_ body: () -> Void) {
        FileLock.withExclusiveLock(at: FileLock.sidecarURL(for: url), body)
    }

    /// `string` and `int` are the two shapes this store writes and the only two
    /// its accessors return. The rest exist purely so any other JSON value
    /// survives a decode-modify-encode cycle unchanged; matching on the first two
    /// is what keeps an uninterpretable value reading as absent.
    private enum JSONValue: Codable {
        case string(String), int(Int), double(Double), bool(Bool), null
        case array([JSONValue]), object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Bool before Int: a JSON `true` is not the integer 1, and writing it
            // back as one would corrupt a newer build's setting.
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int.self) { self = .int(value) }
            else if let value = try? container.decode(Double.self) { self = .double(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { self = .object(try container.decode([String: JSONValue].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .null: try container.encodeNil()
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }
}
