import Foundation
import QuotaCore

struct Arguments {
    enum Format: String { case text, json, waybar }

    var format: Format = .text
    var providers: Set<Provider> = []
    var watch = false
    var intervalMinutes = 15
    var notify = false
    var color = true
    var showHelp = false
    var showVersion = false

    static let version = "0.1.0"

    static func parse(_ argv: [String]) throws -> Arguments {
        var arguments = Arguments()
        var index = argv.startIndex

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
                    throw ArgumentError.invalidValue("--format", "\(value) (expected text, json or waybar)")
                }
                arguments.format = format
            case "--provider":
                let value = try nextValue(for: "--provider").lowercased()
                guard let provider = Provider.allCases.first(where: { $0.slug == value }) else {
                    let known = Provider.allCases.map(\.slug).joined(separator: ", ")
                    throw ArgumentError.invalidValue("--provider", "\(value) (expected one of \(known))")
                }
                arguments.providers.insert(provider)
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
        return arguments
    }

    static let usage = """
    quotabar — AI coding CLI quota monitor

    USAGE
      quotabar [options]

    OPTIONS
      --json                 Emit snapshots as JSON
      --format <fmt>         text (default), json, or waybar
      --provider <name>      Limit to one provider; repeatable (gemini, claude, codex)
      --watch                Keep running and re-probe on an interval
      --interval <minutes>   Refresh interval for --watch (default 15)
      --notify               Send desktop notifications at 80% and 95% usage
      --no-color             Disable ANSI colour in text output
      --version              Print the version and exit
      -h, --help             Show this help

    EXIT CODES
      0  every probe succeeded
      1  at least one provider failed to report
      2  invalid usage
    """
}

enum ArgumentError: Error, CustomStringConvertible {
    case unknown(String), missingValue(String), invalidValue(String, String)

    var description: String {
        switch self {
        case .unknown(let flag): "unknown option \(flag)"
        case .missingValue(let flag): "\(flag) requires a value"
        case .invalidValue(let flag, let value): "invalid value for \(flag): \(value)"
        }
    }
}
