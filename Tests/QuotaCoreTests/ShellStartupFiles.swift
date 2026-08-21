import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Keeps the login-shell rung of `CommandRunner.find` away from the developer's
/// shell startup files.
///
/// `find` asks *every* candidate shell when a name resolves nowhere, so a test
/// that lets the search fall through runs the machine's own `/bin/zsh -lic` and
/// `/bin/bash -lic` — interactive login shells, which source `~/.zshrc` and
/// `~/.bash_profile`. That makes the test assert against whatever the developer
/// keeps there, take as long as those files take to run, and mean something
/// different in the CI container.
///
/// A test that can name the ladder passes `shells:` to `CommandRunner.find` and
/// never spawns a real shell at all. The ones that cannot — the ones covering
/// `runExpect` and `QuotaEngine`'s default locator, which reach `find`
/// internally — wrap themselves in this instead: the shells still run, but the
/// startup files they look for are in an empty directory rather than in `$HOME`.
///
/// The variables are process-wide, so this is only safe while the suite runs
/// its XCTest cases one at a time, which is `swift test`'s default.
enum ShellStartupFiles {
    /// Runs `body` with `HOME` and `ZDOTDIR` pointed at an empty directory and
    /// the startup-file hooks a shell reads before them cleared.
    static func suppressed<T>(_ body: () throws -> T) rethrows -> T {
        let staging = stage()
        defer { staging.restore() }
        return try body()
    }

    /// The same for work that suspends. Discovery hops onto a background queue,
    /// so the staging has to outlive the `await` rather than the call.
    static func suppressed<T>(_ body: () async throws -> T) async rethrows -> T {
        let staging = stage()
        defer { staging.restore() }
        return try await body()
    }

    private struct Staging {
        let directory: URL
        /// A list rather than a dictionary: a variable that was unset has to be
        /// restored to unset, and `[String: String?]` cannot hold that apart
        /// from an absent key.
        let previous: [(key: String, value: String?)]

        func restore() {
            for entry in previous {
                if let value = entry.value { setenv(entry.key, value, 1) } else { unsetenv(entry.key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func stage() -> Staging {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-empty-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // `HOME` is where every shell looks for its own startup files, and
        // `ZDOTDIR` is what zsh looks at first. `ENV` and `BASH_ENV` name a file
        // to source outright, so a developer who sets either has to have it
        // cleared rather than redirected.
        let staged: [(key: String, value: String?)] = [("HOME", directory.path), ("ZDOTDIR", directory.path),
                                                       ("ENV", nil), ("BASH_ENV", nil)]
        let previous = staged.map { (key: $0.key, value: ProcessInfo.processInfo.environment[$0.key]) }
        for entry in staged {
            if let value = entry.value { setenv(entry.key, value, 1) } else { unsetenv(entry.key) }
        }
        return Staging(directory: directory, previous: previous)
    }
}
