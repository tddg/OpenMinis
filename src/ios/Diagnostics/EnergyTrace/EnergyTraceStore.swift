import Foundation

// MARK: - JSONL trace store
//
// Buffered writer for one trace file per run. Records are encoded on the
// caller's executor (the EnergyTrace actor — never the main actor), buffered
// in memory, and flushed to disk when the buffer threshold is reached, when
// the flush interval elapses, or explicitly at run end. There is deliberately
// no synchronous per-record disk write — see the overhead requirements in the
// instrumentation spec.
//
// Lock-guarded class rather than an actor so appends from the EnergyTrace
// actor are synchronous and file line order matches call order (same pattern
// as PerfTrace / ShellCommandRingBuffer).
//
// Files live in Library/Application Support/EnergyTraces/ and are pruned
// oldest-first past the configured file-count / total-byte bounds. A crash can
// leave a partial final line; the offline parser must skip undecodable lines.

final class EnergyTraceStore: @unchecked Sendable {
    static let shared = EnergyTraceStore()

    private let directory: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var _currentFileURL: URL?
    private var buffer: [Data] = []
    private var flushTask: Task<Void, Never>?
    private let encoder: JSONEncoder

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            // Documents (not Application Support) so traces surface in the
            // Files app via UIFileSharingEnabled — researchers pull them by
            // AirDrop without any export step or container download.
            let base = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("EnergyTraces", isDirectory: true)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
    }

    var currentFileURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _currentFileURL
    }

    // MARK: Lifecycle

    /// Creates and opens a new trace file for a run. Any previously open file
    /// is flushed and closed first.
    @discardableResult
    func open(runID: UUID) throws -> URL {
        closeCurrent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let stamp = Self.filenameStamp()
        let prefix = runID.uuidString.prefix(8).lowercased()
        let url = directory.appendingPathComponent("energy-trace-\(stamp)-\(prefix).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let newHandle = try FileHandle(forWritingTo: url)
        lock.lock()
        handle = newHandle
        _currentFileURL = url
        lock.unlock()
        pruneIfNeeded()
        return url
    }

    func append(_ record: EnergyTraceRecord) {
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        let config = EnergyTraceState.configuration

        lock.lock()
        guard handle != nil else { lock.unlock(); return }
        buffer.append(data)
        let shouldFlushNow = buffer.count >= config.maxBufferedRecords
        let needsTimer = !shouldFlushNow && flushTask == nil
        lock.unlock()

        if shouldFlushNow {
            flush()
        } else if needsTimer {
            scheduleFlush(after: config.flushIntervalSeconds)
        }
    }

    func flush() {
        lock.lock()
        flushTask?.cancel()
        flushTask = nil
        guard let handle, !buffer.isEmpty else { lock.unlock(); return }
        var joined = Data()
        for chunk in buffer { joined.append(chunk) }
        buffer.removeAll(keepingCapacity: true)
        do {
            try handle.write(contentsOf: joined)
        } catch {
            NSLog("[EnergyTraceStore] [ERROR] flush failed: %@", String(describing: error))
        }
        lock.unlock()
    }

    /// Flushes and closes the current trace file. Safe to call repeatedly.
    func closeCurrent() {
        flush()
        lock.lock()
        try? handle?.close()
        handle = nil
        _currentFileURL = nil
        lock.unlock()
    }

    private func scheduleFlush(after seconds: Double) {
        lock.lock()
        guard flushTask == nil else { lock.unlock(); return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
        lock.unlock()
    }

    private func timerFired() {
        lock.lock()
        flushTask = nil
        lock.unlock()
        flush()
    }

    // MARK: Retention

    struct TraceFileInfo: Sendable {
        let url: URL
        let sizeBytes: Int64
        let modified: Date
    }

    func listTraceFiles() -> [TraceFileInfo] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return TraceFileInfo(url: url,
                                     sizeBytes: Int64(values?.fileSize ?? 0),
                                     modified: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified < $1.modified }
    }

    /// Prunes oldest-first past maxTraceFiles / maxTotalTraceBytes. The
    /// currently open file is never pruned.
    func pruneIfNeeded() {
        let config = EnergyTraceState.configuration
        let current = currentFileURL
        var files = listTraceFiles().filter { $0.url != current }
        var totalBytes = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if let current,
           let size = try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            totalBytes += Int64(size)
        }
        var fileCount = files.count + (current != nil ? 1 : 0)

        while let oldest = files.first,
              fileCount > config.maxTraceFiles || totalBytes > config.maxTotalTraceBytes {
            try? FileManager.default.removeItem(at: oldest.url)
            totalBytes -= oldest.sizeBytes
            fileCount -= 1
            files.removeFirst()
        }
    }

    func deleteAllTraces() {
        closeCurrent()
        for file in listTraceFiles() {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    // MARK: Helpers

    private static func filenameStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
