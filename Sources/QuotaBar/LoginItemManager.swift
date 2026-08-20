import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
            && Bundle.main.bundleIdentifier != nil
    }

    func refresh() {
        status = isAvailable ? SMAppService.mainApp.status : .notFound
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        guard isAvailable else {
            errorMessage = "Launch the signed QuotaBar.app build to configure login startup."
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
