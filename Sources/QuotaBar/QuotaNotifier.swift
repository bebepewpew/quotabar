import Foundation
@preconcurrency import UserNotifications

final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresentationDelegate()
    private var onOpen: (@MainActor @Sendable () -> Void)?

    static func install(onOpen: @escaping @MainActor @Sendable () -> Void) {
        guard NotificationEnvironment.supportsUserNotifications else { return }
        shared.onOpen = onOpen
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task { @MainActor in
            onOpen?()
        }
    }
}

actor QuotaNotifier {
    static let shared = QuotaNotifier()

    private let defaults = UserDefaults.standard
    private let deliveredKey = "QuotaBar.deliveredQuotaNotifications.v2"
    private var delivered: [String: Date]

    private init() {
        delivered = defaults.data(forKey: deliveredKey)
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }

    func requestAuthorization() async -> NotificationPermissionState {
        guard NotificationEnvironment.supportsUserNotifications else { return .unavailable }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return .unavailable
        }
        return await permissionState()
    }

    func permissionState() async -> NotificationPermissionState {
        guard NotificationEnvironment.supportsUserNotifications else { return .unavailable }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: return .enabled
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    func sendTestNotification() async -> Bool {
        var state = await permissionState()
        if state == .notDetermined { state = await requestAuthorization() }
        guard state == .enabled else { return false }
        return await deliver(
            title: "QuotaBar notifications are working",
            body: "You’ll be alerted when quota usage reaches 80% and 95%.",
            identifier: "quota.test.\(UUID().uuidString)"
        )
    }

    func evaluate(_ snapshots: [QuotaSnapshot]) async {
        if NotificationEnvironment.supportsUserNotifications {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        }

        for snapshot in snapshots where snapshot.error == nil {
            for window in snapshot.windows {
                guard let level = AlertLevel(usedPercent: window.usedPercent) else { continue }
                let identifier = notificationIdentifier(snapshot: snapshot, window: window, level: level)
                guard delivered[identifier] == nil else { continue }

                let title = "\(snapshot.provider.rawValue) quota is \(level.title)"
                let body = notificationBody(window: window)
                if await deliver(title: title, body: body, identifier: identifier) {
                    delivered[identifier] = Date()
                }
            }
        }
        trimAndPersist()
    }

    private func deliver(title: String, body: String, identifier: String) async -> Bool {
        if NotificationEnvironment.supportsUserNotifications {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            do {
                try await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                )
                return true
            } catch { return false }
        }

        // UserNotifications raises an Objective-C exception for a plain SwiftPM
        // executable. Never fall back to osascript: those notifications are
        // attributed to Automation and clicking them opens the wrong process.
        return false
    }

    private func notificationIdentifier(snapshot: QuotaSnapshot, window: QuotaWindow, level: AlertLevel) -> String {
        let period: String
        if let reset = window.resetAt {
            period = String(Int(reset.timeIntervalSince1970))
        } else {
            period = "no-reset"
        }
        return "quota.\(snapshot.provider.id).\(window.label).\(period).\(level.rawValue)"
    }

    private func notificationBody(window: QuotaWindow) -> String {
        let usage = QuotaFormatting.percent(window.usedPercent)
        guard let reset = window.resetAt else { return "\(window.label) limit is \(usage) used." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: reset, relativeTo: Date())
        return "\(window.label) limit is \(usage) used and resets \(relative)."
    }

    private func trimAndPersist() {
        if delivered.count > 500 {
            delivered = Dictionary(uniqueKeysWithValues: delivered.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(delivered) { defaults.set(data, forKey: deliveredKey) }
    }
}

enum NotificationPermissionState: Sendable, Equatable {
    case enabled, denied, notDetermined, unavailable

    var label: String {
        switch self {
        case .enabled: "Enabled"
        case .denied: "Blocked in System Settings"
        case .notDetermined: "Permission not requested"
        case .unavailable: "Unavailable"
        }
    }
}

enum NotificationEnvironment {
    static var supportsUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}

private enum AlertLevel: String {
    case warning, critical

    init?(usedPercent: Double) {
        if usedPercent >= 95 { self = .critical }
        else if usedPercent >= 80 { self = .warning }
        else { return nil }
    }

    var title: String { self == .critical ? "almost exhausted" : "running low" }
}
