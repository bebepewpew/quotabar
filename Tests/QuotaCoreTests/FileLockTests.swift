import XCTest
import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import QuotaCore

/// The sidecar lock the state file and the history log share: that it still
/// serialises writers, that it releases, and above all that it is bounded — a
/// holder that never lets go must cost the deadline, not the process.
final class FileLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-file-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    private func sidecar(_ name: String = "guarded.json") -> URL {
        FileLock.sidecarURL(for: directory.appendingPathComponent(name))
    }

    // MARK: - The common path

    func testSidecarPathIsTheGuardedFilePlusLock() {
        XCTAssertEqual(FileLock.sidecarURL(for: URL(fileURLWithPath: "/state/quotabar/state.json")).path,
                       "/state/quotabar/state.json.lock")
    }

    /// Nothing else holds the lock, so this must not pay the deadline for it.
    func testAnUncontendedLockRunsTheBodyOnceAndPromptly() {
        let url = sidecar()
        let runs = Counter()
        let started = DispatchTime.now()
        FileLock.withExclusiveLock(at: url) { runs.increment() }

        XCTAssertEqual(runs.value, 1)
        XCTAssertLessThan(elapsed(since: started), FileLock.acquisitionDeadline,
                          "an uncontended acquisition must not wait at all")
    }

    /// The lock is released on the way out, not just when the process exits.
    func testTheLockIsReleasedWhenTheBodyReturns() throws {
        let url = sidecar()
        FileLock.withExclusiveLock(at: url) {}

        #if !os(Windows)
        let descriptor = try XCTUnwrap(openSidecar(url))
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0,
                       "the sidecar must be lockable again once the guarded write is done")
        flock(descriptor, LOCK_UN)
        #endif
    }

    /// The lock still has to be a lock: the deadline changes how long a writer
    /// waits, never whether the guarded writes overlap when nobody is stalled.
    func testConcurrentCallersRunTheirBodiesOneAtATime() {
        let url = sidecar()
        let inside = Counter(), overlaps = Counter(), runs = Counter()
        // Eight bodies of 10ms are far inside the half-second deadline, so this
        // measures exclusion rather than anybody giving up.
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            FileLock.withExclusiveLock(at: url) {
                if inside.increment() > 1 { overlaps.increment() }
                Thread.sleep(forTimeInterval: 0.01)
                inside.decrement()
                runs.increment()
            }
        }

        XCTAssertEqual(runs.value, 8)
        XCTAssertEqual(overlaps.value, 0, "a non-blocking acquisition must still serialise the writers")
    }

    // MARK: - Best effort

    /// Best effort means the write happens anyway. A sidecar under a path that is
    /// a regular file can never be opened, and that must cost a lock, not a write.
    func testASidecarThatCannotBeOpenedStillRunsTheBody() throws {
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let runs = Counter()

        FileLock.withExclusiveLock(at: blocker.appendingPathComponent("state.json.lock")) { runs.increment() }

        XCTAssertEqual(runs.value, 1)
    }

    #if !os(Windows)
    /// The regression this file exists for. The lock used to be taken with a
    /// blocking `LOCK_EX`, so a holder that stalled — a suspended process, a home
    /// directory on a network filesystem — blocked every other QuotaBar process
    /// for as long as it liked. Against that implementation the wait below times
    /// out instead of returning.
    func testAContendedLockGivesUpAtTheDeadlineAndStillRunsTheBodyOnce() throws {
        let url = sidecar()
        let holder = try XCTUnwrap(openSidecar(url))
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0, "the test has to be the one holding the lock")
        // Released only at the end, so the lock is contended for the whole wait
        // and any thread still blocked on it can finish afterwards.
        defer { flock(holder, LOCK_UN); close(holder) }

        let runs = Counter()
        let finished = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        DispatchQueue.global(qos: .userInitiated).async {
            FileLock.withExclusiveLock(at: url) { runs.increment() }
            finished.signal()
        }

        // Generous enough that a loaded container cannot make it flake, and far
        // short of the unbounded wait it is here to rule out.
        let tolerance = 2.0
        XCTAssertEqual(finished.wait(timeout: .now() + FileLock.acquisitionDeadline + tolerance), .success,
                       "a contended lock must give up at the deadline instead of waiting on the holder")
        XCTAssertEqual(runs.value, 1, "the guarded write still runs, exactly once, without the lock")
        XCTAssertGreaterThan(elapsed(since: started), FileLock.acquisitionDeadline / 2,
                             "it must retry until the deadline rather than give up on first contention")
    }

    /// A holder that lets go inside the deadline is waited for, and the write is
    /// then made under the lock rather than beside it.
    func testAHolderThatReleasesInsideTheDeadlineIsWaitedFor() throws {
        let url = sidecar()
        let holder = try XCTUnwrap(openSidecar(url))
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)

        let held = Counter()
        let finished = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        DispatchQueue.global(qos: .userInitiated).async {
            FileLock.withExclusiveLock(at: url) {
                // Nobody else can be holding it: the test's descriptor let go.
                held.increment()
                finished.signal()
            }
        }

        Thread.sleep(forTimeInterval: 0.05)
        // Only meaningful while the waiter is still inside its deadline; a machine
        // slow enough to blow past it would otherwise fail on its own scheduling.
        if elapsed(since: started) < FileLock.acquisitionDeadline {
            XCTAssertEqual(held.value, 0, "the waiter must not have run while the lock was held")
        }
        flock(holder, LOCK_UN)
        defer { close(holder) }

        XCTAssertEqual(finished.wait(timeout: .now() + FileLock.acquisitionDeadline), .success,
                       "releasing inside the deadline must let the waiter through")
        XCTAssertEqual(held.value, 1)
    }

    private func openSidecar(_ url: URL) -> Int32? {
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        return descriptor >= 0 ? descriptor : nil
    }
    #endif

    private func elapsed(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}

/// A counter several threads touch: the bodies above run wherever the lock lets
/// them, and the assertions read the totals afterwards.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int { lock.withLock { count += 1; return count } }
    func decrement() { lock.withLock { count -= 1 } }
    var value: Int { lock.withLock { count } }
}
