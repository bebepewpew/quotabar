import SwiftUI
import AppKit
import Combine

@main struct QuotaBarApp: App {
    @StateObject private var store: QuotaStore

    @MainActor init() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        let store = QuotaStore()
        _store = StateObject(wrappedValue: store)
        StatusBarController.shared.install(store: store)
        NotificationPresentationDelegate.install {
            StatusBarController.shared.show()
        }
        store.startScheduler()
        Task { _ = await QuotaNotifier.shared.requestAuthorization() }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    static let shared = StatusBarController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var store: QuotaStore?
    private var cancellables = Set<AnyCancellable>()

    func install(store: QuotaStore) {
        guard self.store == nil else { return }
        self.store = store
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: TrayContent(store: store))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        store.$snapshots
            .combineLatest(store.$menuBarSelections)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] _, _ in
                guard let self, let store else { return }
                self.updateIcon(store.menuBarIndicators)
                self.updatePopoverSize(for: store)
            }
            .store(in: &cancellables)
        updateIcon(store.menuBarIndicators)
        updatePopoverSize(for: store)
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    func show() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateIcon(_ quotas: [MenuBarQuota]) {
        statusItem.button?.image = MenuBarIconRenderer.render(quotas: quotas)
        statusItem.button?.toolTip = "AI Quotas"
    }

    private func updatePopoverSize(for store: QuotaStore) {
        let width = DashboardView.preferredWidth(for: store.snapshots)
        guard let view = popover.contentViewController?.view else {
            popover.contentSize = NSSize(width: width, height: 500)
            return
        }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        popover.contentSize = NSSize(width: width, height: min(max(fitting.height, 320), 820))
    }
}

private struct TrayContent: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        DashboardView(store: store)
            .frame(width: DashboardView.preferredWidth(for: store.snapshots))
    }
}

struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    @State private var showsSettings = false

    var body: some View {
        let layout = makeColumnLayout()
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Quotas").font(.title2.bold())
                    Text("Local CLI limits").foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
                Button { showsSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings")
                    .popover(isPresented: $showsSettings, arrowEdge: .top) {
                        SettingsView(store: store).frame(width: 380, height: 600)
                    }
                if store.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 22, height: 22)
                        .help("Refreshing quotas…")
                } else {
                    Button { store.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }.buttonStyle(.borderless).help("Refresh quotas")
                }
            }
            ScrollView {
                if store.isDiscoveringTools {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Finding installed CLIs…").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 180)
                } else if store.snapshots.isEmpty {
                    ContentUnavailableView("No supported CLIs found", systemImage: "terminal", description: Text("Install Gemini CLI, Claude Code, or Codex, then relaunch QuotaBar."))
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(layout.columns.indices, id: \.self) { index in
                            LazyVStack(spacing: 14) {
                                ForEach(layout.columns[index]) { snapshot in
                                    QuotaCard(snapshot: snapshot)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: layout.height)
            HStack {
                Text("QuotaBar never reads or stores API keys.").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link)
            }
        }
        .padding(16)
    }

    static func preferredWidth(for snapshots: [QuotaSnapshot]) -> CGFloat {
        let desired = CGFloat(preferredColumnCount(for: snapshots)) * 370 + 20
        return min(desired, max(390, (NSScreen.main?.visibleFrame.width ?? 1_200) - 40))
    }

    private static func preferredColumnCount(for snapshots: [QuotaSnapshot]) -> Int {
        guard !snapshots.isEmpty else { return 1 }
        let total = snapshots.reduce(CGFloat.zero) { $0 + estimatedHeight(of: $1) } + CGFloat(max(0, snapshots.count - 1) * 14)
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1_200
        let maxColumns = min(3, max(1, Int((screenWidth - 40) / 370)))
        if total <= 620 { return 1 }
        if snapshots.count >= 3 && total > 1_180 { return min(3, maxColumns) }
        return min(2, min(snapshots.count, maxColumns))
    }

    private func makeColumnLayout() -> (columns: [[QuotaSnapshot]], height: CGFloat) {
        guard !store.snapshots.isEmpty else { return ([[]], 260) }
        let count = Self.preferredColumnCount(for: store.snapshots)
        var columns = Array(repeating: [QuotaSnapshot](), count: count)
        var heights = Array(repeating: CGFloat.zero, count: count)

        for snapshot in store.snapshots {
            let shortest = heights.indices.min(by: { heights[$0] < heights[$1] }) ?? 0
            columns[shortest].append(snapshot)
            heights[shortest] += Self.estimatedHeight(of: snapshot) + (columns[shortest].count > 1 ? 14 : 0)
        }
        let contentHeight = heights.max() ?? 260
        return (columns, min(max(contentHeight, 260), 720))
    }

    private static func estimatedHeight(of snapshot: QuotaSnapshot) -> CGFloat {
        let rows = snapshot.windows.reduce(CGFloat.zero) { total, window in
            total + (window.resetAt == nil ? 43 : 61)
        }
        return 76 + rows + (snapshot.error == nil ? 0 : 48)
    }
}

struct MenuBarCompositeIcon: View {
    let quotas: [MenuBarQuota]

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.render(quotas: quotas))
            .id(signature)
            .accessibilityLabel(accessibilityDescription)
    }

    private var signature: String {
        quotas.map { "\($0.id):\($0.usedPercent ?? -1)" }.joined(separator: ",")
    }

    private var accessibilityDescription: String {
        guard !quotas.isEmpty else { return "AI Quotas" }
        return quotas.map { quota in
            let value = quota.usedPercent.map { "\(QuotaFormatting.percent($0)) used" } ?? "waiting for data"
            return "\(quota.selection.provider.rawValue) \(quota.selection.windowLabel), \(value)"
        }.joined(separator: "; ")
    }
}

@MainActor
enum MenuBarIconRenderer {
    static func render(quotas: [MenuBarQuota]) -> NSImage {
        let shown = Array(quotas.prefix(3))
        let size = NSSize(width: shown.isEmpty ? 18 : CGFloat(shown.count) * 23 - 3, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            if shown.isEmpty {
                let baseConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                let base = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)?
                    .withSymbolConfiguration(baseConfig)
                base?.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            }

            for (index, quota) in shown.enumerated() {
                let x = CGFloat(index) * 23
                let color = NSColor(hex: quota.selection.provider.tint)

                // Keep the provider mark large enough to recognize. The quota is
                // a separate strip instead of a ring competing for the same pixels.
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                    .applying(.init(paletteColors: [color]))
                let symbol = NSImage(systemSymbolName: quota.selection.provider.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                symbol?.draw(in: NSRect(x: x + 3, y: 5, width: 14, height: 12))

                let badge = NSAttributedString(string: quota.badge, attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.labelColor,
                    .strokeColor: NSColor.windowBackgroundColor, .strokeWidth: -2.0
                ])
                badge.draw(at: NSPoint(x: x + 19 - badge.size().width, y: 8))

                NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
                let trackRect = NSRect(x: x, y: 1, width: 20, height: 3)
                NSBezierPath(roundedRect: trackRect, xRadius: 1.5, yRadius: 1.5).fill()

                if let used = quota.usedPercent {
                    let fraction = min(max(used / 100, 0.015), 1)
                    progressColor(used: used, provider: color).setFill()
                    let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY,
                                          width: max(2, trackRect.width * CGFloat(fraction)),
                                          height: trackRect.height)
                    NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func progressColor(used: Double?, provider: NSColor) -> NSColor {
        guard let used else { return .tertiaryLabelColor }
        if used >= 95 { return .systemRed }
        if used >= 80 { return .systemOrange }
        return provider
    }
}

struct SettingsView: View {
    @ObservedObject var store: QuotaStore
    @StateObject private var loginItem = LoginItemManager()
    @State private var notificationPermission: NotificationPermissionState = .unavailable
    @State private var notificationTestFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("Automatic refresh").font(.headline)
                Picker("Refresh interval", selection: $store.refreshIntervalMinutes) {
                    ForEach(QuotaStore.refreshIntervals, id: \.self) { minutes in
                        Text(intervalLabel(minutes)).tag(minutes)
                    }
                }.pickerStyle(.menu)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch QuotaBar at login", isOn: Binding(
                    get: { loginItem.isRequested },
                    set: { loginItem.setEnabled($0) }
                ))

                if loginItem.requiresApproval {
                    HStack {
                        Text("macOS requires approval for this login item.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { loginItem.openSystemSettings() }
                            .buttonStyle(.link)
                    }
                } else if let error = loginItem.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Notifications").font(.headline)
                    Spacer()
                    Text(notificationPermission.label).font(.caption).foregroundStyle(.secondary)
                }
                Text("Alerts are sent at 80% used and again at 95% used.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if notificationPermission == .notDetermined {
                        Button("Enable Notifications") {
                            Task { notificationPermission = await QuotaNotifier.shared.requestAuthorization() }
                        }
                    } else if notificationPermission == .denied {
                        Button("Open Notification Settings") { openNotificationSettings() }
                    }
                    Button("Send Test Notification") {
                        Task {
                            notificationTestFailed = !(await QuotaNotifier.shared.sendTestNotification())
                            notificationPermission = await QuotaNotifier.shared.permissionState()
                        }
                    }
                    .disabled(notificationPermission == .denied || notificationPermission == .unavailable)
                }
                if notificationTestFailed {
                    Text("The test could not be delivered. Check QuotaBar in System Settings → Notifications.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Menu bar limits").font(.headline)
                Text("Choose up to three quota windows to show beside the icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.menuBarSelectionOptions) { selection in
                        Toggle(isOn: binding(for: selection)) {
                            HStack {
                                Image(systemName: selection.provider.symbol).foregroundStyle(Color(hex: selection.provider.tint))
                                Text(selection.provider.rawValue)
                                Spacer()
                                Text(selection.windowLabel).foregroundStyle(.secondary)
                                if !store.isMenuBarSelectionAvailable(selection) {
                                    Image(systemName: "exclamationmark.circle")
                                        .foregroundStyle(.secondary)
                                        .help("Not present in the latest refresh")
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!store.menuBarSelections.contains(selection) && store.menuBarSelections.count >= 3)
                    }
                }
            }
            Text("\(store.menuBarSelections.count) of 3 selected")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18)
        .onAppear {
            loginItem.refresh()
            Task { notificationPermission = await QuotaNotifier.shared.permissionState() }
        }
    }

    private func binding(for selection: QuotaSelection) -> Binding<Bool> {
        Binding(get: { store.menuBarSelections.contains(selection) },
                set: { store.setMenuBarSelection(selection, enabled: $0) })
    }

    private func intervalLabel(_ minutes: Int) -> String {
        switch minutes { case 0: "Off"; case 60: "Every hour"; default: "Every \(minutes) minutes" }
    }

    private func openNotificationSettings() {
        guard let identifier = Bundle.main.bundleIdentifier,
              let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct QuotaCard: View {
    let snapshot: QuotaSnapshot
    var color: Color { Color(hex: snapshot.provider.tint) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: snapshot.provider.symbol).foregroundStyle(color).frame(width: 22)
                Text(snapshot.provider.rawValue).font(.headline)
                Spacer()
                if let plan = snapshot.plan { Text(plan.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(snapshot.windows) { window in
                VStack(spacing: 5) {
                    HStack {
                        Text(window.label).font(.caption)
                        Spacer()
                        Text("\(QuotaFormatting.percent(window.usedPercent)) used").font(.caption.monospacedDigit()).fontWeight(.medium)
                    }
                    ProgressView(value: window.usedPercent, total: 100).tint(color)
                    if let reset = window.resetAt {
                        Text("Resets \(reset, style: .relative)").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            if let error = snapshot.error {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Updated \(snapshot.updatedAt, style: .relative)")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255,
                  alpha: 1)
    }
}
