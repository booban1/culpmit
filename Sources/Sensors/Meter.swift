import Darwin

// Whole-machine CPU load from the kernel's tick counters, cheap enough to read every second

final class LoadMeter {
    private let host = mach_host_self()
    private var last: host_cpu_load_info?

    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { last = info }
        guard let l = last else { return nil }
        let user = Double(info.cpu_ticks.0 &- l.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- l.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- l.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- l.cpu_ticks.3)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total * 100 : nil
    }
}
