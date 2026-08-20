import Foundation
@preconcurrency import UserNotifications
import QuotaCore

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

/// macOS delivery path. Threshold selection and dedup live in
/// `QuotaCore.AlertEvaluator`, shared with the Linux CLI.
struct UserNotificationSink: QuotaNotificationSink {
    func deliver(_ alert: QuotaAlert) async -> Bool {
        await send(title: alert.title, body: alert.body, identifier: alert.identifier)
    }

    func send(title: String, body: String, identifier: String) async -> Bool {
        // UserNotifications raises an Objective-C exception for a plain SwiftPM
        // executable. Never fall back to osascript: those notifications are
        // attributed to Automation and clicking them opens the wrong process.
        guard NotificationEnvironment.supportsUserNotifications else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let attachment = try? UNNotificationAttachment(identifier: "quotabar-icon", url: iconURL) {
            content.attachments = [attachment]
        }
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
            return true
        } catch { return false }
    }
}

actor QuotaNotifier {
    static let shared = QuotaNotifier()

    private let evaluator = AlertEvaluator()
    private let sink = UserNotificationSink()

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
        return await sink.send(
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
        await evaluator.dispatch(snapshots, through: sink)
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
