import AppKit

// Memory as Activity Monitor counts it: the pressure gauge macOS keeps, memory used (app memory, wired and
// compressed) of the total, swap, and each process's footprint

enum Pressure: Int {
    case normal = 1, warning = 2, critical = 4

    var name: String { ["Normal", "Warning", "", "Critical"][rawValue - 1] }
    // Activity Monitor's colours: the label's own at normal, yellow at warning, red at critical
    var tint: NSColor? { self == .normal ? nil : self == .warning ? .systemYellow : .systemRed }
}

struct MemoryReading {
    let used: Double
    let total: Double
    let swap: Double
    let pressure: Pressure
}

func memoryReading() -> MemoryReading? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = Double(vm_kernel_page_size)
    let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
    let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
    var level: Int32 = 1
    var levelSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
    return MemoryReading(used: used, total: Double(ProcessInfo.processInfo.physicalMemory), swap: Double(swap.xsu_used),
                         pressure: Pressure(rawValue: Int(level)) ?? .normal)
}

// a process's footprint in bytes, as Activity Monitor's Memory column shows it; readable for this account's processes
func footprint(_ pid: pid_t) -> Double? {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    return result == 0 ? Double(info.ri_phys_footprint) : nil
}
