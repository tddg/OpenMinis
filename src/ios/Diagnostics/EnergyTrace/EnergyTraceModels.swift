import Foundation

// MARK: - Schema
//
// Versioned JSONL schema for the energy/battery-impact research trace.
// One JSON object per line; every record carries the common envelope fields
// (schema_version, record_type, wall_time, monotonic_ns, run_id, span_id,
// parent_span_id, name) with record-specific metadata flattened into the same
// top-level object.
//
// Durations must be computed from `monotonic_ns` (CLOCK_MONOTONIC, which on
// Darwin keeps counting across device sleep); `wall_time` exists only for
// human correlation with external tools such as Power Profiler.

enum EnergyTraceSchema {
    static let version = 1
}

enum EnergyRecordType: String, Codable, Sendable {
    case runStart = "run_start"
    case runEnd = "run_end"
    case spanStart = "span_start"
    case spanEnd = "span_end"
    case event = "event"
    case resourceSample = "resource_sample"
}

/// Stable span names. Call sites must use these, never model-generated strings.
enum EnergySpanName: String, Codable, Sendable, CaseIterable {
    case agentTask = "agent_task"
    case modelRequest = "model_request"
    case modelTTFT = "model_time_to_first_token"
    case modelStream = "model_stream"
    case modelPostprocess = "model_postprocess"
    case toolDispatch = "tool_dispatch"
    case shellExecute = "shell_execute"
    case shellOutputSanitize = "shell_output_sanitize"
    case browserAction = "browser_action"
    case browserNavigation = "browser_navigation"
    case browserJavascript = "browser_javascript"
    case browserSnapshot = "browser_snapshot"
    case nativeOffload = "native_offload"
    case fileRead = "file_read"
    case fileWrite = "file_write"
    case statePersist = "state_persist"
    case uiRenderUpdate = "ui_render_update"
    case backgroundWait = "background_wait"
    case remoteRPC = "remote_rpc"
}

/// Workload class assigned by the researcher when starting a controlled run.
/// Normal (non-experiment) user runs use `.unknown`.
enum EnergyTaskClass: String, Codable, Sendable {
    case native
    case shell
    case browser
    case vision
    case mixed
    case remote
    case unknown
}

// MARK: - Metadata values

/// JSON scalar for record metadata. Keeps the trace strictly typed while
/// allowing per-record-type fields without a schema struct per record.
enum EnergyValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var intValue: Int64? { if case .int(let i) = self { return i }; return nil }
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
}

extension EnergyValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                        ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - Records

/// One JSONL line. Envelope fields are fixed; `metadata` keys are flattened
/// into the same top-level JSON object on encode (and collected back on
/// decode), matching the analysis schema.
struct EnergyTraceRecord: Codable, Sendable {
    var schemaVersion: Int = EnergyTraceSchema.version
    var recordType: EnergyRecordType
    var wallTime: String
    var monotonicNs: UInt64
    var runID: UUID
    var spanID: UUID?
    var parentSpanID: UUID?
    var name: String?
    var metadata: [String: EnergyValue] = [:]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum Envelope: String, CaseIterable {
        case schemaVersion = "schema_version"
        case recordType = "record_type"
        case wallTime = "wall_time"
        case monotonicNs = "monotonic_ns"
        case runID = "run_id"
        case spanID = "span_id"
        case parentSpanID = "parent_span_id"
        case name = "name"
    }

    init(recordType: EnergyRecordType,
         wallTime: String,
         monotonicNs: UInt64,
         runID: UUID,
         spanID: UUID? = nil,
         parentSpanID: UUID? = nil,
         name: String? = nil,
         metadata: [String: EnergyValue] = [:]) {
        self.recordType = recordType
        self.wallTime = wallTime
        self.monotonicNs = monotonicNs
        self.runID = runID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.name = name
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        schemaVersion = try c.decode(Int.self, forKey: DynamicKey(Envelope.schemaVersion.rawValue))
        recordType = try c.decode(EnergyRecordType.self, forKey: DynamicKey(Envelope.recordType.rawValue))
        wallTime = try c.decode(String.self, forKey: DynamicKey(Envelope.wallTime.rawValue))
        monotonicNs = try c.decode(UInt64.self, forKey: DynamicKey(Envelope.monotonicNs.rawValue))
        runID = try c.decode(UUID.self, forKey: DynamicKey(Envelope.runID.rawValue))
        spanID = try c.decodeIfPresent(UUID.self, forKey: DynamicKey(Envelope.spanID.rawValue))
        parentSpanID = try c.decodeIfPresent(UUID.self, forKey: DynamicKey(Envelope.parentSpanID.rawValue))
        name = try c.decodeIfPresent(String.self, forKey: DynamicKey(Envelope.name.rawValue))
        let envelopeKeys = Set(Envelope.allCases.map(\.rawValue))
        var extra: [String: EnergyValue] = [:]
        for key in c.allKeys where !envelopeKeys.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(EnergyValue.self, forKey: key)
        }
        metadata = extra
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(schemaVersion, forKey: DynamicKey(Envelope.schemaVersion.rawValue))
        try c.encode(recordType, forKey: DynamicKey(Envelope.recordType.rawValue))
        try c.encode(wallTime, forKey: DynamicKey(Envelope.wallTime.rawValue))
        try c.encode(monotonicNs, forKey: DynamicKey(Envelope.monotonicNs.rawValue))
        try c.encode(runID, forKey: DynamicKey(Envelope.runID.rawValue))
        try c.encodeIfPresent(spanID, forKey: DynamicKey(Envelope.spanID.rawValue))
        try c.encodeIfPresent(parentSpanID, forKey: DynamicKey(Envelope.parentSpanID.rawValue))
        try c.encodeIfPresent(name, forKey: DynamicKey(Envelope.name.rawValue))
        let envelopeKeys = Set(Envelope.allCases.map(\.rawValue))
        for (key, value) in metadata where !envelopeKeys.contains(key) {
            try c.encode(value, forKey: DynamicKey(key))
        }
    }
}

// MARK: - Run / span descriptors

/// Researcher-supplied context for a controlled experiment run.
struct EnergyExperimentContext: Sendable {
    var taskClass: EnergyTaskClass
    var label: String?
    var implementationVariant: String?

    init(taskClass: EnergyTaskClass = .unknown,
         label: String? = nil,
         implementationVariant: String? = nil) {
        self.taskClass = taskClass
        self.label = label
        self.implementationVariant = implementationVariant
    }
}

struct EnergyRunOutcome: Sendable {
    var success: Bool
    var completionReason: String?
    var errorClass: String?

    static let success = EnergyRunOutcome(success: true, completionReason: "task_finished")
    static func failure(_ errorClass: String) -> EnergyRunOutcome {
        EnergyRunOutcome(success: false, completionReason: "error", errorClass: errorClass)
    }
    static let cancelled = EnergyRunOutcome(success: false, completionReason: "cancelled")
}

struct EnergySpanOutcome: Sendable {
    var success: Bool
    var errorClass: String?
    var cancelled: Bool
    var timedOut: Bool
    var retryIndex: Int

    init(success: Bool,
         errorClass: String? = nil,
         cancelled: Bool = false,
         timedOut: Bool = false,
         retryIndex: Int = 0) {
        self.success = success
        self.errorClass = errorClass
        self.cancelled = cancelled
        self.timedOut = timedOut
        self.retryIndex = retryIndex
    }

    static let success = EnergySpanOutcome(success: true)
    static let cancelled = EnergySpanOutcome(success: false, cancelled: true)
    static let timedOut = EnergySpanOutcome(success: false, timedOut: true)
    static func failure(_ errorClass: String) -> EnergySpanOutcome {
        EnergySpanOutcome(success: false, errorClass: errorClass)
    }
}

/// Handle returned by `EnergyTrace.beginSpan`. `active == false` means tracing
/// was disabled (or the run is unknown) and every operation on the token is a
/// no-op; call sites never need to branch on the tracing state themselves.
struct EnergySpanToken: Sendable {
    let runID: UUID
    let spanID: UUID
    let parentSpanID: UUID?
    let name: EnergySpanName
    let active: Bool

    static func inactive(name: EnergySpanName) -> EnergySpanToken {
        EnergySpanToken(runID: UUID(), spanID: UUID(), parentSpanID: nil, name: name, active: false)
    }
}

// MARK: - Clocks

enum EnergyClock {
    /// Nanoseconds on Darwin's CLOCK_MONOTONIC, which (unlike
    /// mach_absolute_time / CLOCK_UPTIME_RAW) continues to advance while the
    /// device is asleep — required because traced tasks may span screen-off
    /// and low-power periods.
    static func monotonicNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    // ISO8601DateFormatter is documented thread-safe; the unsafe opt-out is
    // for the Swift 6 language mode used by the test target.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func wallTimeString(_ date: Date = Date()) -> String {
        iso8601.string(from: date)
    }
}
