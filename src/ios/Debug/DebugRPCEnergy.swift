#if DEBUG
import Foundation

/// JSON-RPC handlers for the EnergyTrace research instrumentation.
///
/// Energy tracing is opt-in and disabled by default. The intended controlled-
/// experiment flow is:
///   1. `debug.energyTrace.start {task_class, label, variant}` — enables
///      tracing and opens a researcher-labeled run (one JSONL trace file);
///   2. drive the agent task on-device (its agent_task/model/shell/browser
///      spans attach to the run automatically);
///   3. `debug.energyTrace.stop {success, completion_reason}` — closes the
///      run and (by default) disables tracing again;
///   4. `debug.energyTrace.list` / `read` / `export` to pull the trace.
///
/// `enable` alone turns tracing on WITHOUT opening a run — every agent task
/// then auto-opens a task-scoped run (task_class=unknown), useful for
/// unlabeled exploration.
///
/// Traces contain operational metadata only (hashes, byte counts, durations,
/// hosts) — no prompts, outputs, URLs, or raw commands — but review before
/// sharing regardless.
enum DebugRPCEnergy {

    /// `debug.energyTrace.status {}`
    static func status() async -> [String: Any] {
        let config = EnergyTraceState.configuration
        let files = EnergyTraceStore.shared.listTraceFiles()
        let activeRun = await EnergyTrace.shared.activeRunID
        return [
            "enabled": EnergyTraceState.isEnabled,
            "active_run_id": activeRun?.uuidString ?? NSNull() as Any,
            "current_file": EnergyTraceStore.shared.currentFileURL?.lastPathComponent ?? NSNull() as Any,
            "sampling_interval_s": config.samplingIntervalSeconds,
            "store_command_preview": config.storeCommandPreview,
            "trace_file_count": files.count,
            "trace_total_bytes": files.reduce(Int64(0)) { $0 + $1.sizeBytes },
        ]
    }

    /// `debug.energyTrace.enable {}` / `debug.energyTrace.disable {}`
    static func setEnabled(_ on: Bool) async -> [String: Any] {
        if !on {
            await EnergyTraceRuntime.shared.stopExplicitRun(
                outcome: EnergyRunOutcome(success: false, completionReason: "tracing_disabled"))
        }
        EnergyTraceState.setEnabled(on)
        return ["ok": true, "enabled": EnergyTraceState.isEnabled]
    }

    /// `debug.energyTrace.start {task_class?, label?, variant?, sampling_interval_s?, store_command_preview?}`
    static func start(params: [String: Any]) async -> [String: Any] {
        var config = EnergyTraceState.configuration
        if let interval = numeric(params["sampling_interval_s"]) {
            config.samplingIntervalSeconds = interval
        }
        if let preview = params["store_command_preview"] as? Bool {
            config.storeCommandPreview = preview
        }
        EnergyTraceState.setConfiguration(config)
        EnergyTraceState.setEnabled(true)

        let taskClass = EnergyTaskClass(rawValue: params["task_class"] as? String ?? "unknown") ?? .unknown
        let context = EnergyExperimentContext(
            taskClass: taskClass,
            label: params["label"] as? String,
            implementationVariant: params["variant"] as? String)
        let runID = await EnergyTraceRuntime.shared.startExplicitRun(context: context)
        guard let runID else {
            return ["ok": false,
                    "error": "run not started (a run may already be active — stop it first)"]
        }
        return [
            "ok": true,
            "run_id": runID.uuidString,
            "file": EnergyTraceStore.shared.currentFileURL?.lastPathComponent ?? "",
            "sampling_interval_s": EnergyTraceState.configuration.samplingIntervalSeconds,
        ]
    }

    /// `debug.energyTrace.stop {success?, completion_reason?, keep_enabled?}`
    static func stop(params: [String: Any]) async -> [String: Any] {
        let outcome = EnergyRunOutcome(
            success: params["success"] as? Bool ?? true,
            completionReason: params["completion_reason"] as? String ?? "task_finished")
        await EnergyTraceRuntime.shared.stopExplicitRun(outcome: outcome)
        if (params["keep_enabled"] as? Bool) != true {
            EnergyTraceState.setEnabled(false)
        }
        return ["ok": true, "enabled": EnergyTraceState.isEnabled]
    }

    /// `debug.energyTrace.setSamplingInterval {seconds}`
    static func setSamplingInterval(params: [String: Any]) -> [String: Any] {
        guard let seconds = numeric(params["seconds"]) else {
            return ["ok": false, "error": "missing 'seconds' (allowed: 1, 2, 5, 10)"]
        }
        var config = EnergyTraceState.configuration
        config.samplingIntervalSeconds = seconds
        EnergyTraceState.setConfiguration(config)
        return ["ok": true,
                "sampling_interval_s": EnergyTraceState.configuration.samplingIntervalSeconds]
    }

    /// `debug.energyTrace.list {}`
    static func list() -> [String: Any] {
        let files = EnergyTraceStore.shared.listTraceFiles()
        let formatter = ISO8601DateFormatter()
        return [
            "files": files.map { info in
                [
                    "name": info.url.lastPathComponent,
                    "bytes": info.sizeBytes,
                    "modified": formatter.string(from: info.modified),
                ] as [String: Any]
            },
            "total_bytes": files.reduce(Int64(0)) { $0 + $1.sizeBytes },
        ]
    }

    /// `debug.energyTrace.read {file, offset?, length?}` — pull a trace file
    /// (or export ZIP) over the debug channel in base64 chunks.
    static func read(params: [String: Any]) throws -> [String: Any] {
        guard let name = params["file"] as? String else {
            throw DebugRPCErr(-32602, "missing 'file'")
        }
        guard let url = resolveTraceFile(named: name) else {
            throw DebugRPCErr(-32602, "unknown trace file '\(name)'")
        }
        let offset = (params["offset"] as? Int) ?? 0
        let length = min((params["length"] as? Int) ?? 1_048_576, 4 * 1_048_576)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DebugRPCErr(-32603, "cannot open \(name)")
        }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: UInt64(max(0, offset)))
        let data = (try? handle.read(upToCount: length)) ?? Data()
        return [
            "file": name,
            "offset": offset,
            "length": data.count,
            "total_bytes": total,
            "eof": UInt64(offset + data.count) >= total,
            "base64": data.base64EncodedString(),
        ]
    }

    /// `debug.energyTrace.export {file?}` — build a shareable ZIP
    /// (manifest.json + trace.jsonl + README.txt). Exports the named trace, or
    /// the most recent one. Returns the ZIP's name for `debug.energyTrace.read`.
    static func export(params: [String: Any]) async throws -> [String: Any] {
        let files = EnergyTraceStore.shared.listTraceFiles()
        let source: URL
        if let name = params["file"] as? String {
            guard let url = resolveTraceFile(named: name) else {
                throw DebugRPCErr(-32602, "unknown trace file '\(name)'")
            }
            source = url
        } else if let newest = files.last {
            source = newest.url
        } else {
            throw DebugRPCErr(-32602, "no trace files to export")
        }
        await EnergyTrace.shared.flush(closing: false)

        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("energy-export-\(UUID().uuidString)", isDirectory: true)
        let payloadDir = staging.appendingPathComponent(
            source.deletingPathExtension().lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try fm.copyItem(at: source, to: payloadDir.appendingPathComponent("trace.jsonl"))

        let manifest: [String: Any] = [
            "schema_version": EnergyTraceSchema.version,
            "trace_file": source.lastPathComponent,
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "device_model": EnergyResourceSampler.deviceModelIdentifier(),
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build_number": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                      options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: payloadDir.appendingPathComponent("manifest.json"))

        let readme = """
        OpenMinis energy trace export.

        trace.jsonl: one JSON object per line (schema_version \(EnergyTraceSchema.version)).
        Record types: run_start, run_end, span_start, span_end, event, resource_sample.
        Durations derive from monotonic_ns; wall_time is for aligning with
        Power Profiler / Instruments recordings.

        Contains operational metadata only (durations, byte counts, salted
        hashes, hosts) — no prompts, model outputs, URLs, or raw commands.
        Review before sharing.
        """
        try Data(readme.utf8).write(to: payloadDir.appendingPathComponent("README.txt"))

        // NSFileCoordinator's forUploading intent zips a directory without any
        // third-party dependency (the same mechanism share sheets use).
        let zipURL: URL = try await withCheckedThrowingContinuation { continuation in
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(
                readingItemAt: payloadDir,
                options: .forUploading,
                error: &coordinatorError
            ) { tempZip in
                do {
                    let dest = source.deletingLastPathComponent()
                        .appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".zip")
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: tempZip, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            if let coordinatorError {
                continuation.resume(throwing: coordinatorError)
            }
        }
        let size = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // Also copy into Documents/EnergyTraces/ so the export is reachable
        // from the Files app / Finder device browsing (UIFileSharingEnabled)
        // without downloading the whole app container.
        var documentsPath: String? = nil
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let exportDir = docs.appendingPathComponent("EnergyTraces", isDirectory: true)
            do {
                try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
                let dest = exportDir.appendingPathComponent(zipURL.lastPathComponent)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: zipURL, to: dest)
                documentsPath = "Documents/EnergyTraces/\(zipURL.lastPathComponent)"
            } catch {
                // Non-fatal: the primary copy next to the traces still exists.
            }
        }
        var result: [String: Any] = ["ok": true, "zip": zipURL.lastPathComponent, "bytes": size]
        if let documentsPath { result["documents_path"] = documentsPath }
        return result
    }

    /// `debug.energyTrace.delete {}` — delete all trace files and exports.
    static func delete() async -> [String: Any] {
        await EnergyTraceRuntime.shared.stopExplicitRun(
            outcome: EnergyRunOutcome(success: false, completionReason: "deleted"))
        EnergyTraceStore.shared.deleteAllTraces()
        // Also remove export ZIPs living alongside the traces.
        if let dir = traceDirectory() {
            let zips = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "zip" } ?? []
            for zip in zips { try? FileManager.default.removeItem(at: zip) }
        }
        return ["ok": true]
    }

    // MARK: Helpers

    private static func numeric(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    private static func traceDirectory() -> URL? {
        EnergyTraceStore.shared.listTraceFiles().first?.url.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("EnergyTraces", isDirectory: true)
    }

    /// Resolve a bare filename inside the trace directory, refusing anything
    /// path-like so the debug channel cannot read arbitrary files.
    private static func resolveTraceFile(named name: String) -> URL? {
        guard !name.contains("/"), !name.contains(".."),
              name.hasSuffix(".jsonl") || name.hasSuffix(".zip"),
              let dir = traceDirectory() else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif // DEBUG
