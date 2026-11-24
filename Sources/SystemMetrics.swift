import Darwin
import Foundation

struct SystemSnapshot {
    let cpuUsage: Double        // 0.0 ... 1.0
    let ramUsage: Double        // 0.0 ... 1.0
    let ramUsedBytes: UInt64
    let ramTotalBytes: UInt64
    let thermalState: ProcessInfo.ThermalState

    var isThrottling: Bool {
        thermalState == .serious || thermalState == .critical
    }

    var thermalDescription: String {
        switch thermalState {
        case .nominal:
            return "Normal"
        case .fair:
            return "Fair"
        case .serious:
            return "Throttling (Serious)"
        case .critical:
            return "Throttling (Critical)"
        @unknown default:
            return "Unknown"
        }
    }
}

/// Ultra-lightweight native Mach/Foundation system metrics sampler.
/// Performs zero subprocesses and zero heap allocations per sample.
final class SystemMetrics {
    private let hostPort: mach_port_t
    private let pageSize: UInt64
    private let totalMemoryBytes: UInt64

    private var hasPreviousCPU = false
    private var prevUser: UInt32 = 0
    private var prevSystem: UInt32 = 0
    private var prevIdle: UInt32 = 0
    private var prevNice: UInt32 = 0

    init() {
        self.hostPort = mach_host_self()
        var size: vm_size_t = 0
        if host_page_size(hostPort, &size) == KERN_SUCCESS, size > 0 {
            self.pageSize = UInt64(size)
        } else {
            self.pageSize = UInt64(getpagesize())
        }
        self.totalMemoryBytes = ProcessInfo.processInfo.physicalMemory

        // Prime baseline CPU ticks so the first scheduled sample has a valid delta.
        _ = sampleCPU()
    }

    func sample() -> SystemSnapshot {
        let cpu = sampleCPU()
        let (ramUsage, usedBytes) = sampleRAM()
        let thermal = ProcessInfo.processInfo.thermalState
        return SystemSnapshot(
            cpuUsage: cpu,
            ramUsage: ramUsage,
            ramUsedBytes: usedBytes,
            ramTotalBytes: totalMemoryBytes,
            thermalState: thermal
        )
    }

    private func sampleCPU() -> Double {
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr = withUnsafeMutablePointer(to: &loadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0.0 }

        let user = loadInfo.cpu_ticks.0
        let system = loadInfo.cpu_ticks.1
        let idle = loadInfo.cpu_ticks.2
        let nice = loadInfo.cpu_ticks.3

        defer {
            prevUser = user
            prevSystem = system
            prevIdle = idle
            prevNice = nice
            hasPreviousCPU = true
        }

        guard hasPreviousCPU else { return 0.0 }

        let dUser = UInt64(user &- prevUser)
        let dSystem = UInt64(system &- prevSystem)
        let dIdle = UInt64(idle &- prevIdle)
        let dNice = UInt64(nice &- prevNice)

        let active = dUser + dSystem + dNice
        let total = active + dIdle
        guard total > 0 else { return 0.0 }

        return min(1.0, max(0.0, Double(active) / Double(total)))
    }

    private func sampleRAM() -> (usage: Double, usedBytes: UInt64) {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS, totalMemoryBytes > 0 else { return (0.0, 0) }

        // Activity Monitor "Memory Used": App Memory (internal - purgeable) + Wired + Compressed.
        let internalPages = UInt64(vmStats.internal_page_count)
        let purgeablePages = UInt64(vmStats.purgeable_count)
        let appPages = internalPages >= purgeablePages ? (internalPages - purgeablePages) : 0
        let wiredPages = UInt64(vmStats.wire_count)
        let compressedPages = UInt64(vmStats.compressor_page_count)

        let usedBytes = (appPages + wiredPages + compressedPages) * pageSize
        let usage = min(1.0, max(0.0, Double(usedBytes) / Double(totalMemoryBytes)))
        return (usage, usedBytes)
    }
}
