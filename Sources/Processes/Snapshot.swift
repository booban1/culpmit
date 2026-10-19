import Foundation

// Every process's CPU share from one ps call, plus the dev server's cap, and small lookups by process ID

struct Snapshot {
    var byPid: [pid_t: Double] = [:]
    var devCap = "Off"
}

// one ps call serves every reading within the same second. Waiting on ps runs the run loop, so a timer can ask again
// mid-call; it gets the last reading, and the lock covers only the bookkeeping.
private var lastSnapshot: (at: Date, snap: Snapshot)?
private var sampling = false
private let snapshotLock = NSLock()

func snapshot() -> Snapshot {
    snapshotLock.lock()
    if let last = lastSnapshot, sampling || Date().timeIntervalSince(last.at) < 0.9 {
        snapshotLock.unlock()
        return last.snap
    }
    if sampling {
        snapshotLock.unlock()
        return Snapshot()
    }
    sampling = true
    snapshotLock.unlock()
    var s = Snapshot()
    for line in run("/bin/ps", ["-Ao", "pid=,%cpu=,command="]).out.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let pid = pid_t(parts[0]), let v = Double(parts[1]) else { continue }
        s.byPid[pid] = v / threads
        guard parts.count == 3, parts[2].contains("next dev") else { continue }
        let words = parts[2].split(separator: " ")
        if let c = words.first, c.hasSuffix("cpulimit"), let i = words.firstIndex(of: "-l"), i + 1 < words.count,
           let n = Double(words[i + 1]) {
            s.devCap = percent(n / threads)
        }
    }
    snapshotLock.lock()
    lastSnapshot = (Date(), s)
    sampling = false
    snapshotLock.unlock()
    return s
}

func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buffer, UInt32(buffer.count))
    return String(cString: buffer)
}

func parentOf(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
}
