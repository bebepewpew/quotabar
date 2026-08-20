import Foundation

enum Provider: String, CaseIterable, Identifiable, Sendable, Codable {
    case gemini = "Gemini CLI"
    case claude = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }
    var symbol: String {
        switch self { case .gemini: "sparkles"; case .claude: "brain.head.profile"; case .codex: "chevron.left.forwardslash.chevron.right" }
    }
    var tint: String {
        switch self { case .gemini: "4F7DF3"; case .claude: "D97757"; case .codex: "10A37F" }
    }
}

struct QuotaSelection: Identifiable, Hashable, Codable, Sendable {
    let provider: Provider
    let windowKey: String
    let windowLabel: String
    var id: String { "\(provider.id)|\(windowKey)" }

    init(provider: Provider, windowKey: String? = nil, windowLabel: String) {
        self.provider = provider
        self.windowKey = windowKey ?? QuotaWindow.key(for: windowLabel)
        self.windowLabel = windowLabel
    }

    private enum CodingKeys: String, CodingKey { case provider, windowKey, windowLabel }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(Provider.self, forKey: .provider)
        windowLabel = try values.decode(String.self, forKey: .windowLabel)
        windowKey = try values.decodeIfPresent(String.self, forKey: .windowKey) ?? QuotaWindow.key(for: windowLabel)
    }
}

struct MenuBarQuota: Identifiable, Sendable {
    let selection: QuotaSelection
    let usedPercent: Double?
    let badge: String
    var id: String { selection.id }
}

struct QuotaWindow: Identifiable, Sendable, Codable {
    let key: String
    var id: String { key }
    let label: String
    let usedPercent: Double
    let resetAt: Date?

    init(key: String? = nil, label: String, usedPercent: Double, resetAt: Date?) {
        self.key = key ?? Self.key(for: label)
        self.label = label
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }

    static func key(for label: String) -> String {
        String(label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .split(separator: "-").joined(separator: "-"))
    }

    private enum CodingKeys: String, CodingKey { case key, label, usedPercent, resetAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decode(String.self, forKey: .label)
        key = try values.decodeIfPresent(String.self, forKey: .key) ?? Self.key(for: label)
        usedPercent = try values.decode(Double.self, forKey: .usedPercent)
        resetAt = try values.decodeIfPresent(Date.self, forKey: .resetAt)
    }
}

struct QuotaSnapshot: Identifiable, Sendable, Codable {
    var id: Provider { provider }
    let provider: Provider
    var windows: [QuotaWindow] = []
    var plan: String?
    var error: String?
    var probeSucceeded = true
    var updatedAt = Date()

    private enum CodingKeys: String, CodingKey { case provider, windows, plan, error, probeSucceeded, updatedAt }
    init(provider: Provider, windows: [QuotaWindow] = [], plan: String? = nil, error: String? = nil,
         probeSucceeded: Bool = true, updatedAt: Date = Date()) {
        self.provider = provider
        self.windows = windows
        self.plan = plan
        self.error = error
        self.probeSucceeded = probeSucceeded
        self.updatedAt = updatedAt
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(Provider.self, forKey: .provider)
        windows = try values.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? []
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        probeSucceeded = try values.decodeIfPresent(Bool.self, forKey: .probeSucceeded) ?? true
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    static func loading(_ provider: Provider) -> Self { .init(provider: provider) }
}


enum QuotaFormatting {
    static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        return abs(clamped - clamped.rounded()) < 0.05
            ? "\(Int(clamped.rounded()))%"
            : String(format: "%.1f%%", clamped)
    }
}
