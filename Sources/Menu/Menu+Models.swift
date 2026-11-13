import AppKit
import IOKit

// Local models first: while llama.cpp, ollama or opencode works, every other busy app is held back, so the model has
// the Mac's whole heat budget. The model, the shells, the terminal apps and Culpmit run free; VS Code keeps one core
// for its terminal and chats. Two minutes after the model goes quiet, every app returns to where it stood.

private let modelPrefixes = ["llama-", "ollama", "opencode"]
private let shells: Set<String> = ["zsh", "bash", "fish", "sh", "login", "tmux", "screen"]
private let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                                      "net.kovidgoyal.kitty", "org.alacritty"]
// apps holding the terminal and the chats keep one core
private let oneCore: Set<String> = ["com.microsoft.VSCode"]
private let quietFor: TimeInterval = 120

extension Menu {
    func checkModels() {
        let snap = snapshot()
        var names: [pid_t: String] = [:]
        for pid in snap.byPid.keys { names[pid] = processName(pid) }
        let roots = names.filter { entry in modelPrefixes.contains { entry.value.hasPrefix($0) } }.map(\.key)
        guard !roots.isEmpty || modelRun else { return }
        let model = descendants(of: roots, among: Array(snap.byPid.keys))
        let cores = model.reduce(0.0) { $0 + (snap.byPid[$1] ?? 0) } * threads / 100
        // llama.cpp works on the Radeon with its processor threads asleep, so the graphics load counts while it stirs at
        // all; Ollama and OpenCode run on the processor here, and an idle server beside a busy graphics card is other
        // apps' work
        let llama = descendants(of: roots.filter { names[$0]?.hasPrefix("llama-") == true }, among: Array(snap.byPid.keys))
        let llamaCores = llama.reduce(0.0) { $0 + (snap.byPid[$1] ?? 0) } * threads / 100
        if !roots.isEmpty, cores >= 0.2 || (llamaCores >= 0.03 && gpuBusy() >= 50) { modelBusyAt = Date() }
        guard let busy = modelBusyAt, Date().timeIntervalSince(busy) < quietFor else {
            if modelRun { endModelRun() }
            return
        }
        if !modelRun {
            modelRun = true
            let who = Set(roots.compactMap { names[$0] }).sorted().joined(separator: ", ")
            note("model run: starts, \(who), \(String(format: "%.2f", cores)) cores")
        }
        let shellPids = names.filter { shells.contains($0.value) }.map(\.key)
        let terminalPids = NSWorkspace.shared.runningApplications.filter { terminals.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier)
        Limiter.spared = Set(model + shellPids + terminalPids + [getpid()])
        holdOthers(snap, sparing: Set(model))
    }

    // each busy app outside the model, held once a run: idled, or one core for VS Code; terminal apps run free
    private func holdOthers(_ snap: Snapshot, sparing model: Set<pid_t>) {
        let grouped = groupByApp(Array(snap.byPid.keys))
        for (key, members) in grouped.members {
            guard let app = grouped.owners[key], app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  !terminals.contains(id) else { continue }
            let pid = app.processIdentifier
            guard pid != getpid(), !modelHeld.contains(pid) else { continue }
            let cores = members.filter { !model.contains($0) }.reduce(0.0) { $0 + (snap.byPid[$1] ?? 0) } * threads / 100
            guard cores >= 0.05 else { continue }
            if oneCore.contains(id) {
                limiters[id]?.stop()
                let limiter = Limiter()
                limiter.start(root: pid, cpus: 1)
                modelCaps[pid] = limiter
            } else if !members.contains(where: model.contains), canIdle(pid), !isIdled(pid) {
                // the app hosting the model, such as Ollama's chat window, runs free
                idle(pid)
                modelIdled.insert(pid)
            } else {
                continue
            }
            modelHeld.insert(pid)
            note("model run: holds \(app.localizedName ?? id), \(String(format: "%.2f", cores)) cores")
        }
        store.set(modelHeld.map { Int($0) }, forKey: "modelHeld")
    }

    func endModelRun() {
        for pid in modelIdled where isIdled(pid) { wake(pid) }
        for (pid, limiter) in modelCaps {
            limiter.stop()
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, apps.contains(where: { $0.id == id }) {
                applyApp(id)
            }
        }
        modelIdled = []
        modelCaps = [:]
        modelHeld = []
        modelRun = false
        modelBusyAt = nil
        Limiter.spared = []
        store.removeObject(forKey: "modelHeld")
        note("model run: ends")
    }

    // apps held by a Culpmit that stopped mid-run run free again
    func settleModelRun() {
        for pid in (store.array(forKey: "modelHeld") as? [Int]) ?? [] {
            for p in Limiter.tree(of: pid_t(pid)) { kill(p, SIGCONT) }
        }
        store.removeObject(forKey: "modelHeld")
    }

    private func descendants(of roots: [pid_t], among pids: [pid_t]) -> [pid_t] {
        var kids: [pid_t: [pid_t]] = [:]
        for pid in pids { if let p = parentOf(pid) { kids[p, default: []].append(pid) } }
        var out = roots, queue = roots, seen = Set(roots)
        while let p = queue.popLast() {
            for c in kids[p] ?? [] where seen.insert(c).inserted { out.append(c); queue.append(c) }
        }
        return out
    }
}

// the busiest graphics processor's utilisation in percent, from its own statistics
func gpuBusy() -> Double {
    var iterator = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
        return 0
    }
    defer { IOObjectRelease(iterator) }
    var most = 0.0
    var service = IOIteratorNext(iterator)
    while service != 0 {
        if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any], let used = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
            most = max(most, used)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return most
}
