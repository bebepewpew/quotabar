import Foundation
import QuotaCore

/// Which quota windows the tray shows, persisted through the existing
/// `StateStore` seam — `UserDefaults` on macOS, the XDG JSON file on Linux.
public final class TrayPreferences: @unchecked Sendable {
    /// A new key: the macOS menu bar keeps its own selections untouched.
    public static let storageKey = "QuotaBar.traySelections.v1"
    /// Mirrors the macOS menu bar, which shows at most three.
    public static let maximumSelections = 3

    /// Encoding a selection list on its way to the store. It is a seam because
    /// `[QuotaSelection]` always encodes, which would otherwise leave the
    /// "never overwrite what we could not encode" guarantee in `setSelections`
    /// unreachable from a test.
    typealias Encode = @Sendable ([QuotaSelection]) throws -> Data

    private let store: StateStore
    private let encode: Encode

    public convenience init(store: StateStore = StateStoreFactory.makeDefault()) {
        self.init(store: store, encode: { try JSONEncoder().encode($0) })
    }

    init(store: StateStore, encode: @escaping Encode) {
        self.store = store
        self.encode = encode
    }

    /// Saved selections, capped at `maximumSelections`. Older or malformed
    /// payloads must decode to an empty list rather than throwing.
    ///
    /// The cap is applied on read as well as on write, so a list stored by a
    /// future build that shows more windows still renders at this build's limit
    /// instead of overflowing the tray.
    public var selections: [QuotaSelection] {
        guard let data = store.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([QuotaSelection].self, from: data)
        else { return [] }
        return Self.capped(decoded)
    }

    public func setSelections(_ selections: [QuotaSelection]) {
        // A payload we cannot encode must not wipe the saved one: leave the
        // stored value alone rather than writing nil over it.
        guard let data = try? encode(Self.capped(selections)) else { return }
        store.setData(data, forKey: Self.storageKey)
    }

    private static func capped(_ selections: [QuotaSelection]) -> [QuotaSelection] {
        Array(selections.prefix(maximumSelections))
    }
}
