import AppKit

// The busiest apps and processes right now, each helper counted under the app that ships it

struct Hog {
    let name: String
    let cpu: Double
    // the group's footprint in bytes; zero where macOS keeps another user's processes private
    let memory: Double
    let app: NSRunningApplication?
    let pid: pid_t
    let mine: Bool
}

func pathOf(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return String(cString: buffer)
}

func uidOf(_ pid: pid_t) -> uid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_uid : nil
}

// Busy: an app joins at half of one core (Activity Monitor's scale) and leaves under 30% of one,
// so an app near the line holds still. Shares here are of the whole Mac, hence the division by threads.
final class BusyList {
    static let join = 50 / threads
    static let leave = 30 / threads
    private var listed: Set<pid_t> = []

    func update(_ byPid: [pid_t: Double], count: Int) -> [Hog] {
        let busy = topHogs(byPid, count: 20).filter { $0.cpu >= BusyList.join || (listed.contains($0.pid) && $0.cpu >= BusyList.leave) }
        listed = Set(busy.map(\.pid))
        return Array(busy.prefix(count))
    }
}

// the app macOS holds responsible for a process, as Activity Monitor groups them (a libsystem call, looked up once)
let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
    guard let f = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(f, to: (@convention(c) (pid_t) -> pid_t).self)
}()

// every process under the app that ships it, as Activity Monitor groups them, keyed by the app's pid
func groupByApp(_ pids: [pid_t]) -> (members: [pid_t: [pid_t]], owners: [pid_t: NSRunningApplication]) {
    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (String, NSRunningApplication)? in
        guard let path = app.bundleURL?.path else { return nil }
        return (path + "/", app)
    }
    var members: [pid_t: [pid_t]] = [:]
    var owners: [pid_t: NSRunningApplication] = [:]
    let me = getpid(), home = Bundle.main.bundlePath + "/"
    for pid in pids {
        let path = pathOf(pid)
        // the outermost app holds its helpers; an app in its own right nested inside another, such as Culpmit's test
        // apps, holds itself
        let matches = apps.filter { path.hasPrefix($0.0) }
        let inner = matches.max(by: { $0.0.count < $1.0.count })?.1
        var owner = inner?.activationPolicy == .regular ? inner : matches.min(by: { $0.0.count < $1.0.count })?.1
        // Culpmit holds only itself: an app inside it stands on its own from its first moment, before macOS lists it
        if owner?.processIdentifier == me, pid != me, path.hasPrefix(home) { owner = NSRunningApplication(processIdentifier: pid) }
        // a helper living outside its app, such as a web page's process, counts under the app responsible for it
        if owner == nil, let responsible = responsibleFor?(pid), responsible > 0, responsible != pid {
            owner = apps.first { $0.1.processIdentifier == responsible }?.1
        }
        let key = owner?.processIdentifier ?? pid
        members[key, default: []].append(pid)
        if let owner { owners[key] = owner }
    }
    return (members, owners)
}

// the apps using the most CPU, or with byMemory the most memory, each with both figures
func topHogs(_ byPid: [pid_t: Double], count: Int = 3, byMemory: Bool = false) -> [Hog] {
    let (members, owners) = groupByApp(Array(byPid.keys))
    let cpu = members.mapValues { $0.reduce(0) { $0 + (byPid[$1] ?? 0) } }
    let memory = byMemory ? members.mapValues { $0.reduce(0) { $0 + (footprint($1) ?? 0) } } : [:]
    let ranked = (byMemory ? memory : cpu).sorted { $0.value > $1.value }.map(\.key)
    return ranked.prefix(count).compactMap { pid in
        let share = cpu[pid] ?? 0
        guard byMemory || share >= 1 else { return nil }
        let app = owners[pid] ?? NSRunningApplication(processIdentifier: pid)
        var name = app?.localizedName ?? processName(pid)
        if name.isEmpty { name = pid == 0 ? "kernel_task" : (pathOf(pid) as NSString).lastPathComponent }
        if name.isEmpty { name = "process \(pid)" }
        let bytes = memory[pid] ?? (members[pid] ?? []).reduce(0) { $0 + (footprint($1) ?? 0) }
        return Hog(name: name, cpu: share, memory: bytes, app: app, pid: pid, mine: uidOf(pid) == getuid())
    }
}
