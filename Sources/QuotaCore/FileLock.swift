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
    /// Runs `body` while holding an exclusive lock on `url`.
    ///
    /// Best effort by design: a lock we cannot take must not stop the write it
    /// was protecting, because failing to persist is worse than racing. Every
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
        guard flock(descriptor, LOCK_EX) == 0 else { return body() }
        defer { flock(descriptor, LOCK_UN) }
        body()
        #endif
    }

    /// The conventional sidecar path for `url`: the file itself plus `.lock`.
    static func sidecarURL(for url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".lock")
    }
}
