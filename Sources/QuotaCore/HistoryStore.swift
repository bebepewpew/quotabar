import Foundation

// MARK: - Identity

/// The stable identity of one quota series: a provider and a window *key*.
///
/// Keys, never labels. `AGENTS.md` makes window keys identity and labels display
/// data, so a provider renaming "5-hour limit" to "Session" must not orphan three
/// months of history.
public struct HistorySeriesID: Hashable, Sendable, Codable {
    public let provider: Provider
    public let windowKey: String

    public init(provider: Provider, windowKey: String) {
        self.provider = provider
        self.windowKey = windowKey
    }

    /// The value the file's 32-bit series hash is computed over.
    var hashInput: String { "\(provider.slug)|\(windowKey)" }
}

/// One quota reading for one window at one instant — the unit the history file
/// stores and every later analysis reads back.
public struct UsageSample: Sendable, Equatable {
    public let series: HistorySeriesID
    public let at: Date
    public let usedPercent: Double
    public let resetAt: Date?

    public init(series: HistorySeriesID, at: Date, usedPercent: Double, resetAt: Date?) {
        self.series = series
        self.at = at
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }
}

// MARK: - Series catalogue

/// Maps the 32-bit hash stored in every record back to the series it identifies.
///
/// Records stay fixed-width by storing a hash rather than a variable-length key,
/// and this map — not the hash function — is the authority on identity. It
/// persists through `StateStore`, so the metadata half of history uses the seam
/// `AGENTS.md` mandates and inherits its backward-compatible decoding.
public final class HistorySeriesCatalog: @unchecked Sendable {
    public static let storageKey = "QuotaBar.historySeries.v1"

    /// A hash already claimed by a *different* series is astronomically unlikely
    /// across the handful of windows three CLIs report. It is also silent when it
    /// happens — two providers' usage would merge into one line — so assignment
    /// re-salts until it finds a free slot rather than trusting the odds.
    static let maximumSaltAttempts: UInt32 = 1_000

    private let store: StateStore
    private let lock = NSLock()
    private var entries: [UInt32: HistorySeriesID]

    public init(store: StateStore = StateStoreFactory.makeDefault()) {
        self.store = store
        let decoded = store.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Dictionary(decoded.map { ($0.hash, $0.series) }, uniquingKeysWith: { first, _ in first })
    }

    /// The hash for `series`, registering and persisting one if it is new.
    public func hash(for series: HistorySeriesID) -> UInt32 {
        lock.withLock {
            if let existing = registeredLocked(series) { return existing }
            // Another process may have registered this series since we loaded, and
            // the stored map is what every reader will consult. Adopt it before
            // allocating, or a `--watch` process and a one-shot invocation could
            // file the same series under two different hashes.
            adoptStoredLocked()
            if let existing = registeredLocked(series) { return existing }

            var candidate = Self.fnv1a(series.hashInput)
            var salt: UInt32 = 0
            while let claimant = entries[candidate], claimant != series, salt < Self.maximumSaltAttempts {
                salt += 1
                candidate = Self.fnv1a("\(series.hashInput)|\(salt)")
            }
            entries[candidate] = series
            persistLocked()
            return candidate
        }
    }

    private func registeredLocked(_ series: HistorySeriesID) -> UInt32? {
        entries.first(where: { $0.value == series })?.key
    }

    /// Folds whatever is stored into the in-memory map, letting the stored entry
    /// win. A hash already published is one records on disk already use.
    private func adoptStoredLocked() {
        for entry in storedLocked() { entries[entry.hash] = entry.series }
    }

    private func storedLocked() -> [Entry] {
        store.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    public func series(for hash: UInt32) -> HistorySeriesID? { lock.withLock { entries[hash] } }

    public func all() -> [UInt32: HistorySeriesID] { lock.withLock { entries } }

    /// Forgets every mapping. Only `--clear` should reach this: a record whose
    /// hash has no series reads as unknown, not as a crash.
    public func removeAll() {
        lock.withLock {
            entries = [:]
            store.setData(nil, forKey: Self.storageKey)
        }
    }

    /// Writes the union of what is stored and what we hold, so a second process
    /// registering a different series concurrently does not have its entry
    /// replaced by our start-of-process view — the same clobber
    /// `JSONFileStateStore` merges to avoid for its keys.
    ///
    /// A payload we cannot encode must not wipe the saved one either, so a failed
    /// encode leaves the stored bytes alone rather than writing nil over them.
    private func persistLocked() {
        var merged = Dictionary(storedLocked().map { ($0.hash, $0.series) },
                                uniquingKeysWith: { first, _ in first })
        for (hash, series) in entries where merged[hash] == nil { merged[hash] = series }
        entries = merged
        let payload = merged.map { Entry(hash: $0.key, series: $0.value) }.sorted { $0.hash < $1.hash }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        store.setData(data, forKey: Self.storageKey)
    }

    /// FNV-1a, 32-bit. Chosen for being short, dependency-free and stable across
    /// platforms and launches — Swift's own `Hasher` is seeded per process and
    /// would hand the same series a different hash on every run.
    static func fnv1a(_ value: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    private struct Entry: Codable {
        let hash: UInt32
        let series: HistorySeriesID
    }
}

// MARK: - File format

/// The on-disk shape of `history.bin`: a 32-byte header, then fixed-stride
/// 12-byte records appended in time order.
///
/// Fixed stride rather than varint or JSON because it makes the file its own
/// index — record `n` sits at a known offset, a torn write is visible as a size
/// that is not a multiple of the stride, and a full scan is integer loads with no
/// parsing. Three months at the default refresh interval is about 828 KB.
enum HistoryFormat {
    static let magic: [UInt8] = Array("QBH1".utf8)
    static let version: UInt16 = 1
    static let headerLength = 32
    static let recordStride = 12

    /// `resetIn` sentinel for "this window reported no reset time".
    static let noReset: UInt16 = 0xFFFF
    /// One below the sentinel. 65534 minutes is 45 days and the longest real
    /// window is a week, so clamping here can only ever affect nonsense input.
    static let maximumResetMinutes: UInt16 = 0xFFFE

    struct Header: Equatable {
        var version: UInt16 = HistoryFormat.version
        var stride: UInt16 = UInt16(HistoryFormat.recordStride)
        /// Record times are seconds after this instant, which keeps the offset
        /// small and still leaves 136 years of range in a `UInt32`.
        var epoch: Date

        func encoded() -> Data {
            var bytes = HistoryFormat.magic
            bytes += littleEndian(version)
            bytes += littleEndian(stride)
            bytes += littleEndian(UInt64(max(0, epoch.timeIntervalSince1970).rounded()))
            bytes += littleEndian(UInt32(0))    // flags, unused at version 1
            bytes += [UInt8](repeating: 0, count: 12)
            return Data(bytes)
        }

        /// `nil` when the bytes are not a QuotaBar history header — truncated,
        /// empty or foreign. The caller replaces the first two and leaves the
        /// third alone.
        static func decode(_ data: Data) -> Header? {
            let bytes = [UInt8](data)
            guard bytes.count >= HistoryFormat.headerLength,
                  Array(bytes[0..<4]) == HistoryFormat.magic else { return nil }
            return Header(version: HistoryFormat.readUInt16(bytes, at: 4),
                          stride: HistoryFormat.readUInt16(bytes, at: 6),
                          epoch: Date(timeIntervalSince1970: TimeInterval(HistoryFormat.readUInt64(bytes, at: 8))))
        }

        /// Whether this build may both read and append. A newer format, or a
        /// stride we do not recognise, is readable by nobody here and writable by
        /// nobody here either.
        var isSupported: Bool {
            version <= HistoryFormat.version && Int(stride) == HistoryFormat.recordStride
        }
    }

    /// A sample as 12 bytes, or `nil` when it cannot be represented: before the
    /// file's epoch, past its range, or carrying a percentage that is not a
    /// number. Refusing here is what keeps every stored record decodable.
    static func encodeRecord(_ sample: UsageSample, hash: UInt32, epoch: Date) -> Data? {
        guard sample.usedPercent.isFinite else { return nil }
        let offset = sample.at.timeIntervalSince(epoch).rounded()
        guard offset >= 0, offset <= TimeInterval(UInt32.max) else { return nil }

        var bytes = littleEndian(UInt32(offset))
        bytes += littleEndian(hash)
        bytes += littleEndian(UInt16((min(max(sample.usedPercent, 0), 100) * 100).rounded()))
        bytes += littleEndian(resetMinutes(from: sample.at, to: sample.resetAt))
        return Data(bytes)
    }

    /// Minutes until the reset, or the sentinel when there is none.
    ///
    /// A reset already in the past stores as 0 rather than clamping to the
    /// sentinel: "resets now" is a real state a window sits in between the
    /// deadline passing and the next probe, and it is not the same as "unknown".
    static func resetMinutes(from now: Date, to resetAt: Date?) -> UInt16 {
        guard let resetAt else { return noReset }
        let minutes = (resetAt.timeIntervalSince(now) / 60).rounded()
        guard minutes.isFinite else { return noReset }
        guard minutes > 0 else { return 0 }
        return minutes >= TimeInterval(maximumResetMinutes) ? maximumResetMinutes : UInt16(minutes)
    }

    /// The four fields of one record, still untrusted: the caller resolves the
    /// hash and clamps the percentage.
    struct RawRecord: Equatable {
        let offsetSeconds: UInt32
        let hash: UInt32
        let centi: UInt16
        let resetMinutes: UInt16
    }

    static func decodeRecord(_ bytes: [UInt8], at index: Int) -> RawRecord {
        RawRecord(offsetSeconds: readUInt32(bytes, at: index),
                  hash: readUInt32(bytes, at: index + 4),
                  centi: readUInt16(bytes, at: index + 8),
                  resetMinutes: readUInt16(bytes, at: index + 10))
    }

    /// Turns a decoded record back into a sample. Percentages are clamped on the
    /// way out as well as in: the file is as untrusted as the CLI text was.
    static func sample(from record: RawRecord, series: HistorySeriesID, epoch: Date) -> UsageSample {
        let at = epoch.addingTimeInterval(TimeInterval(record.offsetSeconds))
        return UsageSample(series: series,
                           at: at,
                           usedPercent: min(max(Double(record.centi) / 100, 0), 100),
                           resetAt: record.resetMinutes == noReset
                               ? nil
                               : at.addingTimeInterval(TimeInterval(record.resetMinutes) * 60))
    }

    // MARK: Little-endian primitives

    static func littleEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
    }

    static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }

    static func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[index + $1]) << (8 * UInt32($1))) }
    }

    static func readUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | (UInt64(bytes[index + $1]) << (8 * UInt64($1))) }
    }
}

// MARK: - Location

/// Where the history log lives, per platform.
///
/// History is state, not configuration, so it does not join `state.json` under
/// the config root. The convention is selected at runtime rather than with `#if`
/// for the same reason `JSONFileStateStore` does it: every platform's rule stays
/// compiled, and therefore testable, wherever the suite happens to run.
public enum HistoryLocation {
    enum StateBase: Sendable, Equatable {
        /// `~/Library/Application Support`.
        case applicationSupport
        /// `${XDG_STATE_HOME:-~/.local/state}`.
        case xdgState
        /// `%LOCALAPPDATA%`, falling back to `~/AppData/Local`.
        case windowsLocalAppData
    }

    static var platformBase: StateBase {
        #if os(macOS)
        .applicationSupport
        #elseif os(Windows)
        .windowsLocalAppData
        #else
        .xdgState
        #endif
    }

    public static func defaultURL() -> URL {
        defaultURL(environment: ProcessInfo.processInfo.environment,
                   home: FileManager.default.homeDirectoryForCurrentUser,
                   base: platformBase)
    }

    static func defaultURL(environment: [String: String], home: URL, base convention: StateBase) -> URL {
        directory(environment: environment, home: home, base: convention)
            .appendingPathComponent("history.bin")
    }

    static func directory(environment: [String: String], home: URL, base convention: StateBase) -> URL {
        switch convention {
        case .applicationSupport:
            return home.appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("QuotaBar", isDirectory: true)
        case .windowsLocalAppData:
            let base: URL
            if let local = environment["LOCALAPPDATA"], !local.isEmpty {
                base = URL(fileURLWithPath: local, isDirectory: true)
            } else {
                base = home.appendingPathComponent("AppData", isDirectory: true)
                    .appendingPathComponent("Local", isDirectory: true)
            }
            return base.appendingPathComponent("QuotaBar", isDirectory: true)
        case .xdgState:
            let base: URL
            if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
                base = URL(fileURLWithPath: xdg, isDirectory: true)
            } else {
                base = home.appendingPathComponent(".local", isDirectory: true)
                    .appendingPathComponent("state", isDirectory: true)
            }
            return base.appendingPathComponent("quotabar", isDirectory: true)
        }
    }
}

// MARK: - Store

/// What a read returned, and what it had to skip to return it.
///
/// The count is reported rather than swallowed so `quotabar history` can say
/// "2 damaged records ignored". Recording stays silent by contrast: a damaged
/// history file must never turn into a failed quota refresh.
public struct HistoryReadResult: Sendable, Equatable {
    public let samples: [UsageSample]
    public let damagedRecords: Int
    public let hasPartialTail: Bool
    /// Set when the file was written by a newer build and left untouched.
    public let unreadableVersion: UInt16?

    public init(samples: [UsageSample] = [], damagedRecords: Int = 0,
                hasPartialTail: Bool = false, unreadableVersion: UInt16? = nil) {
        self.samples = samples
        self.damagedRecords = damagedRecords
        self.hasPartialTail = hasPartialTail
        self.unreadableVersion = unreadableVersion
    }

    /// One concise line, or nil when the read was clean.
    public var diagnostic: String? {
        if let unreadableVersion {
            return "History was written by a newer QuotaBar (format \(unreadableVersion)) and was left unchanged."
        }
        var parts: [String] = []
        if damagedRecords > 0 {
            parts.append("\(damagedRecords) damaged record\(damagedRecords == 1 ? "" : "s") ignored")
        }
        if hasPartialTail { parts.append("an incomplete final record was discarded") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

/// Append-only usage history. A seam, so front-ends and analysis can be driven
/// from a scripted store instead of a real file.
public protocol HistoryStore: AnyObject, Sendable {
    /// Appends what it can and reports how many records landed. Never throws:
    /// history is best effort and must not turn a working refresh into a failure.
    @discardableResult func append(_ samples: [UsageSample]) -> Int
    func read(from: Date, to: Date) -> HistoryReadResult
    /// The most recent sample per series — all a recorder needs to apply a
    /// deadband and spot a cycle boundary.
    func heads() -> [HistorySeriesID: UsageSample]
    /// Drops records older than `horizon` before `now`, reporting how many went.
    @discardableResult func compact(now: Date, horizon: TimeInterval) -> Int
    func removeAll()
}

extension HistoryStore {
    public func read() -> HistoryReadResult { read(from: .distantPast, to: .distantFuture) }
}

/// The file-backed implementation.
///
/// Every write takes the sidecar lock, appends at the end and returns; nothing
/// rewrites the file except `compact`, which runs rarely and lands through an
/// atomic replace. There is no fsync in the append path on purpose — losing the
/// last few minutes of quota telemetry to a power cut is acceptable, and an fsync
/// on every refresh in a long-running menu-bar app is not.
public final class FileHistoryStore: HistoryStore, @unchecked Sendable {
    /// Records are decoded in chunks this size, so resident memory stays flat
    /// however long the history grows.
    static let readChunkBytes = 64 * 1_024

    public static let defaultHorizon: TimeInterval = 120 * 86_400
    /// A backstop for a pathological refresh interval, independent of age.
    public static let maximumFileBytes = 32 * 1_024 * 1_024

    private let url: URL
    private let catalog: HistorySeriesCatalog
    private let lock = NSLock()

    public init(url: URL? = nil, catalog: HistorySeriesCatalog? = nil,
                store: StateStore = StateStoreFactory.makeDefault()) {
        self.url = url ?? HistoryLocation.defaultURL()
        self.catalog = catalog ?? HistorySeriesCatalog(store: store)
    }

    // MARK: Writing

    @discardableResult
    public func append(_ samples: [UsageSample]) -> Int {
        guard let first = samples.first else { return 0 }
        // Resolve hashes before taking the file lock. Registering a series writes
        // through `StateStore`, which takes a lock of its own, and taking them in
        // this order everywhere is what keeps the two from deadlocking.
        let resolved = samples.map { (sample: $0, hash: catalog.hash(for: $0.series)) }

        var written = 0
        lock.withLock {
            FileLock.withExclusiveLock(at: FileLock.sidecarURL(for: url)) {
                guard let handle = openForUpdate(creatingHeaderAt: first.at) else { return }
                defer { try? handle.close() }
                // A file a newer build wrote is never appended to, so downgrading
                // and running the old binary cannot corrupt it.
                guard let header = currentHeader(handle), header.isSupported else { return }
                discardPartialTail(handle)

                var payload = Data()
                var encoded = 0
                for entry in resolved {
                    guard let record = HistoryFormat.encodeRecord(entry.sample, hash: entry.hash,
                                                                  epoch: header.epoch) else { continue }
                    payload.append(record)
                    encoded += 1
                }
                guard !payload.isEmpty, let end = try? handle.seekToEnd() else { return }
                do {
                    try handle.write(contentsOf: payload)
                    written = encoded
                } catch {
                    // A partial write leaves a torn record for the next reader to
                    // find. Put the file back where it was instead.
                    try? handle.truncate(atOffset: end)
                }
            }
        }
        return written
    }

    // MARK: Reading

    public func read(from: Date, to: Date) -> HistoryReadResult {
        let known = catalog.all()
        var samples: [UsageSample] = []
        let outcome = streamRecords { header, record in
            guard let series = known[record.hash] else { return false }
            let sample = HistoryFormat.sample(from: record, series: series, epoch: header.epoch)
            guard sample.at >= from, sample.at <= to else { return true }
            samples.append(sample)
            return true
        }
        // Appends run in time order per process, but two processes interleave and
        // a clock can step backwards, so file order is only approximately time
        // order. Sorting is what makes the result dependable; discarding the
        // records that arrived late would silently lose a concurrent writer's.
        samples.sort { $0.at < $1.at }
        return HistoryReadResult(samples: samples,
                                 damagedRecords: outcome.damaged,
                                 hasPartialTail: outcome.partialTail,
                                 unreadableVersion: outcome.unreadableVersion)
    }

    public func heads() -> [HistorySeriesID: UsageSample] {
        // A full scan rather than a tail read: a series that stopped being sampled
        // weeks ago still has a head, and it is nowhere near the end of the file.
        // Only the latest per series is retained, so this costs one chunk of
        // memory rather than one entry per record.
        let known = catalog.all()
        var latest: [HistorySeriesID: UsageSample] = [:]
        _ = streamRecords { header, record in
            guard let series = known[record.hash] else { return false }
            let sample = HistoryFormat.sample(from: record, series: series, epoch: header.epoch)
            if let existing = latest[series], existing.at >= sample.at { return true }
            latest[series] = sample
            return true
        }
        return latest
    }

    // MARK: Retention

    @discardableResult
    public func compact(now: Date, horizon: TimeInterval = FileHistoryStore.defaultHorizon) -> Int {
        let cutoff = now.addingTimeInterval(-horizon)
        var dropped = 0
        lock.withLock {
            FileLock.withExclusiveLock(at: FileLock.sidecarURL(for: url)) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return }
                defer { try? handle.close() }
                guard let header = currentHeader(handle), header.isSupported,
                      let count = recordCount(handle), count > 0 else { return }

                // Everything expired is a prefix, so the live range starts at the
                // first record inside the horizon and runs to the end. Stopping at
                // the *first* live record is what keeps this safe when file order
                // is only approximately time order: a record sitting before it is
                // necessarily older than the cutoff, so nothing live is ever cut.
                var firstLive = count
                for index in 0..<count {
                    guard let raw = readRecord(handle, index: index) else { break }
                    if header.epoch.addingTimeInterval(TimeInterval(raw.offsetSeconds)) >= cutoff {
                        firstLive = index
                        break
                    }
                }
                guard firstLive > 0 else { return }

                let liveOffset = UInt64(HistoryFormat.headerLength + firstLive * HistoryFormat.recordStride)
                var live = Data()
                if (try? handle.seek(toOffset: liveOffset)) != nil, let tail = try? handle.readToEnd() {
                    live = tail
                }

                // `.atomic` is the same temp-file-and-rename the state store uses,
                // so a concurrent reader sees the whole old file or the whole new
                // one and never a half-copied middle.
                guard (try? (header.encoded() + live).write(to: url, options: .atomic)) != nil else { return }
                dropped = firstLive
            }
        }
        return dropped
    }

    /// Whether the file is worth rewriting yet. The common answer costs a header
    /// and one record rather than a scan.
    public func needsCompaction(now: Date, horizon: TimeInterval = FileHistoryStore.defaultHorizon) -> Bool {
        lock.withLock {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            if let end = try? handle.seekToEnd(), Int(end) >= Self.maximumFileBytes { return true }
            guard let header = currentHeader(handle), header.isSupported,
                  let oldest = readRecord(handle, index: 0) else { return false }
            let at = header.epoch.addingTimeInterval(TimeInterval(oldest.offsetSeconds))
            return now.timeIntervalSince(at) > horizon
        }
    }

    public func removeAll() {
        lock.withLock {
            FileLock.withExclusiveLock(at: FileLock.sidecarURL(for: url)) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        catalog.removeAll()
    }

    // MARK: Plumbing

    /// Opens the file for update, creating it with a fresh header when it is
    /// absent or shorter than one.
    ///
    /// A file that is long enough but carries a foreign magic is left exactly as
    /// it is: refusing to record is recoverable, and overwriting something we did
    /// not write is not.
    private func openForUpdate(creatingHeaderAt epoch: Date) -> FileHandle? {
        let manager = FileManager.default
        if (try? FileHandle(forReadingFrom: url))?.readAndClose(HistoryFormat.headerLength) == nil {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The epoch is the start of the creation day, so offsets stay small and
            // a sample stamped slightly before "now" is still representable.
            let base = Date(timeIntervalSince1970: (epoch.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
            guard manager.createFile(atPath: url.path,
                                     contents: HistoryFormat.Header(epoch: base).encoded()) else { return nil }
        }
        return try? FileHandle(forUpdating: url)
    }

    private func currentHeader(_ handle: FileHandle) -> HistoryFormat.Header? {
        guard (try? handle.seek(toOffset: 0)) != nil,
              let data = try? handle.read(upToCount: HistoryFormat.headerLength) else { return nil }
        return HistoryFormat.Header.decode(data)
    }

    /// How many whole records the file holds, ignoring any torn tail.
    private func recordCount(_ handle: FileHandle) -> Int? {
        guard let end = try? handle.seekToEnd() else { return nil }
        return max(0, Int(end) - HistoryFormat.headerLength) / HistoryFormat.recordStride
    }

    /// A crash between two writes can leave fewer than `stride` bytes at the end.
    /// Cut them before appending so record boundaries stay aligned.
    private func discardPartialTail(_ handle: FileHandle) {
        guard let end = try? handle.seekToEnd() else { return }
        let remainder = max(0, Int(end) - HistoryFormat.headerLength) % HistoryFormat.recordStride
        guard remainder != 0 else { return }
        try? handle.truncate(atOffset: end - UInt64(remainder))
    }

    private func readRecord(_ handle: FileHandle, index: Int) -> HistoryFormat.RawRecord? {
        let offset = UInt64(HistoryFormat.headerLength + index * HistoryFormat.recordStride)
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: HistoryFormat.recordStride),
              data.count == HistoryFormat.recordStride else { return nil }
        return HistoryFormat.decodeRecord([UInt8](data), at: 0)
    }

    private struct ScanOutcome {
        var damaged = 0
        var partialTail = false
        var unreadableVersion: UInt16?
    }

    /// Streams every whole record through `accept` in bounded chunks, counting the
    /// ones it rejects. `accept` returns false for a record it could not place —
    /// an unknown series — which is what "damaged" counts.
    private func streamRecords(_ accept: (HistoryFormat.Header, HistoryFormat.RawRecord) -> Bool) -> ScanOutcome {
        lock.withLock {
            var outcome = ScanOutcome()
            guard let handle = try? FileHandle(forReadingFrom: url) else { return outcome }
            defer { try? handle.close() }
            guard let header = currentHeader(handle) else { return outcome }
            guard header.isSupported else {
                outcome.unreadableVersion = header.version
                return outcome
            }
            guard let end = try? handle.seekToEnd() else { return outcome }
            let available = max(0, Int(end) - HistoryFormat.headerLength)
            outcome.partialTail = available % HistoryFormat.recordStride != 0

            let chunk = Self.readChunkBytes - (Self.readChunkBytes % HistoryFormat.recordStride)
            var offset = UInt64(HistoryFormat.headerLength)

            while true {
                guard (try? handle.seek(toOffset: offset)) != nil,
                      let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
                let bytes = [UInt8](data)
                let usable = (bytes.count / HistoryFormat.recordStride) * HistoryFormat.recordStride
                guard usable > 0 else { break }

                var index = 0
                while index < usable {
                    if !accept(header, HistoryFormat.decodeRecord(bytes, at: index)) { outcome.damaged += 1 }
                    index += HistoryFormat.recordStride
                }
                offset += UInt64(usable)
            }
            return outcome
        }
    }
}

private extension FileHandle {
    /// Reads up to `count` bytes and closes, returning nil when the file could not
    /// supply that many. Used only to ask "is there a header here at all".
    func readAndClose(_ count: Int) -> Data? {
        defer { try? close() }
        guard let data = try? read(upToCount: count), data.count == count else { return nil }
        return data
    }
}
