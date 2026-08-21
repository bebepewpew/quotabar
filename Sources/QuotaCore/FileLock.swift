import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An advisory exclusive lock taken on a sidecar file.
///
/// The sidecar exists because the files this guards are replaced by an atomic
/// rename, which would otherwise leave each writer holding a different inode and
/// therefore a different lock. `JSONFileStateStore` needs it so a `--watch`
/// process and a one-shot invocation do not clobber each other's keys, and the
/// history log needs the same guarantee for its appends and compaction, so the
/// implementation lives here rather than twice.
enum FileLock {
    /// How long a contended lock is retried before the guarded write goes ahead
    /// without it, in seconds.
    ///
    /// The window the lock closes is one atomic rewrite of a small file, so
    /// contention that outlasts half a second is a holder that has stalled, been
    /// suspended, or is sitting on a slow network filesystem — none of which a
    /// write should wait on, least of all the CLI's, which takes this on the main
    /// actor.
    static let acquisitionDeadline: TimeInterval = 0.5

    /// How long to wait between attempts. Short enough that ordinary contention
    /// is not noticeably delayed, long enough that waiting is not a spin.
    private static let retryInterval: TimeInterval = 0.005

    /// Runs `body` while holding an exclusive lock on `url`.
    ///
    /// Best effort by design: a lock we cannot take must not stop the write it
    /// was protecting, because failing to persist is worse than racing. The lock
    /// is therefore taken without blocking and retried for at most
    /// ``acquisitionDeadline`` — half a second — after which `body` runs unlocked
    /// rather than waiting on the holder. Either way it runs exactly once. Every
    /// caller's own read-modify-write is still correct on its own; the lock only
    /// closes the interleaving window.
    static func withExclusiveLock(at url: URL, _ body: () -> Void) {
        #if os(Windows)
        // `flock` is POSIX-only; `LockFileEx` is the equivalent and belongs with a
        // Windows front-end.
        body()
        #else
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        guard acquire(descriptor) else { return body() }
        defer { flock(descriptor, LOCK_UN) }
        body()
        #endif
    }

    #if !os(Windows)
    /// Takes the lock without ever blocking on it.
    ///
    /// `LOCK_NB` turns contention into an `EWOULDBLOCK` this can retry, so the
    /// wait is bounded by ``acquisitionDeadline`` instead of by whoever holds the
    /// lock. Elapsed time is measured on the monotonic clock: a wait that must be
    /// bounded cannot be lengthened by the wall clock moving.
    private static func acquire(_ descriptor: Int32) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(acquisitionDeadline))
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            // Contention and an interrupted call are worth another attempt.
            // Anything else — a descriptor that cannot be locked at all — will
            // not clear by waiting, so it falls through to the unlocked write
            // immediately, exactly as the blocking version did.
            guard errno == EWOULDBLOCK || errno == EINTR else { return false }
            guard clock.now < deadline else { return false }
            Thread.sleep(forTimeInterval: retryInterval)
        }
    }
    #endif

    /// The conventional sidecar path for `url`: the file itself plus `.lock`.
    static func sidecarURL(for url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".lock")
    }
}
