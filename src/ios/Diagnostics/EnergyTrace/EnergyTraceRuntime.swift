#if canImport(UIKit)
import Foundation
import UIKit

// MARK: - Runtime integration
//
// iOS-side glue between the platform-neutral EnergyTrace core and the app:
//   - opens/closes the top-level agent_task span from AIChatViewModel's
//     isProcessing transitions (which bracket every agent-loop entry point:
//     send, retry, resume, rerun, queued-prompt drain, compaction);
//   - attaches the task to a researcher-started run when one is active,
//     otherwise auto-starts a run scoped to the task;
//   - runs the low-frequency resource sampler only while a run is active;
//   - emits app/power/thermal lifecycle events during runs.
//
// All operations funnel through a serial continuation chain so begin/end
// ordering is preserved across the MainActor → EnergyTrace actor hops.

@MainActor
final class EnergyTraceRuntime {
    static let shared = EnergyTraceRuntime()

    private struct SessionTask {
        let runID: UUID
        let token: EnergySpanToken
        /// true when this task auto-started its run (no researcher run was
        /// active), so ending the task also ends the run.
        let autoStartedRun: Bool
    }

    private struct ModelPhase {
        var request: EnergySpanToken
        var ttft: EnergySpanToken?
        var stream: EnergySpanToken?
    }

    private var sessionTasks: [String: SessionTask] = [:]
    private var modelPhases: [String: ModelPhase] = [:]
    private var samplerTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var batteryMonitoringWasEnabled: Bool?
    private var chain: Task<Void, Never>?
    private lazy var hasher = EnergyTraceHasher.installHasher()

    private init() {}

    /// Serializes async operations in submission order (submissions happen on
    /// the main actor, so order is deterministic).
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task { @MainActor in
            await prev?.value
            await op()
        }
    }

    // MARK: Agent task lifecycle (called from AIChatViewModel.isProcessing)

    func agentTaskStarted(sessionId: String?, trigger: String,
                          modelId: String?, provider: String?) {
        guard EnergyTraceState.isEnabled else { return }
        let sid = sessionId ?? "no-session"
        // Capture UI-context metadata synchronously at the transition.
        let deviceMeta = EnergyResourceSampler.deviceContextMetadata()
        var spanMeta: [String: EnergyValue] = [
            "trigger": .string(trigger),
            "session_id_hash": .string(String(hasher.hash(sid).prefix(16))),
        ]
        if let modelId { spanMeta["model_name"] = .string(modelId) }
        if let provider { spanMeta["model_provider"] = .string(provider) }

        enqueue { [weak self] in
            guard let self, self.sessionTasks[sid] == nil else { return }
            let autoStarted: Bool
            var runID = await EnergyTrace.shared.activeRunID
            if runID != nil {
                autoStarted = false
            } else {
                var runMeta = deviceMeta
                runMeta["run_origin"] = .string("auto_agent_task")
                runID = await EnergyTrace.shared.startRun(
                    context: EnergyExperimentContext(taskClass: .unknown),
                    extraMetadata: runMeta)
                autoStarted = true
            }
            guard let runID else { return }
            let token = await EnergyTrace.shared.beginSpan(
                runID: runID, name: .agentTask, metadata: spanMeta)
            self.sessionTasks[sid] = SessionTask(runID: runID, token: token,
                                                 autoStartedRun: autoStarted)
            self.beginRunSideEffectsIfNeeded()
        }
    }

    func agentTaskEnded(sessionId: String?, cancelled: Bool, failed: Bool) {
        guard EnergyTraceState.isEnabled else { return }
        let sid = sessionId ?? "no-session"

        enqueue { [weak self] in
            guard let self, let st = self.sessionTasks.removeValue(forKey: sid) else { return }
            // A model iteration that threw leaves its phase spans open; close
            // them before the parent task so the trace nests cleanly.
            await self.closeModelPhase(sessionId: sid,
                                       outcome: cancelled ? .cancelled : .failure("agent_task_ended"),
                                       metadata: [:])
            let outcome: EnergySpanOutcome
            if cancelled {
                outcome = .cancelled
            } else if failed {
                outcome = .failure("agent_task_error")
            } else {
                outcome = .success
            }
            await EnergyTrace.shared.endSpan(st.token, outcome: outcome)
            if st.autoStartedRun {
                let runOutcome: EnergyRunOutcome = cancelled ? .cancelled
                    : (failed ? .failure("agent_task_error") : .success)
                await EnergyTrace.shared.endRun(st.runID, outcome: runOutcome)
            }
            await self.endRunSideEffectsIfIdle()
        }
    }

    /// Current run/parent-token for nested instrumentation (shell, browser,
    /// model spans). nil when no traced agent task is active for the session.
    func taskContext(sessionId: String?) -> (runID: UUID, parent: EnergySpanToken)? {
        guard EnergyTraceState.isEnabled else { return nil }
        let sid = sessionId ?? "no-session"
        guard let st = sessionTasks[sid] else { return nil }
        return (st.runID, st.token)
    }

    // MARK: Model request phases (called from runAgentLoop / processStreamEvents)
    //
    // One model_request span per agent-loop iteration (covering the request
    // plus any in-iteration auto-retries), with model_time_to_first_token and
    // model_stream child spans split at the first streamed content event.

    func modelRequestBegan(sessionId: String?, provider: String,
                           modelId: String, requestIndex: Int) {
        guard EnergyTraceState.isEnabled else { return }
        let sid = sessionId ?? "no-session"
        enqueue { [weak self] in
            guard let self, let st = self.sessionTasks[sid] else { return }
            // A dangling phase from a thrown iteration: close it first.
            await self.closeModelPhase(sessionId: sid,
                                       outcome: .failure("superseded"),
                                       metadata: [:])
            let request = await EnergyTrace.shared.beginSpan(
                runID: st.runID, parent: st.token, name: .modelRequest,
                metadata: [
                    "provider": .string(provider),
                    "model": .string(modelId),
                    "request_index": .int(Int64(requestIndex)),
                ])
            let ttft = await EnergyTrace.shared.beginSpan(
                runID: st.runID, parent: request, name: .modelTTFT)
            self.modelPhases[sid] = ModelPhase(request: request, ttft: ttft)
        }
    }

    /// First streamed content event: ends the TTFT span, starts model_stream.
    /// Safe to call on every content-block start — only the first has effect.
    func modelFirstToken(sessionId: String?) {
        guard EnergyTraceState.isEnabled else { return }
        let sid = sessionId ?? "no-session"
        enqueue { [weak self] in
            guard let self, var phase = self.modelPhases[sid],
                  let ttft = phase.ttft else { return }
            await EnergyTrace.shared.endSpan(ttft, outcome: .success)
            phase.ttft = nil
            phase.stream = await EnergyTrace.shared.beginSpan(
                runID: phase.request.runID, parent: phase.request, name: .modelStream)
            self.modelPhases[sid] = phase
        }
    }

    func modelRequestEnded(sessionId: String?, success: Bool,
                           metadata: [String: EnergyValue]) {
        guard EnergyTraceState.isEnabled else { return }
        let sid = sessionId ?? "no-session"
        enqueue { [weak self] in
            await self?.closeModelPhase(
                sessionId: sid,
                outcome: success ? .success : .failure("model_request_error"),
                metadata: metadata)
        }
    }

    /// Must run inside the serial chain (or from an op already on it).
    private func closeModelPhase(sessionId sid: String,
                                 outcome: EnergySpanOutcome,
                                 metadata: [String: EnergyValue]) async {
        guard let phase = modelPhases.removeValue(forKey: sid) else { return }
        if let ttft = phase.ttft {
            // No content ever arrived; the TTFT span shares the request outcome.
            await EnergyTrace.shared.endSpan(ttft, outcome: outcome)
        }
        if let stream = phase.stream {
            await EnergyTrace.shared.endSpan(stream, outcome: outcome)
        }
        await EnergyTrace.shared.endSpan(phase.request, outcome: outcome, metadata: metadata)
    }

    // MARK: Explicit (researcher-driven) runs — used by debug controls

    func startExplicitRun(context: EnergyExperimentContext) async -> UUID? {
        guard EnergyTraceState.isEnabled else { return nil }
        let meta = EnergyResourceSampler.deviceContextMetadata()
        var runMeta = meta
        runMeta["run_origin"] = .string("explicit")
        let runID = await EnergyTrace.shared.startRun(context: context, extraMetadata: runMeta)
        if runID != nil { beginRunSideEffectsIfNeeded() }
        return runID
    }

    func stopExplicitRun(outcome: EnergyRunOutcome) async {
        if let runID = await EnergyTrace.shared.activeRunID {
            let meta = EnergyResourceSampler.deviceContextMetadata()
            await EnergyTrace.shared.endRun(runID, outcome: outcome, extraMetadata: meta)
        }
        await endRunSideEffectsIfIdle()
    }

    // MARK: Run side effects (sampler + lifecycle observers + battery monitor)

    private func beginRunSideEffectsIfNeeded() {
        if batteryMonitoringWasEnabled == nil {
            batteryMonitoringWasEnabled = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        startSamplerIfNeeded()
        registerLifecycleObserversIfNeeded()
    }

    private func endRunSideEffectsIfIdle() async {
        guard sessionTasks.isEmpty else { return }
        guard await EnergyTrace.shared.activeRunID == nil else { return }
        samplerTask?.cancel()
        samplerTask = nil
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        if let previous = batteryMonitoringWasEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = previous
            batteryMonitoringWasEnabled = nil
        }
        await EnergyTrace.shared.flush(closing: false)
    }

    private func startSamplerIfNeeded() {
        guard samplerTask == nil else { return }
        samplerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = max(1, EnergyTraceState.configuration.samplingIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, self != nil else { break }
                guard let runID = await EnergyTrace.shared.activeRunID else { continue }
                let meta = EnergyResourceSampler.sampleMetadata()
                await EnergyTrace.shared.recordResourceSample(runID: runID, metadata: meta)
            }
        }
    }

    private func registerLifecycleObserversIfNeeded() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let pairs: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "app_did_become_active"),
            (UIApplication.willResignActiveNotification, "app_will_resign_active"),
            (UIApplication.didEnterBackgroundNotification, "app_did_enter_background"),
            (UIApplication.willEnterForegroundNotification, "app_will_enter_foreground"),
            (.NSProcessInfoPowerStateDidChange, "low_power_mode_changed"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal_state_changed"),
            (UIDevice.batteryStateDidChangeNotification, "battery_state_changed"),
        ]
        for (notification, eventName) in pairs {
            let observer = center.addObserver(forName: notification, object: nil,
                                              queue: .main) { _ in
                Task { @MainActor in
                    EnergyTraceRuntime.shared.emitLifecycleEvent(eventName)
                }
            }
            lifecycleObservers.append(observer)
        }
    }

    private func emitLifecycleEvent(_ name: String) {
        guard EnergyTraceState.isEnabled else { return }
        var meta: [String: EnergyValue] = [
            "app_state": .string(EnergyResourceSampler.appStateName()),
            "thermal_state": .string(EnergyResourceSampler.thermalStateName()),
            "low_power_mode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "battery_state": .string(EnergyResourceSampler.batteryStateName()),
            "screen_brightness": .double(Double(UIScreen.main.brightness)),
        ]
        meta["battery_level"] = EnergyResourceSampler.batteryLevel()
        Task {
            guard let runID = await EnergyTrace.shared.activeRunID else { return }
            await EnergyTrace.shared.event(runID: runID, name: name, metadata: meta)
        }
    }
}
#endif
