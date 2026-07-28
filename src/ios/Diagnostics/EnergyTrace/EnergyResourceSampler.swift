import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Resource sampling
//
// Low-frequency process/device samples recorded while an energy-trace run is
// active (default every 2 s, never faster than 1 Hz, and never when no run is
// active). These are explanatory variables for the external Power Profiler
// measurement, not energy readings themselves: app CPU / memory are proxies
// scoped to this process (WebContent is a separate process and is invisible
// here — see BrowserResourceMonitor's documentation, which stays authoritative
// on that limitation).
//
// The Mach samplers mirror BrowserResourceMonitor's private helpers; they are
// duplicated rather than exposed because the spec forbids risky diagnostics
// refactors and BrowserResourceMonitor deliberately keeps its own copies
// (same precedent as CrashReporter).

enum EnergyResourceSampler {

    /// One resource_sample record's metadata. Main-actor because it reads
    /// UIApplication / UIScreen / UIDevice state.
    @MainActor
    static func sampleMetadata() -> [String: EnergyValue] {
        var meta: [String: EnergyValue] = [
            "app_memory_mb": .int(Int64(appMemoryMB())),
            "app_available_memory_mb": .int(Int64(appAvailableMemoryMB())),
            "app_cpu_percent": .double((appCPUPercent() * 10).rounded() / 10),
            "thermal_state": .string(thermalStateName()),
            "low_power_mode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "active_shell_commands": .int(Int64(runningShellCommandCount())),
        ]
        #if canImport(UIKit)
        meta["app_state"] = .string(appStateName())
        meta["battery_level"] = batteryLevel()
        meta["battery_state"] = .string(batteryStateName())
        meta["screen_brightness"] = .double(Double(UIScreen.main.brightness))
        if UIApplication.shared.applicationState == .background {
            let remaining = UIApplication.shared.backgroundTimeRemaining
            if remaining < 24 * 60 * 60 {
                meta["background_time_remaining_s"] = .double(remaining.rounded())
            }
        }
        #endif
        return meta
    }

    /// run_start context: device/app identity plus the same environment fields
    /// the resource samples carry, so a run is interpretable on its own.
    @MainActor
    static func deviceContextMetadata() -> [String: EnergyValue] {
        var meta: [String: EnergyValue] = [
            "device_model": .string(deviceModelIdentifier()),
            "os_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "app_version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
            "build_number": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
            "network_type": .string(NetworkMonitor.currentNetworkTypeName),
            "thermal_state": .string(thermalStateName()),
            "low_power_mode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
        ]
        #if canImport(UIKit)
        meta["app_state"] = .string(appStateName())
        meta["battery_level"] = batteryLevel()
        meta["battery_state"] = .string(batteryStateName())
        meta["screen_brightness"] = .double(Double(UIScreen.main.brightness))
        meta["idle_timer_disabled"] = .bool(UIApplication.shared.isIdleTimerDisabled)
        #endif
        return meta
    }

    // MARK: Environment helpers

    static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func runningShellCommandCount() -> Int {
        ShellCommandRingBuffer.syncSnapshot.filter { $0.exitCode == nil }.count
    }

    #if canImport(UIKit)
    @MainActor
    static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    /// Requires UIDevice battery monitoring to be enabled (EnergyTraceRuntime
    /// turns it on while a run is active); reports null otherwise.
    @MainActor
    static func batteryLevel() -> EnergyValue {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? .double(Double(level)) : .null
    }

    @MainActor
    static func batteryStateName() -> String {
        switch UIDevice.current.batteryState {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
    #endif

    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // MARK: Mach samplers (process-scoped proxies, not energy measurements)

    /// Resident footprint of this process (MB); `phys_footprint`, excluding
    /// out-of-process WebContent by construction.
    static func appMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) / (1024 * 1024)
    }

    /// Remaining allocation budget before this process is jetsammed (MB).
    static func appAvailableMemoryMB() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory()) / (1024 * 1024)
        #else
        return -1
        #endif
    }

    /// Per-thread CPU summed for this process (%); 100.0 == one saturated
    /// core. WebContent CPU does not appear here.
    static func appCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return -1 }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            if info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }
}
