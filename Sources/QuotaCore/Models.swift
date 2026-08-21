import Foundation

public enum Provider: String, CaseIterable, Identifiable, Sendable, Codable {
    case gemini = "Gemini CLI"
    case claude = "Claude Code"
    case codex = "Codex"

    public var id: String { rawValue }

    /// Name of the CLI executable this provider is probed through.
    public var executableName: String {
        switch self { case .gemini: "gemini"; case .claude: "claude"; case .codex: "codex" }
    }

    /// Short lowercase name accepted by the CLI's `--provider` flag.
    public var slug: String { executableName }

    /// SF Symbol name. Only the macOS front-end renders these.
    public var symbol: String {
        switch self { case .gemini: "sparkles"; case .claude: "brain.head.profile"; case .codex: "chevron.left.forwardslash.chevron.right" }
    }

    public var tint: String {
        switch self { case .gemini: "4F7DF3"; case .claude: "D97757"; case .codex: "10A37F" }
    }
}

/// The red, green and blue bytes of a tint written as `RRGGBB`, the form
/// `Provider.tint` stores.
///
/// The parse lives in the core rather than once per front-end because the
/// front-ends used to disagree about a tint they cannot read: the Linux tray
/// fell back to a neutral grey, the macOS menu bar to pure black. One
/// implementation cannot drift from itself.
public struct TintRGB: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    /// What a tint that cannot be parsed draws as: `secondaryLabelColor`,
    /// opaque. An invisible icon is a worse failure than a wrong colour, so the
    /// fallback is never black and never transparent.
    public static let fallback = TintRGB(red: 0x8E, green: 0x8E, blue: 0x93)

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `RRGGBB`, with an optional leading `#`. Anything else is
    /// ``fallback``.
    public init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        // `UInt32(_:radix:)` accepts a leading sign, so "+12345" would otherwise
        // parse as 0x012345 — a wrong colour rather than the documented grey.
        // Six ASCII hex digits is the only form this reads.
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt32(digits, radix: 16) else {
            self = .fallback
            return
        }
        self.init(red: UInt8((value >> 16) & 0xFF),
                  green: UInt8((value >> 8) & 0xFF),
                  blue: UInt8(value & 0xFF))
    }
}

public struct QuotaSelection: Identifiable, Hashable, Codable, Sendable {
    public let provider: Provider
    public let windowKey: String
    public let windowLabel: String
    public var id: String { "\(provider.id)|\(windowKey)" }

    public init(provider: Provider, windowKey: String? = nil, windowLabel: String) {
        self.provider = provider
        self.windowKey = windowKey ?? QuotaWindow.key(for: windowLabel)
        self.windowLabel = windowLabel
    }

    private enum CodingKeys: String, CodingKey { case provider, windowKey, windowLabel }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(Provider.self, forKey: .provider)
        windowLabel = try values.decode(String.self, forKey: .windowLabel)
        windowKey = try values.decodeIfPresent(String.self, forKey: .windowKey) ?? QuotaWindow.key(for: windowLabel)
    }
}

public struct MenuBarQuota: Identifiable, Sendable {
    public let selection: QuotaSelection
    public let usedPercent: Double?
    public let badge: String
    public var id: String { selection.id }

    public init(selection: QuotaSelection, usedPercent: Double?, badge: String) {
        self.selection = selection
        self.usedPercent = usedPercent
        self.badge = badge
    }
}

public struct QuotaWindow: Identifiable, Sendable, Codable {
    public let key: String
    public var id: String { key }
    public let label: String
    public let usedPercent: Double
    public let resetAt: Date?

    public init(key: String? = nil, label: String, usedPercent: Double, resetAt: Date?) {
        self.key = key ?? Self.key(for: label)
        self.label = label
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }

    public static func key(for label: String) -> String {
        String(label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .split(separator: "-").joined(separator: "-"))
    }

    private enum CodingKeys: String, CodingKey { case key, label, usedPercent, resetAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decode(String.self, forKey: .label)
        key = try values.decodeIfPresent(String.self, forKey: .key) ?? Self.key(for: label)
        usedPercent = try values.decode(Double.self, forKey: .usedPercent)
        resetAt = try values.decodeIfPresent(Date.self, forKey: .resetAt)
    }
}

public struct QuotaSnapshot: Identifiable, Sendable, Codable {
    public var id: Provider { provider }
    public let provider: Provider
    public var windows: [QuotaWindow] = []
    public var plan: String?
    public var error: String?
    public var probeSucceeded = true
    public var updatedAt = Date()

    private enum CodingKeys: String, CodingKey { case provider, windows, plan, error, probeSucceeded, updatedAt }
    public init(provider: Provider, windows: [QuotaWindow] = [], plan: String? = nil, error: String? = nil,
                probeSucceeded: Bool = true, updatedAt: Date = Date()) {
        self.provider = provider
        self.windows = windows
        self.plan = plan
        self.error = error
        self.probeSucceeded = probeSucceeded
        self.updatedAt = updatedAt
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(Provider.self, forKey: .provider)
        windows = try values.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? []
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        probeSucceeded = try values.decodeIfPresent(Bool.self, forKey: .probeSucceeded) ?? true
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public static func loading(_ provider: Provider) -> Self { .init(provider: provider) }
}
