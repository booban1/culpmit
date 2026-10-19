import IOKit

// Reads sensors straight from the System Management Controller

final class SMC {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var input = input
        var output = [UInt8](repeating: 0, count: 80)
        var size = 80
        let result = IOConnectCallStructMethod(conn, 2, &input, 80, &output, &size)
        guard result == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }

    private func put(_ value: UInt32, _ buffer: inout [UInt8], at index: Int) {
        withUnsafeBytes(of: value) { for (i, byte) in $0.enumerated() { buffer[index + i] = byte } }
    }

    private func get(_ buffer: [UInt8], at index: Int) -> UInt32 {
        buffer[index..<index + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    func raw(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard key.utf8.count == 4 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        put(key.utf8.reduce(0) { $0 << 8 | UInt32($1) }, &input, at: 0)
        input[42] = 9
        guard let info = call(input) else { return nil }
        let size = get(info, at: 28), type = get(info, at: 32)
        guard size > 0, size <= 32 else { return nil }
        put(size, &input, at: 28)
        input[42] = 5
        guard let out = call(input) else { return nil }
        let name = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: type >> UInt32($0)) }, encoding: .ascii) ?? ""
        return (name, Array(out[48..<48 + Int(size)]))
    }

    func value(_ key: String) -> Double? {
        guard let (type, b) = raw(key) else { return nil }
        switch type {
        case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "flt " where b.count >= 4: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "fpe2" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ui8 " where b.count >= 1: return Double(b[0])
        case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4: return Double(b[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default: return nil
        }
    }

    // the CPU's sensor, found once on each Mac: the names Intel Macs share first, then the hottest of the core
    // sensors this Mac lists; a sensor that stops answering is looked for afresh on the next read
    private var cpuKeys: [String]?

    func cpuTemperature() -> Double? {
        if cpuKeys == nil { cpuKeys = findCPUKeys() }
        let readings = (cpuKeys ?? []).compactMap { value($0) }.filter { $0 > 0 && $0 < 130 }
        if readings.isEmpty { cpuKeys = nil }
        return readings.max()
    }

    // the key or keys behind the reading, for --status
    var cpuSensor: String { (cpuKeys ?? []).joined(separator: " ") }

    private func findCPUKeys() -> [String] {
        for key in ["TC0P", "TC0D", "TC0E", "TC0F", "TCAD", "TCXC", "TCXc", "TC0H"] {
            if let v = value(key), v > 0, v < 130 { return [key] }
        }
        return allKeys().filter { key in
            let c = Array(key)
            return c[0] == "T" && c[1] == "C" && c[2].isNumber && (c[3] == "C" || c[3] == "c") && (value(key) ?? 0) > 0
        }
    }

    // every key this SMC holds, read by index
    private func allKeys() -> [String] {
        let count = Int(value("#KEY") ?? 0)
        return (0..<count).compactMap { i in
            var input = [UInt8](repeating: 0, count: 80)
            input[42] = 8
            put(UInt32(i), &input, at: 44)
            guard let out = call(input) else { return nil }
            let key = get(out, at: 0)
            return String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: key >> UInt32($0)) }, encoding: .ascii)
        }.filter { $0.count == 4 }
    }

    func fans() -> [Double] {
        let count = Int(value("FNum") ?? 0)
        return (0..<count).compactMap { value("F\($0)Ac") }
    }

    // each fan's top speed, in the same order
    func fanMaxes() -> [Double] {
        let count = Int(value("FNum") ?? 0)
        return (0..<count).compactMap { value("F\($0)Mx") }
    }
}
