import Foundation
import QuotaCore

struct Arguments {
    /// What the invocation is for. Absent from the command line means `status`,
    /// so every existing invocation keeps working unchanged.
    enum Command: String { case status, history, advise }

    enum Format: String { case text, json, waybar, csv }

    var command: Command = .status
    var format: Format = .text
    var providers: Set<Provider> = []
    var watch = false
    var intervalMinutes = 15
    var notify = false
    var color = true
    var showHelp = false
    var showVersion = false

    // history
    var since: TimeInterval = 7 * 86_400
    var showCycles = false
    var clearHistory = false
    var windowKey: String?

    static let version = "0.1.0"

    static func parse(_ argv: [String]) throws -> Arguments {
        var arguments = Arguments()
        var index = argv.startIndex

        // A leading bare word is the subcommand. Anything else non-flag is a
        // mistake worth naming rather than ignoring.
        if let first = argv.first, !first.hasPrefix("-") {
            guard let command = Command(rawValue: first) else {
                throw ArgumentError.unknownCommand(first)
            }
            arguments.command = command
            index += 1
        }

        func nextValue(for flag: String) throws -> String {
            index += 1
            guard index < argv.endIndex else { throw ArgumentError.missingValue(flag) }
            return argv[index]
        }

        while index < argv.endIndex {
            let argument = argv[index]
            switch argument {
            case "--json": arguments.format = .json
            case "--format":
                let value = try nextValue(for: "--format")
                guard let format = Format(rawValue: value) else {
                    throw ArgumentError.invalidValue("--format", "\(value) (expected text, json, waybar or csv)")
                }
                arguments.format = format
            case "--provider":
                let value = try nextValue(for: "--provider").lowercased()
                guard let provider = Provider.allCases.first(where: { $0.slug == value }) else {
                    let known = Provider.allCases.map(\.slug).joined(separator: ", ")
                    throw ArgumentError.invalidValue("--provider", "\(value) (expected one of \(known))")
                }
                arguments.providers.insert(provider)
            case "--window": arguments.windowKey = try nextValue(for: "--window")
            case "--since":
                let value = try nextValue(for: "--since")
                guard let seconds = Self.duration(value) else {
                    throw ArgumentError.invalidValue("--since", "\(value) (expected a span like 24h, 7d or 90m)")
                }
                arguments.since = seconds
            case "--cycles": arguments.showCycles = true
            case "--clear": arguments.clearHistory = true
            case "--watch": arguments.watch = true
            case "--interval":
                let value = try nextValue(for: "--interval")
                guard let minutes = Int(value), minutes > 0 else {
                    throw ArgumentError.invalidValue("--interval", "\(value) (expected a positive number of minutes)")
                }
                arguments.intervalMinutes = minutes
            case "--notify": arguments.notify = true
            case "--no-color": arguments.color = false
            case "--version": arguments.showVersion = true
            case "-h", "--help": arguments.showHelp = true
            default: throw ArgumentError.unknown(argument)
            }
            index += 1
        }
        try arguments.validate()
        return arguments
    }

    /// Rejects combinations that would otherwise be silently ignored, so a
    /// misspelled invocation fails loudly instead of printing the wrong thing.
    private func validate() throws {
        if command != .status, format == .waybar {
            throw ArgumentError.invalidValue("--format", "waybar is only available for the default status output")
        }
        if command != .history, format == .csv {
            throw ArgumentError.invalidValue("--format", "csv is only available for `quotabar history`")
        }
    }

    /// `90m`, `24h`, `7d`, `3w`. Bare digits are days, which is what people mean
    /// when they type `--since 30`.
    static func duration(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let multipliers: [Character: TimeInterval] = ["m": 60, "h": 3_600, "d": 86_400, "w": 604_800]
        guard let unit = trimmed.last else { return nil }
        if unit.isNumber {
            guard let days = Double(trimmed), days > 0 else { return nil }
            return days * 86_400
        }
        guard let multiplier = multipliers[unit],
              let value = Double(trimmed.dropLast()), value > 0 else { return nil }
        return value * multiplier
    }

    static let usage = """
    quotabar — AI coding CLI quota monitor

    USAGE
      quotabar [options]                 Current quota for every installed CLI
      quotabar history [options]         Recorded usage over time
      quotabar advise [options]          Whether your subscriptions fit your usage

    OPTIONS
      --json                 Emit as JSON
      --format <fmt>         text (default), json, waybar (status), csv (history)
      --provider <name>      Limit to one provider; repeatable (gemini, claude, codex)
      --watch                Keep running and re-probe on an interval
      --interval <minutes>   Refresh interval for --watch (default 15)
      --notify               Send desktop notifications at 80% and 95% usage, and
                             when a window is on course to run out before it resets
      --no-color             Disable ANSI colour in text output
      --version              Print the version and exit
      -h, --help             Show this help

    HISTORY OPTIONS
      --since <span>         How far back to read: 90m, 24h, 7d, 3w (default 7d)
      --window <key>         Limit to one quota window
      --cycles               List completed cycles instead of the usage graph
      --clear                Delete all recorded history and exit

    EXIT CODES
      0  every probe succeeded
      1  at least one provider failed to report
      2  invalid usage
    """
}

enum ArgumentError: Error, CustomStringConvertible {
    case unknown(String), unknownCommand(String), missingValue(String), invalidValue(String, String)

    var description: String {
        switch self {
        case .unknown(let flag): "unknown option \(flag)"
        case .unknownCommand(let name): "unknown command \(name) (expected history or advise)"
        case .missingValue(let flag): "\(flag) requires a value"
        case .invalidValue(let flag, let value): "invalid value for \(flag): \(value)"
        }
    }
}
