import XCTest

final class EnergyTraceCoreTests: XCTestCase {

    private var tempDir: URL!
    private var savedEnabled = false
    private var savedConfig = EnergyTraceConfiguration()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnergyTraceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedEnabled = EnergyTraceState.isEnabled
        savedConfig = EnergyTraceState.configuration
        EnergyTraceState.setEnabled(false)
        EnergyTraceState.setConfiguration(EnergyTraceConfiguration())
    }

    override func tearDownWithError() throws {
        EnergyTraceState.setEnabled(savedEnabled)
        EnergyTraceState.setConfiguration(savedConfig)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> EnergyTraceStore {
        EnergyTraceStore(directory: tempDir)
    }

    private func readRecords(_ url: URL, file: StaticString = #filePath,
                             line: UInt = #line) throws -> [EnergyTraceRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { lineText in
            try? decoder.decode(EnergyTraceRecord.self, from: Data(lineText.utf8))
        }
    }

    // MARK: - Schema

    func testRecordRoundtripFlattensMetadata() throws {
        let record = EnergyTraceRecord(
            recordType: .spanEnd,
            wallTime: EnergyClock.wallTimeString(),
            monotonicNs: EnergyClock.monotonicNs(),
            runID: UUID(),
            spanID: UUID(),
            parentSpanID: UUID(),
            name: EnergySpanName.shellExecute.rawValue,
            metadata: [
                "duration_ms": .double(12.5),
                "exit_code": .int(0),
                "success": .bool(true),
                "error_class": .null,
                "command_hash": .string("abc123"),
            ]
        )
        let data = try JSONEncoder().encode(record)

        // Metadata keys must appear at the JSON top level, not nested.
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["record_type"] as? String, "span_end")
        XCTAssertEqual(obj["exit_code"] as? Int, 0)
        XCTAssertEqual(obj["duration_ms"] as? Double, 12.5)
        XCTAssertNil(obj["metadata"])

        let decoded = try JSONDecoder().decode(EnergyTraceRecord.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, EnergyTraceSchema.version)
        XCTAssertEqual(decoded.recordType, .spanEnd)
        XCTAssertEqual(decoded.runID, record.runID)
        XCTAssertEqual(decoded.spanID, record.spanID)
        XCTAssertEqual(decoded.parentSpanID, record.parentSpanID)
        XCTAssertEqual(decoded.name, "shell_execute")
        XCTAssertEqual(decoded.metadata, record.metadata)
    }

    func testEnergyValueScalarRoundtrip() throws {
        let values: [String: EnergyValue] = [
            "s": .string("hello"), "i": .int(-42), "d": .double(3.25),
            "b": .bool(false), "n": .null,
        ]
        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([String: EnergyValue].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    // MARK: - Store

    func testStoreBuffersUntilFlush() throws {
        let store = makeStore()
        let runID = UUID()
        let url = try store.open(runID: runID)

        store.append(EnergyTraceRecord(recordType: .event,
                                       wallTime: EnergyClock.wallTimeString(),
                                       monotonicNs: EnergyClock.monotonicNs(),
                                       runID: runID, name: "e1"))
        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertEqual(sizeBefore, 0, "record should be buffered, not written synchronously")

        store.flush()
        let records = try readRecords(url)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].name, "e1")
        store.closeCurrent()
    }

    func testStoreAutoFlushAtThreshold() throws {
        var config = EnergyTraceConfiguration()
        config.maxBufferedRecords = 3
        config.flushIntervalSeconds = 3600
        EnergyTraceState.setConfiguration(config)

        let store = makeStore()
        let runID = UUID()
        let url = try store.open(runID: runID)
        for i in 0..<3 {
            store.append(EnergyTraceRecord(recordType: .event,
                                           wallTime: EnergyClock.wallTimeString(),
                                           monotonicNs: EnergyClock.monotonicNs(),
                                           runID: runID, name: "e\(i)"))
        }
        let records = try readRecords(url)
        XCTAssertEqual(records.count, 3, "hitting maxBufferedRecords must flush without explicit call")
        store.closeCurrent()
    }

    func testAppendAfterCloseIsDropped() throws {
        let store = makeStore()
        let runID = UUID()
        let url = try store.open(runID: runID)
        store.closeCurrent()
        store.append(EnergyTraceRecord(recordType: .event,
                                       wallTime: EnergyClock.wallTimeString(),
                                       monotonicNs: EnergyClock.monotonicNs(),
                                       runID: runID, name: "late"))
        store.flush()
        XCTAssertEqual(try readRecords(url).count, 0)
    }

    func testPruningOldestFirstByCount() throws {
        var config = EnergyTraceConfiguration()
        config.maxTraceFiles = 2
        EnergyTraceState.setConfiguration(config)
        let store = makeStore()

        for i in 0..<4 {
            let url = tempDir.appendingPathComponent("energy-trace-0000000\(i)-aaaa.jsonl")
            try Data("{}\n".utf8).write(to: url)
            let date = Date(timeIntervalSince1970: 1_000_000 + Double(i) * 60)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        store.pruneIfNeeded()
        let remaining = store.listTraceFiles().map { $0.url.lastPathComponent }.sorted()
        XCTAssertEqual(remaining, ["energy-trace-00000002-aaaa.jsonl",
                                   "energy-trace-00000003-aaaa.jsonl"])
    }

    func testPruningByTotalBytes() throws {
        var config = EnergyTraceConfiguration()
        config.maxTotalTraceBytes = 1024
        EnergyTraceState.setConfiguration(config)
        let store = makeStore()

        for i in 0..<3 {
            let url = tempDir.appendingPathComponent("energy-trace-byte\(i)-aaaa.jsonl")
            try Data(repeating: 0x7B, count: 600).write(to: url)
            let date = Date(timeIntervalSince1970: 2_000_000 + Double(i) * 60)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        store.pruneIfNeeded()
        XCTAssertEqual(store.listTraceFiles().count, 1)
        XCTAssertEqual(store.listTraceFiles().first?.url.lastPathComponent,
                       "energy-trace-byte2-aaaa.jsonl")
    }

    // MARK: - Coordinator

    func testDisabledModeProducesNoFilesAndInactiveTokens() async throws {
        EnergyTraceState.setEnabled(false)
        let trace = EnergyTrace(store: makeStore())
        let runID = await trace.startRun(context: EnergyExperimentContext())
        XCTAssertNil(runID)

        let token = await trace.beginSpan(runID: UUID(), name: .shellExecute)
        XCTAssertFalse(token.active)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contents.isEmpty, "disabled tracing must write nothing")
    }

    func testRunAndNestedSpansProduceOrderedRecords() async throws {
        EnergyTraceState.setEnabled(true)
        let store = makeStore()
        let trace = EnergyTrace(store: store)

        let maybeRunID = await trace.startRun(
            context: EnergyExperimentContext(taskClass: .shell, label: "unit_test",
                                             implementationVariant: "baseline"))
        let runID = try XCTUnwrap(maybeRunID)
        let url = try XCTUnwrap(store.currentFileURL)

        let task = await trace.beginSpan(runID: runID, name: .agentTask)
        let shell = await trace.beginSpan(runID: runID, parent: task, name: .shellExecute,
                                          metadata: ["command_hash": .string("deadbeef")])
        await trace.endSpan(shell, outcome: .success, metadata: ["exit_code": .int(0)])
        await trace.endSpan(task, outcome: .success)
        await trace.endRun(runID, outcome: .success)

        let records = try readRecords(url)
        XCTAssertEqual(records.map(\.recordType),
                       [.runStart, .spanStart, .spanStart, .spanEnd, .spanEnd, .runEnd])

        let runStart = records[0]
        XCTAssertEqual(runStart.metadata["task_class"], .string("shell"))
        XCTAssertEqual(runStart.metadata["experiment_label"], .string("unit_test"))

        let shellStart = records[2]
        XCTAssertEqual(shellStart.name, "shell_execute")
        XCTAssertEqual(shellStart.parentSpanID, task.spanID)

        let shellEnd = records[3]
        XCTAssertEqual(shellEnd.spanID, shell.spanID)
        XCTAssertEqual(shellEnd.metadata["exit_code"], .int(0))
        XCTAssertEqual(shellEnd.metadata["success"], .bool(true))
        XCTAssertNotNil(shellEnd.metadata["duration_ms"]?.doubleValue)

        let runEnd = records[5]
        XCTAssertEqual(runEnd.metadata["success"], .bool(true))
        XCTAssertNotNil(runEnd.metadata["duration_ms"]?.doubleValue)

        // Monotonic timestamps never decrease in this single-actor sequence.
        let times = records.map(\.monotonicNs)
        XCTAssertEqual(times, times.sorted())
    }

    func testLeakedSpanClosedAtEndRun() async throws {
        EnergyTraceState.setEnabled(true)
        let store = makeStore()
        let trace = EnergyTrace(store: store)
        let maybeRunID = await trace.startRun(context: EnergyExperimentContext())
        let runID = try XCTUnwrap(maybeRunID)
        let url = try XCTUnwrap(store.currentFileURL)

        _ = await trace.beginSpan(runID: runID, name: .browserAction)
        await trace.endRun(runID, outcome: .cancelled)

        let records = try readRecords(url)
        let spanEnd = try XCTUnwrap(records.first { $0.recordType == .spanEnd })
        XCTAssertEqual(spanEnd.metadata["cancelled"], .bool(true))
        XCTAssertEqual(spanEnd.metadata["leaked"], .bool(true))
        let runEnd = try XCTUnwrap(records.last)
        XCTAssertEqual(runEnd.recordType, .runEnd)
        XCTAssertEqual(runEnd.metadata["leaked_span_count"], .int(1))
        // Leaked span_end must precede run_end.
        XCTAssertLessThan(records.firstIndex { $0.recordType == .spanEnd }!,
                          records.firstIndex { $0.recordType == .runEnd }!)
    }

    func testSecondConcurrentRunIsRefused() async throws {
        EnergyTraceState.setEnabled(true)
        let trace = EnergyTrace(store: makeStore())
        let first = await trace.startRun(context: EnergyExperimentContext())
        XCTAssertNotNil(first)
        let second = await trace.startRun(context: EnergyExperimentContext())
        XCTAssertNil(second)
        await trace.endRun(first!, outcome: .success)
    }

    func testWithEnergySpanClosesOnThrow() async throws {
        EnergyTraceState.setEnabled(true)
        let store = makeStore()
        let trace = EnergyTrace(store: store)
        let maybeRunID = await trace.startRun(context: EnergyExperimentContext())
        let runID = try XCTUnwrap(maybeRunID)
        let url = try XCTUnwrap(store.currentFileURL)

        struct TestError: Error {}
        do {
            _ = try await withEnergySpan(trace: trace, runID: runID,
                                         name: .modelRequest) { () -> Int in
                throw TestError()
            }
            XCTFail("expected throw")
        } catch {}
        await trace.endRun(runID, outcome: .failure("TestError"))

        let records = try readRecords(url)
        let spanEnd = try XCTUnwrap(records.first {
            $0.recordType == .spanEnd && $0.name == "model_request"
        })
        XCTAssertEqual(spanEnd.metadata["success"], .bool(false))
        XCTAssertEqual(spanEnd.metadata["error_class"], .string("TestError"))
        XCTAssertNil(spanEnd.metadata["leaked"], "span must close via throw path, not leak closure")
    }

    func testWithEnergySpanClosesOnCancellation() async throws {
        EnergyTraceState.setEnabled(true)
        let store = makeStore()
        let trace = EnergyTrace(store: store)
        let maybeRunID = await trace.startRun(context: EnergyExperimentContext())
        let runID = try XCTUnwrap(maybeRunID)
        let url = try XCTUnwrap(store.currentFileURL)

        let started = expectation(description: "span started")
        let task = Task {
            try await withEnergySpan(trace: trace, runID: runID, name: .shellExecute) {
                started.fulfill()
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        _ = await task.result
        await trace.endRun(runID, outcome: .cancelled)

        let records = try readRecords(url)
        let spanEnd = try XCTUnwrap(records.first {
            $0.recordType == .spanEnd && $0.name == "shell_execute"
        })
        XCTAssertEqual(spanEnd.metadata["cancelled"], .bool(true))
        XCTAssertNil(spanEnd.metadata["leaked"])
    }

    func testConcurrentOverlappingSpans() async throws {
        EnergyTraceState.setEnabled(true)
        let store = makeStore()
        let trace = EnergyTrace(store: store)
        let maybeRunID = await trace.startRun(context: EnergyExperimentContext())
        let runID = try XCTUnwrap(maybeRunID)
        let url = try XCTUnwrap(store.currentFileURL)

        let parent = await trace.beginSpan(runID: runID, name: .agentTask)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let name: EnergySpanName = i.isMultiple(of: 2) ? .shellExecute : .browserAction
                    let token = await trace.beginSpan(runID: runID, parent: parent, name: name)
                    await Task.yield()
                    await trace.endSpan(token, outcome: .success,
                                        metadata: ["i": .int(Int64(i))])
                }
            }
        }
        await trace.endSpan(parent)
        await trace.endRun(runID, outcome: .success)

        let records = try readRecords(url)
        let starts = records.filter { $0.recordType == .spanStart && $0.name != "agent_task" }
        let ends = records.filter { $0.recordType == .spanEnd && $0.name != "agent_task" }
        XCTAssertEqual(starts.count, 20)
        XCTAssertEqual(ends.count, 20)
        XCTAssertEqual(Set(starts.map(\.spanID)), Set(ends.map(\.spanID)))
        for start in starts {
            XCTAssertEqual(start.parentSpanID, parent.spanID)
        }
        XCTAssertTrue(ends.allSatisfy { $0.metadata["leaked"] == nil })
    }

    // MARK: - Privacy hashing

    func testHashStableWithinSaltAndDivergentAcrossSalts() {
        let saltA = Data(repeating: 0xAA, count: 16)
        let saltB = Data(repeating: 0xBB, count: 16)
        let a = EnergyTraceHasher(salt: saltA)
        let b = EnergyTraceHasher(salt: saltB)

        XCTAssertEqual(a.hash("ls -la"), a.hash("ls -la"))
        XCTAssertNotEqual(a.hash("ls -la"), b.hash("ls -la"))
        XCTAssertEqual(a.hash("ls -la").count, 64)
    }

    func testCommandHashNormalizesWhitespace() {
        let hasher = EnergyTraceHasher(salt: Data(repeating: 1, count: 16))
        XCTAssertEqual(hasher.hashCommand("ls   -la\n"), hasher.hashCommand("ls -la"))
        XCTAssertNotEqual(hasher.hashCommand("ls -la"), hasher.hashCommand("ls -l"))
    }

    func testInstallHasherPersistsSalt() {
        let suite = "EnergyTraceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = EnergyTraceHasher.installHasher(defaults: defaults)
        let second = EnergyTraceHasher.installHasher(defaults: defaults)
        XCTAssertEqual(first.salt, second.salt)
        XCTAssertEqual(first.hash("x"), second.hash("x"))
    }

    // MARK: - Robustness

    func testMalformedTrailingLineIsSkippedOnRead() throws {
        let url = tempDir.appendingPathComponent("energy-trace-partial-aaaa.jsonl")
        let good = EnergyTraceRecord(recordType: .event,
                                     wallTime: EnergyClock.wallTimeString(),
                                     monotonicNs: EnergyClock.monotonicNs(),
                                     runID: UUID(), name: "ok")
        var data = try JSONEncoder().encode(good)
        data.append(0x0A)
        data.append(Data("{\"schema_version\":1,\"record_type\":\"ev".utf8))
        try data.write(to: url)

        let records = try readRecords(url)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].name, "ok")
    }

    func testSamplingIntervalClamping() {
        var config = EnergyTraceConfiguration()
        config.samplingIntervalSeconds = 3.4
        EnergyTraceState.setConfiguration(config)
        XCTAssertEqual(EnergyTraceState.configuration.samplingIntervalSeconds, 2)

        config.samplingIntervalSeconds = 100
        EnergyTraceState.setConfiguration(config)
        XCTAssertEqual(EnergyTraceState.configuration.samplingIntervalSeconds, 10)
    }
}
