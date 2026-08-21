import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-wide signal dispositions the probes depend on.
public enum ProcessSignals {
    /// Ignores `SIGPIPE`, so a write to a pipe whose reader has exited returns
    /// `EPIPE` and surfaces as a thrown error instead of killing the process.
    ///
    /// Every probe writes to a child's stdin, and `CodexProbe.fetch` does it
    /// *after* the initialize response — if `codex app-server` exits between that
    /// reply and the `initialized`/`rateLimits` writes, the default disposition
    /// takes the whole menu bar down with signal 13 rather than failing one
    /// refresh. `CommandRunner.run` has the same exposure writing `input`.
    ///
    /// The disposition is global to the process and installed exactly once, so
    /// this is safe to call from anywhere and cheap to call repeatedly. Hosts
    /// call it at startup; the two seams that own pipes call it as well, so the
    /// guarantee does not depend on an entry point remembering to.
    ///
    /// Windows has no `SIGPIPE` — a write to a broken pipe there already fails
    /// as an ordinary error.
    public static func ignoreBrokenPipe() { _ = brokenPipeIgnored }

    #if os(Windows)
    private static let brokenPipeIgnored = true
    #else
    /// A global `let` is initialised under `swift_once`, so concurrent probes
    /// cannot race to install this.
    private static let brokenPipeIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()
    #endif
}
