import Foundation
import QuotaCore

/// Which quota windows the tray shows, persisted through the existing
/// `StateStore` seam — `UserDefaults` on macOS, the XDG JSON file on Linux.
public final class TrayPreferences: @unchecked Sendable {
    /// A new key: the macOS menu bar keeps its own selections untouched.
    public static let storageKey = "QuotaBar.traySelections.v1"
    /// Mirrors the macOS menu bar, which shows at most three.
    public static let maximumSelections = 3

    private let store: StateStore

    public init(store: StateStore = StateStoreFactory.makeDefault()) {
        self.store = store
    }

    /// Saved selections, capped at `maximumSelections`. Older or malformed
    /// payloads must decode to an empty list rather than throwing.
    public var selections: [QuotaSelection] {
        // TODO(task 4: preferences)
        []
    }

    public func setSelections(_ selections: [QuotaSelection]) {
        // TODO(task 4: preferences)
    }
}
