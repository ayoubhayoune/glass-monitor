import Foundation
import IOKit
import IOKit.ps
import SwiftUI

struct CPUTicks {
    var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    var total: UInt64 { user + system + idle + nice }
}

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot · throttling"
        case .critical: "Critical · throttling"
        @unknown default: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
    }
}

struct PowerInfo: Equatable {
    let watts: Double
    let onBattery: Bool
    let charging: Bool
    let percent: Int?
    /// Minutes until empty (on battery) or full (charging); nil while macOS is still estimating.
    let minutesRemaining: Int?
}

/// Battery wear as macOS reports it in System Information.
struct BatteryHealth: Equatable {
    let maxCapacity: Int?
    let cycles: Int?
    let condition: String?
}

enum SystemStats {
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    /// "Memory Used" the way Activity Monitor computes it: app memory + wired + compressed.
    static func memory() -> (used: UInt64, total: UInt64, compressed: UInt64, swapUsed: UInt64, swapTotal: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var used: UInt64 = 0, compressed: UInt64 = 0
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let app = UInt64(vm.internal_page_count) - min(UInt64(vm.purgeable_count), UInt64(vm.internal_page_count))
            compressed = UInt64(vm.compressor_page_count) * page
            used = (app + UInt64(vm.wire_count)) * page + compressed
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return (min(used, total), total, compressed, swap.xsu_used, swap.xsu_total)
    }

    /// This app's total CPU seconds (itself plus finished helper processes such as ps/lsof)
    /// and its memory footprint (the "Memory" column in Activity Monitor).
    static func selfUsage() -> (cpuTime: Double, memory: UInt64) {
        func seconds(_ r: rusage) -> Double {
            Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6
                + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6
        }
        var me = rusage(), children = rusage()
        getrusage(RUSAGE_SELF, &me)
        getrusage(RUSAGE_CHILDREN, &children)

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return (seconds(me) + seconds(children), result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0)
    }

    static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    static func disk() -> (used: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
        else { return (0, 0) }
        return (Int64(total) - free, Int64(total))
    }

    /// Cumulative bytes read/written by all block storage drivers since boot.
    static func diskIOBytes() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        forEachService("IOBlockStorageDriver") { service in
            guard let stats = property(service, "Statistics") as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    /// Busiest GPU's "Device Utilization %" (0...1), as shown by Activity Monitor's GPU History.
    static func gpuUtilization() -> Double? {
        var best: Double?
        forEachService("IOAccelerator") { service in
            guard let stats = property(service, "PerformanceStatistics") as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            best = max(best ?? 0, value / 100)
        }
        return best
    }

    /// Cumulative bytes on physical ("en*") interfaces, using the 64-bit counters from NET_RT_IFLIST2.
    static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var received: UInt64 = 0, sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                        received += info.ifm_data.ifi_ibytes
                        sent += info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }

    static func power() -> PowerInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let millivolts = (property(service, "Voltage") as? NSNumber)?.doubleValue ?? 0
        // Amperage is a signed value (negative while discharging) that can surface as a wrapped unsigned number.
        let milliamps = Double((property(service, "InstantAmperage") as? NSNumber)?.int64Value ?? 0)
        let onBattery = !((property(service, "ExternalConnected") as? Bool) ?? true)
        let charging = (property(service, "IsCharging") as? Bool) ?? false
        return PowerInfo(watts: abs(millivolts * milliamps) / 1_000_000, onBattery: onBattery, charging: charging,
                         percent: (property(service, "CurrentCapacity") as? NSNumber)?.intValue,
                         minutesRemaining: minutesRemaining(onBattery: onBattery, charging: charging))
    }

    /// Time to empty / full from the public power-sources API (-1 while estimating).
    private static func minutesRemaining(onBattery: Bool, charging: Bool) -> Int? {
        guard onBattery || charging, let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let key = onBattery ? kIOPSTimeToEmptyKey : kIOPSTimeToFullChargeKey
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return (description[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
        }
        return nil
    }

    /// Maximum capacity / cycle count / condition exactly as System Information shows them.
    /// Slow (≈0.5 s, spawns system_profiler): call off the main thread, rarely.
    static func batteryHealth() -> BatteryHealth? {
        let output = Shell.run("/usr/sbin/system_profiler", ["-json", "SPPowerDataType"]).output
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let sections = json["SPPowerDataType"] as? [[String: Any]],
              let health = sections.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first else { return nil }
        let capacity = (health["sppower_battery_health_maximum_capacity"] as? String)
            .flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        return BatteryHealth(maxCapacity: capacity, cycles: health["sppower_battery_cycle_count"] as? Int,
                             condition: health["sppower_battery_health"] as? String)
    }

    // MARK: IOKit helpers

    private static func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
