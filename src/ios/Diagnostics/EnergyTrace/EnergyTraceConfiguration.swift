import Foundation
import CryptoKit

// MARK: - Configuration
//
// Energy tracing is OFF by default and enabled only for controlled
// experiments (debug RPC or settings UI). The enabled flag is runtime-only —
// deliberately not persisted — so a crash or restart can never leave tracing
// silently on for normal usage.
//
// The enabled check mirrors the PerfTrace pattern: a lock-guarded static so
// call sites can bail out with a cheap boolean read before paying any actor
// hop. Disabled mode must cost effectively nothing.

struct EnergyTraceConfiguration: Sendable, Equatable {
    /// Resource-sample cadence while a run is active. Clamped to {1, 2, 5, 10}.
    var samplingIntervalSeconds: Double = 2

    /// Retention: prune oldest trace files beyond either bound.
    var maxTraceFiles: Int = 30
    var maxTotalTraceBytes: Int64 = 200 * 1024 * 1024

    /// JSONL writer buffering. Records buffer in memory and hit disk when
    /// either the record threshold is reached or the flush interval elapses.
    var maxBufferedRecords: Int = 128
    var flushIntervalSeconds: Double = 5

    /// Researcher-only option: include a redacted command preview alongside
    /// the command hash in shell spans. Default (false) stores hash-only.
    var storeCommandPreview: Bool = false

    static let allowedSamplingIntervals: [Double] = [1, 2, 5, 10]

    mutating func clampSamplingInterval() {
        let allowed = Self.allowedSamplingIntervals
        samplingIntervalSeconds = allowed.min {
            abs($0 - samplingIntervalSeconds) < abs($1 - samplingIntervalSeconds)
        } ?? 2
    }
}

enum EnergyTraceState {
    private static let lock = NSLock()
    // Research build: tracing is ON by default — every agent task auto-opens
    // a task-scoped run and writes one JSONL trace to Documents/EnergyTraces/
    // (visible in the Files app), pruned oldest-first by the retention caps.
    // Idle cost is nil: the sampler only runs while a task is active.
    // Flip with `minis-debug rpc debug.energyTrace.disable` when unwanted.
    nonisolated(unsafe) private static var _enabled = true
    nonisolated(unsafe) private static var _configuration = EnergyTraceConfiguration()

    /// Cheap gate for every instrumentation call site. When false, no spans,
    /// events, samples, or file writes happen anywhere in the subsystem.
    static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    static func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        _enabled = on
    }

    static var configuration: EnergyTraceConfiguration {
        lock.lock(); defer { lock.unlock() }
        return _configuration
    }

    static func setConfiguration(_ config: EnergyTraceConfiguration) {
        var c = config
        c.clampSamplingInterval()
        lock.lock(); defer { lock.unlock() }
        _configuration = c
    }
}

// MARK: - Privacy hashing

/// Salted SHA-256 for identifiers that must be stable within an install but
/// not joinable across installs (shell commands, session IDs). The salt is
/// random per install and never leaves the device.
struct EnergyTraceHasher: Sendable {
    let salt: Data

    private static let saltDefaultsKey = "energyTrace.installSalt"
    private static let lock = NSLock()

    /// Hasher using the per-install salt (created on first use).
    static func installHasher(defaults: UserDefaults = .standard) -> EnergyTraceHasher {
        lock.lock(); defer { lock.unlock() }
        if let existing = defaults.data(forKey: saltDefaultsKey), existing.count >= 16 {
            return EnergyTraceHasher(salt: existing)
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        let salt = Data(bytes)
        defaults.set(salt, forKey: saltDefaultsKey)
        return EnergyTraceHasher(salt: salt)
    }

    func hash(_ value: String) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(value.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of a whitespace-normalized shell command, so trivial spacing
    /// differences map to the same identity.
    func hashCommand(_ command: String) -> String {
        let normalized = command
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return hash(normalized)
    }
}
