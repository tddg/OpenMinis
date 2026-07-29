import Foundation
import os

// MARK: - EnergyTrace coordinator
//
// Concurrency-safe coordinator for energy-trace runs. Every important run and
// phase produces two synchronized outputs:
//   1. an OSSignposter interval, for precise alignment with Power Profiler /
//      Instruments timelines;
//   2. a structured JSONL record (EnergyTraceStore), for offline analysis.
//
// Spans are identified by tokens, so concurrent shell commands, browser
// actions, and model requests can overlap freely; there is no global "current
// span". Spans still open when a run ends are closed as leaked (cancelled +
// leaked=true) so the trace never contains dangling intervals.
//
// Everything is gated on EnergyTraceState.isEnabled — the cheap static check —
// so instrumentation call sites cost a boolean read when tracing is off.

actor EnergyTrace {
    static let shared = EnergyTrace(store: .shared)

    private let store: EnergyTraceStore

    private struct SpanState {
        let token: EnergySpanToken
        let startNs: UInt64
        let signpostState: OSSignpostIntervalState
        let poiState: OSSignpostIntervalState
    }

    private struct RunState {
        let startNs: UInt64
        var openSpans: [UUID: SpanState] = [:]
        let signpostState: OSSignpostIntervalState
        let poiState: OSSignpostIntervalState
    }

    private var runs: [UUID: RunState] = [:]

    /// The most recently started, still-active run. Instrumentation attaches
    /// task spans to this when the researcher started a run explicitly.
    private(set) var activeRunID: UUID?

    init(store: EnergyTraceStore) {
        self.store = store
    }

    // MARK: Runs

    /// Starts a run and opens its trace file. Returns nil when tracing is
    /// disabled. `extraMetadata` carries device/app context captured by the
    /// caller (battery, thermal, network, versions...).
    func startRun(context: EnergyExperimentContext,
                  extraMetadata: [String: EnergyValue] = [:]) -> UUID? {
        guard EnergyTraceState.isEnabled else { return nil }
        // One run at a time: the store keeps a single open trace file, and the
        // experimental protocol measures one controlled task per trace anyway.
        guard runs.isEmpty else {
            NSLog("[EnergyTrace] [WARN] startRun ignored: a run is already active")
            return nil
        }
        let runID = UUID()
        do {
            try store.open(runID: runID)
        } catch {
            NSLog("[EnergyTrace] [ERROR] cannot open trace file: %@", String(describing: error))
            return nil
        }
        let startNs = EnergyClock.monotonicNs()
        let signposter = Self.signposter(for: .agentTask)
        let spid = signposter.makeSignpostID()
        let signpostState = signposter.beginInterval("energy_run", id: spid)
        let poiID = Self.poiSignposter.makeSignpostID()
        let poiState = Self.poiSignposter.beginInterval("span", id: poiID, "energy_run")
        runs[runID] = RunState(startNs: startNs, signpostState: signpostState, poiState: poiState)
        activeRunID = runID

        var meta = extraMetadata
        meta["task_class"] = .string(context.taskClass.rawValue)
        if let label = context.label { meta["experiment_label"] = .string(label) }
        if let variant = context.implementationVariant {
            meta["implementation_variant"] = .string(variant)
        }
        store.append(EnergyTraceRecord(recordType: .runStart,
                                       wallTime: EnergyClock.wallTimeString(),
                                       monotonicNs: startNs,
                                       runID: runID,
                                       metadata: meta))
        return runID
    }

    func endRun(_ runID: UUID,
                outcome: EnergyRunOutcome,
                extraMetadata: [String: EnergyValue] = [:]) {
        guard var run = runs.removeValue(forKey: runID) else { return }
        if activeRunID == runID { activeRunID = runs.keys.first }

        // Close leaked spans before the run record so span_end lines precede
        // run_end in the file.
        let leaked = run.openSpans.values.sorted { $0.startNs < $1.startNs }
        run.openSpans.removeAll()
        for span in leaked {
            finishSpan(span, runID: runID,
                       outcome: .cancelled,
                       extra: ["leaked": .bool(true)])
        }

        let endNs = EnergyClock.monotonicNs()
        var meta = extraMetadata
        meta["duration_ms"] = .double(Double(endNs - run.startNs) / 1_000_000)
        meta["success"] = .bool(outcome.success)
        meta["completion_reason"] = outcome.completionReason.map { .string($0) } ?? .null
        meta["error_class"] = outcome.errorClass.map { .string($0) } ?? .null
        if !leaked.isEmpty { meta["leaked_span_count"] = .int(Int64(leaked.count)) }
        store.append(EnergyTraceRecord(recordType: .runEnd,
                                       wallTime: EnergyClock.wallTimeString(),
                                       monotonicNs: endNs,
                                       runID: runID,
                                       metadata: meta))
        Self.signposter(for: .agentTask).endInterval("energy_run", run.signpostState)
        Self.poiSignposter.endInterval("span", run.poiState)
        store.closeCurrent()
    }

    // MARK: Spans

    func beginSpan(runID: UUID,
                   parent: EnergySpanToken? = nil,
                   name: EnergySpanName,
                   metadata: [String: EnergyValue] = [:]) -> EnergySpanToken {
        guard EnergyTraceState.isEnabled, runs[runID] != nil else {
            return .inactive(name: name)
        }
        let token = EnergySpanToken(runID: runID,
                                    spanID: UUID(),
                                    parentSpanID: (parent?.active == true) ? parent?.spanID : nil,
                                    name: name,
                                    active: true)
        let startNs = EnergyClock.monotonicNs()
        let signpostState = Self.beginSignpostInterval(name)
        let poiState = Self.beginPoiInterval(name)
        runs[runID]?.openSpans[token.spanID] = SpanState(token: token,
                                                        startNs: startNs,
                                                        signpostState: signpostState,
                                                        poiState: poiState)
        store.append(EnergyTraceRecord(recordType: .spanStart,
                                       wallTime: EnergyClock.wallTimeString(),
                                       monotonicNs: startNs,
                                       runID: runID,
                                       spanID: token.spanID,
                                       parentSpanID: token.parentSpanID,
                                       name: name.rawValue,
                                       metadata: metadata))
        return token
    }

    func endSpan(_ token: EnergySpanToken,
                 outcome: EnergySpanOutcome = .success,
                 metadata: [String: EnergyValue] = [:]) {
        guard token.active,
              let span = runs[token.runID]?.openSpans.removeValue(forKey: token.spanID)
        else { return }
        finishSpan(span, runID: token.runID, outcome: outcome, extra: metadata)
    }

    private func finishSpan(_ span: SpanState,
                            runID: UUID,
                            outcome: EnergySpanOutcome,
                            extra: [String: EnergyValue]) {
        let endNs = EnergyClock.monotonicNs()
        var meta = extra
        meta["duration_ms"] = .double(Double(endNs - span.startNs) / 1_000_000)
        meta["success"] = .bool(outcome.success)
        meta["error_class"] = outcome.errorClass.map { .string($0) } ?? .null
        meta["cancelled"] = .bool(outcome.cancelled)
        meta["timed_out"] = .bool(outcome.timedOut)
        meta["retry_index"] = .int(Int64(outcome.retryIndex))
        store.append(EnergyTraceRecord(recordType: .spanEnd,
                                       wallTime: EnergyClock.wallTimeString(),
                                       monotonicNs: endNs,
                                       runID: runID,
                                       spanID: span.token.spanID,
                                       parentSpanID: span.token.parentSpanID,
                                       name: span.token.name.rawValue,
                                       metadata: meta))
        Self.endSignpostInterval(span.token.name, span.signpostState)
        Self.poiSignposter.endInterval("span", span.poiState)
    }

    // MARK: Events

    func event(runID: UUID,
               span: EnergySpanToken? = nil,
               name: String,
               metadata: [String: EnergyValue] = [:]) {
        guard EnergyTraceState.isEnabled, runs[runID] != nil else { return }
        var meta = metadata
        meta["event"] = .string(name)
        store.append(EnergyTraceRecord(recordType: .event,
                                       wallTime: EnergyClock.wallTimeString(),
                                       monotonicNs: EnergyClock.monotonicNs(),
                                       runID: runID,
                                       spanID: (span?.active == true) ? span?.spanID : nil,
                                       name: name,
                                       metadata: meta))
        Self.signposter(for: .lifecycle).emitEvent("event", "\(name, privacy: .public)")
    }

    func recordResourceSample(runID: UUID, metadata: [String: EnergyValue]) {
        guard EnergyTraceState.isEnabled, runs[runID] != nil else { return }
        store.append(EnergyTraceRecord(recordType: .resourceSample,
                                       wallTime: EnergyClock.wallTimeString(),
                                       monotonicNs: EnergyClock.monotonicNs(),
                                       runID: runID,
                                       metadata: metadata))
    }

    /// Flushes buffered records and, when `closing`, closes the file — used on
    /// app lifecycle transitions so a kill cannot lose the tail of a trace.
    func flush(closing: Bool = false) {
        if closing {
            store.closeCurrent()
        } else {
            store.flush()
        }
    }

    // MARK: Signposts

    enum SignpostCategory: String {
        case agentTask = "AgentTask"
        case model = "Model"
        case tool = "Tool"
        case shell = "Shell"
        case browser = "Browser"
        case nativeOffload = "NativeOffload"
        case persistence = "Persistence"
        case lifecycle = "Lifecycle"
    }

    static let signpostSubsystem = "com.openminis.app.energytrace"

    /// Every interval is mirrored to the canonical "PointsOfInterest" category:
    /// Instruments' Points of Interest instrument records it reliably in every
    /// template/recording mode, whereas custom categories were observed to be
    /// dropped by deferred-mode device recordings (xctrace Power Profiler
    /// pilot, 2026-07-28). The per-category signposters remain the structured
    /// lanes when they are captured.
    private static let poiSignposter = OSSignposter(subsystem: signpostSubsystem,
                                                    category: "PointsOfInterest")

    private static func beginPoiInterval(_ name: EnergySpanName) -> OSSignpostIntervalState {
        let id = poiSignposter.makeSignpostID()
        return poiSignposter.beginInterval("span", id: id, "\(name.rawValue, privacy: .public)")
    }

    private static let agentTaskSignposter = OSSignposter(subsystem: signpostSubsystem, category: SignpostCategory.agentTask.rawValue)
    private static let modelSignposter = OSSignposter(subsystem: signpostSubsystem, category: SignpostCategory.model.rawValue)
    private static let toolSignposter = OSSignposter(subsystem: signpostSubsystem, category: SignpostCategory.tool.rawValue)
    private static let shellSignposter = OSSignposter(subsystem: signpostSubsystem, category: SignpostCategory.shell.rawValue)
    private static let browserSignposter = OSSignposter(subsystem: signpostSubsystem, category: SignpostCategory.browser.rawValue)
    private static let nativeOffloadSignposter = OSSignposter(subsystem: signpostSubsystem, category: SignpostCategory.nativeOffload.rawValue)
    private static let persistenceSignposter = OSSignposter(subsystem: signpostSubsystem, category: SignpostCategory.persistence.rawValue)
    private static let lifecycleSignposter = OSSignposter(subsystem: signpostSubsystem, category: SignpostCategory.lifecycle.rawValue)

    static func signposter(for category: SignpostCategory) -> OSSignposter {
        switch category {
        case .agentTask: return agentTaskSignposter
        case .model: return modelSignposter
        case .tool: return toolSignposter
        case .shell: return shellSignposter
        case .browser: return browserSignposter
        case .nativeOffload: return nativeOffloadSignposter
        case .persistence: return persistenceSignposter
        case .lifecycle: return lifecycleSignposter
        }
    }

    static func category(for name: EnergySpanName) -> SignpostCategory {
        switch name {
        case .agentTask: return .agentTask
        case .modelRequest, .modelTTFT, .modelStream, .modelPostprocess: return .model
        case .toolDispatch, .remoteRPC: return .tool
        case .shellExecute, .shellOutputSanitize: return .shell
        case .browserAction, .browserNavigation, .browserJavascript, .browserSnapshot: return .browser
        case .nativeOffload: return .nativeOffload
        case .fileRead, .fileWrite, .statePersist: return .persistence
        case .uiRenderUpdate, .backgroundWait: return .lifecycle
        }
    }

    // OSSignposter interval names must be StaticString, hence the switches.
    private static func beginSignpostInterval(_ name: EnergySpanName) -> OSSignpostIntervalState {
        let sp = signposter(for: category(for: name))
        let id = sp.makeSignpostID()
        switch name {
        case .agentTask: return sp.beginInterval("agent_task", id: id)
        case .modelRequest: return sp.beginInterval("model_request", id: id)
        case .modelTTFT: return sp.beginInterval("model_time_to_first_token", id: id)
        case .modelStream: return sp.beginInterval("model_stream", id: id)
        case .modelPostprocess: return sp.beginInterval("model_postprocess", id: id)
        case .toolDispatch: return sp.beginInterval("tool_dispatch", id: id)
        case .shellExecute: return sp.beginInterval("shell_execute", id: id)
        case .shellOutputSanitize: return sp.beginInterval("shell_output_sanitize", id: id)
        case .browserAction: return sp.beginInterval("browser_action", id: id)
        case .browserNavigation: return sp.beginInterval("browser_navigation", id: id)
        case .browserJavascript: return sp.beginInterval("browser_javascript", id: id)
        case .browserSnapshot: return sp.beginInterval("browser_snapshot", id: id)
        case .nativeOffload: return sp.beginInterval("native_offload", id: id)
        case .fileRead: return sp.beginInterval("file_read", id: id)
        case .fileWrite: return sp.beginInterval("file_write", id: id)
        case .statePersist: return sp.beginInterval("state_persist", id: id)
        case .uiRenderUpdate: return sp.beginInterval("ui_render_update", id: id)
        case .backgroundWait: return sp.beginInterval("background_wait", id: id)
        case .remoteRPC: return sp.beginInterval("remote_rpc", id: id)
        }
    }

    private static func endSignpostInterval(_ name: EnergySpanName, _ state: OSSignpostIntervalState) {
        let sp = signposter(for: category(for: name))
        switch name {
        case .agentTask: sp.endInterval("agent_task", state)
        case .modelRequest: sp.endInterval("model_request", state)
        case .modelTTFT: sp.endInterval("model_time_to_first_token", state)
        case .modelStream: sp.endInterval("model_stream", state)
        case .modelPostprocess: sp.endInterval("model_postprocess", state)
        case .toolDispatch: sp.endInterval("tool_dispatch", state)
        case .shellExecute: sp.endInterval("shell_execute", state)
        case .shellOutputSanitize: sp.endInterval("shell_output_sanitize", state)
        case .browserAction: sp.endInterval("browser_action", state)
        case .browserNavigation: sp.endInterval("browser_navigation", state)
        case .browserJavascript: sp.endInterval("browser_javascript", state)
        case .browserSnapshot: sp.endInterval("browser_snapshot", state)
        case .nativeOffload: sp.endInterval("native_offload", state)
        case .fileRead: sp.endInterval("file_read", state)
        case .fileWrite: sp.endInterval("file_write", state)
        case .statePersist: sp.endInterval("state_persist", state)
        case .uiRenderUpdate: sp.endInterval("ui_render_update", state)
        case .backgroundWait: sp.endInterval("background_wait", state)
        case .remoteRPC: sp.endInterval("remote_rpc", state)
        }
    }
}

// MARK: - Guaranteed-closure convenience

/// Runs `operation` inside a span on `trace`, guaranteeing the span is closed
/// on normal return, thrown error, and task cancellation. When tracing is
/// disabled this is a single boolean check plus the operation itself.
func withEnergySpan<T>(trace: EnergyTrace = .shared,
                       runID: UUID,
                       parent: EnergySpanToken? = nil,
                       name: EnergySpanName,
                       metadata: [String: EnergyValue] = [:],
                       operation: () async throws -> T) async rethrows -> T {
    guard EnergyTraceState.isEnabled else {
        return try await operation()
    }
    let token = await trace.beginSpan(runID: runID, parent: parent,
                                      name: name, metadata: metadata)
    do {
        let result = try await operation()
        await trace.endSpan(token, outcome: .success)
        return result
    } catch {
        let outcome: EnergySpanOutcome = (error is CancellationError)
            ? .cancelled
            : .failure(String(describing: type(of: error)))
        await trace.endSpan(token, outcome: outcome)
        throw error
    }
}
