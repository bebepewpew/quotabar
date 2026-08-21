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

        switch arguments.command {
        case .status: await run(arguments)
        case .history: runHistory(arguments)
        case .advise: runAdvise(arguments)
        }
    }

    // MARK: - Status

    private static func run(_ arguments: Arguments) async {
        let store = StateStoreFactory.makeDefault()
        let cache = SnapshotCache(store: store)
        let evaluator = AlertEvaluator(store: store)
        // One history store for the whole run. The recorder writes through it
        // and the forecast reads back through it, instead of --notify building a
        // second store, series catalogue and state store on every tick.
        let history = FileHistoryStore(store: store)
        let recorder = UsageRecorder(store: history)
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
            // `fresh`, not `merged`: a retained snapshot is the previous reading
            // served again, and recording it would draw a flat line the user
            // never used.
            recorder.record(fresh)

            emit(merged, arguments: arguments, useColor: useColor)
            sawFailure = sawFailure || merged.contains { $0.error != nil }

            if arguments.notify {
                let succeeded = fresh.filter { $0.error == nil && !$0.windows.isEmpty }
                await evaluator.dispatch(succeeded, through: sink)
                await evaluator.dispatch(projections: Advisor.projections(from: history, for: succeeded),
                                         through: sink)
            }
            if arguments.watch {
                try? await Task.sleep(for: .seconds(arguments.intervalMinutes * 60))
            }
        } while arguments.watch

        exit(sawFailure ? 1 : 0)
    }

    // MARK: - History

    private static func runHistory(_ arguments: Arguments) {
        let store = StateStoreFactory.makeDefault()
        let history = FileHistoryStore(store: store)

        if arguments.clearHistory {
            history.removeAll()
            print("Deleted recorded usage history.")
            exit(0)
        }

        let now = Date()
        let from = now.addingTimeInterval(-arguments.since)
        let all = history.read()
        let selected = all.samples.filter { matches($0.series, arguments) }

        // Cycles are segmented over the whole record, not the requested window: a
        // boundary needs the sample on each side of it, and the one before `from`
        // is outside the window by definition.
        let cycles = UsageAnalysis.cycles(for: selected)
            .filter { $0.endedAt >= from }
        let windowed = selected.filter { $0.at >= from && $0.at <= now }

        let labels = self.labels(SnapshotCache(store: store).all())
        let result = HistoryReadResult(samples: windowed,
                                       damagedRecords: all.damagedRecords,
                                       hasPartialTail: all.hasPartialTail,
                                       unreadableVersion: all.unreadableVersion)
        do {
            print(try Output.history(result, cycles: cycles, labels: labels,
                                     from: from, to: now, arguments: arguments))
        } catch {
            fail("could not render history: \(error.localizedDescription)", code: 1)
        }
        exit(0)
    }

    // MARK: - Advise

    private static func runAdvise(_ arguments: Arguments) {
        let now = Date()
        let store = StateStoreFactory.makeDefault()
        // The same span the menu-bar panel reads, so the two surfaces cannot
        // advise differently about the same file. Older cycles are dropped by
        // `Advisor.usableCycles` whether they are read or not.
        let history = FileHistoryStore(store: store)
            .read(from: now.addingTimeInterval(-Advisor.adviceLookback), to: now)
        let snapshots = SnapshotCache(store: store).all()

        let inputs = Advisor.inputs(history: history.samples, snapshots: snapshots, now: now)
            .filter { matches($0.series, arguments) }
        let recommendations = Advisor.recommendations(for: inputs, now: now)

        #if os(Windows)
        let isTerminal = _isatty(1) != 0
        #else
        let isTerminal = isatty(1) == 1
        #endif
        let useColor = arguments.color && isTerminal
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        do {
            print(try Output.advice(recommendations, format: arguments.format, color: useColor))
        } catch {
            fail("could not render advice: \(error.localizedDescription)", code: 1)
        }
        exit(0)
    }

    // MARK: - Shared

    private static func matches(_ series: HistorySeriesID, _ arguments: Arguments) -> Bool {
        if !arguments.providers.isEmpty, !arguments.providers.contains(series.provider) { return false }
        if let key = arguments.windowKey, series.windowKey != key { return false }
        return true
    }

    /// Window labels change; keys do not. Labels come from the cached snapshots
    /// purely so the output reads the way the rest of the app does.
    private static func labels(_ snapshots: [QuotaSnapshot]) -> [HistorySeriesID: String] {
        var labels: [HistorySeriesID: String] = [:]
        for snapshot in snapshots {
            for window in snapshot.windows {
                labels[HistorySeriesID(provider: snapshot.provider, windowKey: window.key)] = window.label
            }
        }
        return labels
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
