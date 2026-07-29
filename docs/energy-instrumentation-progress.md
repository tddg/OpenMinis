# Energy instrumentation — progress record

Branch: `energy-trace` on `tddg/OpenMinis` (research fork; never push upstream).
Spec: `minis_energy_instrumentation_implementation_spec.md` (reference, not contract).
Last updated: 2026-07-28.

## Status: instrumentation complete, deployed, first data collected

The full EnergyTrace subsystem is implemented, building, unit-tested, installed
on the research iPhone (14 Plus, `iPhone14,8`), and has produced its first five
real task traces. Next phase: joint capture with Instruments Power Profiler to
attach joules to the trace phases.

## What exists

### On-device instrumentation (`src/ios/Diagnostics/EnergyTrace/`)
- `EnergyTraceModels.swift` — versioned JSONL schema (run/span/event/resource_sample),
  monotonic clock (`CLOCK_MONOTONIC`, counts across sleep), span tokens.
- `EnergyTraceConfiguration.swift` — config + salted privacy hashing.
  **Research default: tracing is ON** (`EnergyTraceState._enabled = true`);
  every agent task auto-opens a task-scoped run. Disable via
  `minis-debug rpc debug.energyTrace.disable`.
- `EnergyTraceStore.swift` — lock-guarded buffered JSONL writer.
  **Traces land in `Documents/EnergyTraces/`** (visible in the Files app via
  `UIFileSharingEnabled`) — one file per run, pruned at 30 files / 200 MB.
- `EnergyTrace.swift` — actor coordinator; paired OSSignposter intervals
  (subsystem `com.openminis.app.energytrace`, categories AgentTask/Model/Tool/
  Shell/Browser/NativeOffload/Persistence/Lifecycle) + JSONL records; leak
  closure at run end; `withEnergySpan` guarantees closure on throw/cancel.
- `EnergyTraceRuntime.swift` — MainActor glue: agent_task span from
  `AIChatViewModel.isProcessing` transitions (covers all six loop entry points),
  model-phase state machine, 2 s resource sampler (only while a run is active),
  lifecycle event observers, battery-monitoring toggle.
- `EnergyResourceSampler.swift` — Mach CPU/memory samplers (mirrors
  BrowserResourceMonitor), device context capture.

### Instrumented call sites
| Span | Where |
|---|---|
| `agent_task` | `AIChatViewModel.swift` `isProcessing` didSet (~line 580/595) |
| `model_request` + TTFT/stream children | `runAgentLoop` around `streamWithGroupFallback` (~line 4625) + usage capture (~line 4948); first token via `processStreamEvents` `.contentBlockStart` (`+SSEStream.swift` ~line 290) |
| `shell_execute` + `shell_output_sanitize` | `AIChatViewModel+ISHCommand.swift` `runRaw` — hash-only commands, exit/bytes/PID; native offloads classified via `OffloadPermissionManager.extractOffloadCommand` (tool_family = calendar/health/photos/…) |
| `browser_action` | `BrowserTabPool.execute` (single chokepoint; bridge emits `browser_bridge_overhead` events, no double count) |
| `file_read/file_write/state_persist/tool_dispatch` | `executeSingleToolUse` (+ConcurrentTools) and `persistAgentMessage` |

### Controls & retrieval
- Debug RPC: `debug.energyTrace.{status,start,stop,enable,disable,setSamplingInterval,list,read,export,delete}`
  (DebugJSONRPC switch + DebugMethodRegistry entries + `DebugRPCEnergy.swift`).
- On-device CLI: `minis-debug rpc <method> ['{json}']` (new generic passthrough).
  Labeled experiment: `start {"task_class":"browser","label":"x","variant":"baseline"}`
  → run task in chat → `stop {"success":true}`.
- Retrieval: Files app → On My iPhone → Minis → EnergyTraces (AirDrop), or
  Xcode → Devices → Download Container (slow: includes rootfs).
- Offline analysis: `scripts/energy_trace_parse.py *.jsonl -o out/` →
  `runs.csv` / `spans.csv` with integrity checks.

### Research-signing changes (revert for paid-team builds)
1. Entitlements stripped (WeatherKit, iCloud/CloudKit, health-records, NFC) —
   personal teams can't provision them. Keep iCloud Sync OFF in app settings.
2. App group renamed → `group.edu.vt.yuec.minis` (global uniqueness).
3. Bundle IDs → `edu.vt.yuec.minis[.*]` (App Store IDs unregisterable);
   research build coexists with the official app.
4. `UIFileSharingEnabled` = true (exposes Documents incl. alpine-rootfs — don't edit).

### Upstream bugs found & fixed on this branch
- `DebugLocalDispatch` / `MinisDebugLogReader` needed `@objc(Name)` — bare
  `@objc` keeps module-qualified runtime names, so ALL RPC-backed `minis-debug`
  subcommands returned -32001 (verified via standalone swiftc repro).
- `ShellCommandRingBuffer` leaked its running count on thrown executions.
- Pre-existing, NOT fixed: 6 `ToolLoopDetectorTests` failures (reproduce on
  main); `ToolPreflightTests.swift` never compiled in MinisTests (excluded via
  membershipExceptions).

## Build environment (this Mac)
- Xcode 26.3, iOS 26.2 SDK, iOS platform downloaded. Disk tight (~12 GB free).
- Native deps built (`deps/build_lame.sh` → `build_ffmpeg.sh` → `build_ish.sh`
  → `prepare_alpine_rootfs.sh`); `build_ish.sh` needs `brew install lld`.
- App build: `xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis
  -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
- Unit tests (19/19 pass): build MinisTests with `-sdk iphonesimulator26.2
  ARCHS=arm64 TEST_HOST= BUNDLE_LOADER=`, run via `xcrun simctl spawn <sim>
  .../Agents/xctest`. Also a macOS SwiftPM harness in the session scratchpad.
- Deploy to phone: Xcode ⌘R, personal team (7-day expiry), Developer Mode on.

## First session findings (5 auto-runs, Jul 28, gpt-5.6-sol via OpenAI)
Visualization: https://claude.ai/code/artifact/055ce71a-5fc0-4d29-b1a2-71f0b164e37e
- **Shell/native-tool residency = 83% of traced wall time.** Long runs (5.6 and
  7.5 min) are one `healthkit` offload occupying nearly the whole run at 8–10%
  mean CPU — phone held awake waiting, supporting the residency hypothesis.
- Model streaming is a small share even at 638k input tokens (187k cached).
- Instrumentation coverage: unattributed gap < 1.2 s per run. Concurrency
  captured (up to 4 overlapping shell commands).
- Session battery 85% → 80% over ~42 min. Peak app CPU 173%.
- Known gap: battery null in run_start context (enabled just after capture);
  present in every 2 s sample — use samples.

## Next: Power Profiler joint capture (in progress)
Goal: joules per phase. Record Instruments **Power Profiler + Points of
Interest** (subsystem `com.openminis.app.energytrace`) while a labeled task
runs; integrate power over span windows. Notes: phone must be unplugged during
measurement (charging zeroes system power) → wireless debugging, or accept
cable for pipeline validation only. CLI route: `xcrun xctrace record
--template ... --device ...`. Not yet done: overhead A/B microbenchmark
(spec §10), browser-task captures, controlled variant experiments (§13/§14).
