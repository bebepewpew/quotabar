import Foundation
import QuotaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct QuotaBarCLI {
    static func main() async {
        // A provider CLI that exits mid-write must fail one refresh, not kill the
        // command. Installed before anything can spawn a child.
        ProcessSignals.ignoreBrokenPipe()
        let arguments: Arguments
        do {
            arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
        } catch let error as ArgumentError {
            fail("\(error.description)\n\n\(Arguments.usage)", code: 2)
        } catch {
            fail(error.localizedDescription, code: 2)
        }

        if arguments.showHelp { print(Arguments.usage); exit(0) }
        if arguments.showVersion { print("quotabar \(Arguments.version)"); exit(0) }
        await run(arguments)
    }

    private static func run(_ arguments: Arguments) async {
        let store = StateStoreFactory.makeDefault()
        let cache = SnapshotCache(store: store)
        let evaluator = AlertEvaluator(store: store)
        let sink = NotifySendSink()
        // Descriptor 1 by number: the C `stdout` global is a mutable var and so
        // not readable under strict concurrency.
        #if os(Windows)
        // A Windows console also needs ENABLE_VIRTUAL_TERMINAL_PROCESSING before
        // ANSI means anything, so this only reports whether it is a terminal.
        let isTerminal = _isatty(1) != 0
        #else
        let isTerminal = isatty(1) == 1
        #endif
        let useColor = arguments.color
            && isTerminal
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

        let installed = await QuotaEngine.discoverProviders()
        let requested = arguments.providers.isEmpty
            ? installed
            : Provider.allCases.filter { arguments.providers.contains($0) }
        let targets = requested.filter(installed.contains)
        var sawFailure = false

        for provider in requested where !installed.contains(provider) {
            warn("\(provider.rawValue) is not installed (looked for `\(provider.executableName)`)")
            sawFailure = true
        }
        guard !targets.isEmpty else {
            // With --provider the per-provider warnings above already said which
            // one is missing; repeating the generic message would contradict them.
            if arguments.providers.isEmpty {
                warn("No supported CLI found. Install codex, claude or gemini and authenticate it.")
            }
            exit(1)
        }
        if arguments.notify && !sink.isAvailable {
            warn("notify-send was not found, so --notify will not deliver anything.")
        }

        var previous = targets.compactMap { cache.snapshot(for: $0) }
        repeat {
            let fresh = await QuotaEngine.refresh(targets)
            let merged = QuotaEngine.retainingLastGood(fresh: fresh, previous: previous)
            previous = merged
            cache.update(with: merged)

            emit(merged, arguments: arguments, useColor: useColor)
            sawFailure = sawFailure || merged.contains { $0.error != nil }

            if arguments.notify {
                await evaluator.dispatch(fresh.filter { $0.error == nil && !$0.windows.isEmpty }, through: sink)
            }
            if arguments.watch {
                try? await Task.sleep(for: .seconds(arguments.intervalMinutes * 60))
            }
        } while arguments.watch

        exit(sawFailure ? 1 : 0)
    }

    private static func emit(_ snapshots: [QuotaSnapshot], arguments: Arguments, useColor: Bool) {
        do {
            // A text watch loop scrolls, so stamp each cycle. JSON and waybar stay
            // one record per line for whatever is consuming the stream.
            if arguments.watch && arguments.format == .text {
                print("\n── \(timestamp()) ──")
            }
            print(try Output.render(snapshots, format: arguments.format, color: useColor))
            // Piped output is block-buffered, which would stall a --watch stream
            // feeding a status bar. Passing nil flushes every open stream.
            fflush(nil)
        } catch {
            warn("could not render output: \(error.localizedDescription)")
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("quotabar: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        warn(message)
        exit(code)
    }
}
