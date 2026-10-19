import AppKit
import Accelerate

// One of the test apps behind Culpmit's Test load, for as long as Culpmit asks, then it quits. Arguments: threads,
// seconds, the most memory it may hold, and the Mac's memory used to reach. Threads keep busy with vector maths as hot
// as real work; the memory fills a quarter of a GB at a time with random bytes, which macOS must hold in full, until
// memory runs short: memory used at the mark, or a GB and a half moved to swap to make room.

let args = CommandLine.arguments
let threads = args.count > 1 ? Int(args[1]) ?? 1 : 1
let seconds = args.count > 2 ? Double(args[2]) ?? 180 : 180
let bytes = args.count > 3 ? Int(args[3]) ?? 0 : 0
let mark = args.count > 4 ? Double(args[4]) ?? 0 : 0

for _ in 0..<max(0, threads) {
    let t = Thread {
        // multiply-adds on a block that stays in the core's own cache: the work that heats a CPU most
        let n = 1024
        let a = [Float](repeating: 0.5, count: n), b = [Float](repeating: 0.5, count: n)
        var c = [Float](repeating: 0.25, count: n), d = [Float](repeating: 0, count: n)
        while true {
            vDSP_vma(a, 1, b, 1, c, 1, &d, 1, vDSP_Length(n))
            swap(&c, &d)
        }
    }
    // full clock speed, the way an app at work runs
    t.qualityOfService = .userInitiated
    t.start()
}

// the memory, held until the app quits
var held: [UnsafeMutableRawPointer] = []
let chunk = 256 << 20
var filled = 0

// the Mac's memory used as Activity Monitor counts it: app memory, wired and compressed
func used() -> Double {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return .infinity }
    let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
    return pages * Double(vm_kernel_page_size)
}

// swap in use, which macOS grows to make room once memory runs short
func swapUsed() -> Double {
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
    return Double(swap.xsu_used)
}
let startSwap = swapUsed()

func fill() {
    guard filled < bytes else { return }
    guard mark <= 0 || used() < mark, swapUsed() - startSwap < 1.5 * 1_073_741_824 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: fill)
        return
    }
    let block = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
    arc4random_buf(block, chunk)
    held.append(block)
    filled += chunk
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: fill)
}
DispatchQueue.main.async(execute: fill)

// App Nap stays away from an app that shows no window
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Culpmit test load")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
