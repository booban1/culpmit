import Foundation
import Darwin

// Holds an app's process tree to a share of the machine by pausing it in short slices

final class Limiter {
    private let lock = NSLock()
    private var active = false
    private var done = DispatchSemaphore(value: 0)
    private var members: [pid_t] = []
    private var target = 1.0
    private var tracked: pid_t = 0
    private let timebase: Double = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return Double(t.numer) / Double(t.denom)
    }()

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return active }

    var root: pid_t { lock.lock(); defer { lock.unlock() }; return tracked }

    func setCPUs(_ cpus: Double) {
        lock.lock()
        target = cpus
        lock.unlock()
    }

    private func cpusNow() -> Double { lock.lock(); defer { lock.unlock() }; return target }

    func start(root: pid_t, cpus: Double) {
        stop()
        lock.lock()
        active = true
        target = cpus
        tracked = root
        done = DispatchSemaphore(value: 0)
        lock.unlock()
        let thread = Thread { [weak self] in self?.loop(root: root) }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        let was = active
        active = false
        let finished = done
        lock.unlock()
        if was { _ = finished.wait(timeout: .now() + 1) }
        resume()
    }

    private func resume() {
        lock.lock()
        let list = members
        lock.unlock()
        for p in list { kill(p, SIGCONT) }
    }

    private func keepGoing() -> Bool { lock.lock(); defer { lock.unlock() }; return active }

    private func cpuNanos(_ pid: pid_t) -> Double? {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        guard result == 0 else { return nil }
        return Double(info.ri_user_time + info.ri_system_time) * timebase
    }

    static func tree(of root: pid_t) -> [pid_t] {
        let count = Int(proc_listallpids(nil, 0))
        guard count > 0 else { return [root] }
        var pids = [pid_t](repeating: 0, count: count + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var kids: [pid_t: [pid_t]] = [:]
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for p in pids.prefix(max(0, got)) where p > 0 {
            if proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, size) == size {
                kids[pid_t(info.pbi_ppid), default: []].append(p)
            }
            // processes macOS holds the app responsible for, such as its web pages, join its tree too
            if p != root, responsibleFor?(p) == root { kids[root, default: []].append(p) }
        }
        var out = [root], seen: Set<pid_t> = [root], queue = [root]
        while let p = queue.popLast() {
            for c in kids[p] ?? [] where seen.insert(c).inserted { out.append(c); queue.append(c) }
        }
        return out
    }

    // the slices keep their timing on a Mac at full load: a real-time thread, the kind audio apps use, runs ahead of
    // every app's work, second only to the kernel and other real-time work. Its few milliseconds a slice sit well
    // inside the budget macOS allows such a thread; user-interactive priority stays as the floor.
    private static func runInRealTime() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let perMs = 1_000_000 * Double(timebase.denom) / Double(timebase.numer)
        var policy = thread_time_constraint_policy_data_t(period: 0, computation: UInt32(5 * perMs),
                                                          constraint: UInt32(20 * perMs), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }

    private func loop(root: pid_t) {
        Limiter.runInRealTime()
        let slot = 0.1
        var usage: [pid_t: Double] = [:]
        var last: [pid_t: (cpu: Double, at: Double)] = [:]
        var rate = 1.0
        var paused = false
        var scanned = 0.0
        var list: [pid_t] = []
        func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }

        while keepGoing() {
            if now() - scanned > 1e9 || list.isEmpty {
                guard kill(root, 0) == 0 else { break }
                list = Limiter.tree(of: root)
                lock.lock(); members = list; lock.unlock()
                let alive = Set(list)
                usage = usage.filter { alive.contains($0.key) }
                last = last.filter { alive.contains($0.key) }
                scanned = now()
            }
            var total = -1.0
            for p in list {
                guard let cpu = cpuNanos(p) else { continue }
                let at = now()
                if let l = last[p], at > l.at {
                    let sample = max(0, cpu - l.cpu) / (at - l.at)
                    let u = usage[p].map { 0.92 * $0 + 0.08 * sample } ?? sample
                    usage[p] = u
                    total = max(total, 0) + u
                }
                last[p] = (cpu, at)
            }
            let cpus = cpusNow()
            rate = total > 0 ? max(min(rate / total * cpus, 1), 0.05) : 1
            if paused {
                for p in list { kill(p, SIGCONT) }
                paused = false
            }
            if rate >= 1, total < 0.7 * cpus {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let work = slot * rate
            Thread.sleep(forTimeInterval: work)
            if slot - work > 0.002 {
                for p in list { kill(p, SIGSTOP) }
                paused = true
                Thread.sleep(forTimeInterval: slot - work)
            }
        }
        if paused { for p in list { kill(p, SIGCONT) } }
        lock.lock()
        let finished = done
        lock.unlock()
        finished.signal()
    }
}
