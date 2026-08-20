import Foundation

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
public final class JSONFileStateStore: StateStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var contents: [String: JSONValue]

    public static func defaultURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("quotabar", isDirectory: true).appendingPathComponent("state.json")
    }

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        contents = (try? Data(contentsOf: self.url))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
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
            persistLocked()
        }
    }

    /// Best effort: a state file we cannot write costs a cached snapshot, never a
    /// refresh. Callers keep working with in-memory values.
    private func persistLocked() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(contents) else { return }
        try? encoded.write(to: url, options: .atomic)
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
