import AppKit

// Idle: holds a regular app to a tenth of one core, so it stops heating the Mac while it keeps running.
// It holds until Wake or until Culpmit quits.

let idleCPUs = 0.1
private let idleExempt: Set<String> = ["com.apple.finder", "com.apple.dock", "com.simonbooban.culpmit"]

extension Menu {
    func canIdle(_ pid: pid_t) -> Bool {
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              let id = app.bundleIdentifier else { return false }
        return !idleExempt.contains(id)
    }

    func isIdled(_ pid: pid_t) -> Bool { idlers[pid] != nil }

    func toggleIdle(_ pid: pid_t) { isIdled(pid) ? wake(pid) : idle(pid) }

    func idle(_ pid: pid_t) {
        guard canIdle(pid), idlers[pid] == nil else { return }
        // a capped app's own limiter steps aside while it idles
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { limiters[id]?.stop() }
        let limiter = Limiter()
        limiter.start(root: pid, cpus: idleCPUs)
        idlers[pid] = limiter
        rememberIdled()
        note("idle \(pid)")
    }

    func wake(_ pid: pid_t) {
        guard let limiter = idlers.removeValue(forKey: pid) else { return }
        limiter.stop()
        rememberIdled()
        // an app idled for memory stays awake a while once woken, however it woke
        if let id = autoIdled.removeValue(forKey: pid) { autoWoken[id] = Date() }
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, apps.contains(where: { $0.id == id }) {
            applyApp(id)
        }
        note("wake \(pid)")
    }

    // idled apps stay listed beside the busy ones, so they can be woken from the menu and the Touch Bar
    func withIdled(_ hogs: [Hog], _ byPid: [pid_t: Double]) -> [Hog] {
        let idled = idlers.keys.sorted().compactMap { pid -> Hog? in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            let tree = Limiter.tree(of: pid)
            let cpu = tree.reduce(0.0) { $0 + (byPid[$1] ?? 0) }
            let memory = tree.reduce(0.0) { $0 + (footprint($1) ?? 0) }
            return Hog(name: app.localizedName ?? "process \(pid)", cpu: cpu, memory: memory, app: app, pid: pid, mine: true)
        }
        return idled + hogs.filter { !isIdled($0.pid) }
    }

    private func rememberIdled() { store.set(idlers.keys.map { Int($0) }, forKey: "idled") }

    func watchIdled() {
        // apps left idled by a Culpmit that stopped without its goodbye run free again
        for pid in (store.array(forKey: "idled") as? [Int]) ?? [] {
            for p in Limiter.tree(of: pid_t(pid)) { kill(p, SIGCONT) }
        }
        store.removeObject(forKey: "idled")
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            self?.idlers.removeValue(forKey: pid)?.stop()
            self?.autoIdled.removeValue(forKey: pid)
            self?.rememberIdled()
        }
        // an app idled for memory wakes as soon as you switch to it
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier,
                  self.autoIdled[pid] != nil else { return }
            self.wake(pid)
        }
    }
}
