import Foundation
import QuotaCore

/// Desktop notifications through `notify-send`, which talks to whichever
/// `org.freedesktop.Notifications` daemon the session provides — KDE Plasma,
/// GNOME, dunst, mako and so on.
struct NotifySendSink: QuotaNotificationSink {
    private let binary: String?

    /// Resolved once. A failed lookup falls back to spawning a login shell, and
    /// undelivered alerts are retried on every watch cycle, so doing this per
    /// alert would spawn a shell per over-threshold window per cycle.
    init() { binary = CommandRunner.find("notify-send") }

    var isAvailable: Bool { binary != nil }

    func deliver(_ alert: QuotaAlert) async -> Bool {
        guard let binary else { return false }
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
