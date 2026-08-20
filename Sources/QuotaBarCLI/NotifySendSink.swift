import Foundation
import QuotaCore

/// Desktop notifications through `notify-send`, which talks to whichever
/// `org.freedesktop.Notifications` daemon the session provides — KDE Plasma,
/// GNOME, dunst, mako and so on.
struct NotifySendSink: QuotaNotificationSink {
    static func isAvailable() -> Bool { CommandRunner.find("notify-send") != nil }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        guard let binary = CommandRunner.find("notify-send") else { return false }
        let arguments = [
            "--app-name=QuotaBar",
            "--urgency=\(alert.level == .critical ? "critical" : "normal")",
            "--icon=\(alert.level == .critical ? "dialog-error" : "dialog-warning")",
            alert.title,
            alert.body
        ]
        // CommandRunner.run blocks on the subprocess, so keep it off the
        // cooperative pool.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let delivered = (try? CommandRunner.run(binary, arguments, timeout: 5)) != nil
                continuation.resume(returning: delivered)
            }
        }
    }
}
