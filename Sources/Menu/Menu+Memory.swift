import AppKit

// Memory, watched from the menu bar's tick each second: the memory alert against its line, and while memory runs
// short, capped apps past their memory line. Memory used shows on the Performance line, tinted by pressure.

extension Menu {
    func checkMemory() {
        guard let m = memoryReading() else { return }
        let swapping = watchSwap(m)
        alertOverLine(m, swapping: swapping)
        // short: pressure up, or memory moving to swap; during a test, memory past the alert's line too, so the memory
        // line can be seen at work
        let short = m.pressure != .normal || swapping || (testing && m.used >= memoryAlertLine * m.total)
        guard short else {
            shortSince = nil
            let calm = calmSince ?? Date()
            calmSince = calm
            // pressure back at normal for 30 seconds wakes the apps idled for memory
            if Date().timeIntervalSince(calm) >= 30 { for pid in Array(autoIdled.keys) { wake(pid) } }
            return
        }
        calmSince = nil
        let since = shortSince ?? Date()
        shortSince = since
        if m.pressure == .critical || Date().timeIntervalSince(since) >= 60 { idleOverLines(critical: m.pressure == .critical) }
    }

    // macOS holds memory used under its ceiling by moving memory to swap, so a GB into swap within a minute marks
    // memory short for the two minutes that follow
    private func watchSwap(_ m: MemoryReading) -> Bool {
        let now = Date()
        swapSeen.append((now, m.swap))
        swapSeen.removeAll { now.timeIntervalSince($0.at) > 60 }
        if let low = swapSeen.map(\.swap).min(), m.swap - low >= gib { swapShortUntil = now.addingTimeInterval(120) }
        return now < swapShortUntil
    }

    // the memory alert: memory used past the line on its slider, or memory moving to swap, for a minute, then at most
    // once in 15 minutes
    private func alertOverLine(_ m: MemoryReading, swapping: Bool) {
        guard swapping || m.used >= memoryAlertLine * m.total else {
            memHighSince = nil
            return
        }
        let since = memHighSince ?? Date()
        memHighSince = since
        guard store.bool(forKey: "memoryAlerts"), Date().timeIntervalSince(since) >= 60,
              Date().timeIntervalSince(lastMemoryAlert) > 900 else { return }
        lastMemoryAlert = Date()
        let title = "Memory at \(gigabytes(m.used)) of \(Int((m.total / gib).rounded())) GB"
        postMemory(m, title: title, swapping: swapping)
    }

    // capped apps past their memory line idle while memory is short, so macOS squeezes their memory first. The app in
    // front stays live, and an app woken in the last 5 minutes stays awake unless pressure turns critical.
    private func idleOverLines(critical: Bool) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for entry in apps where entry.on {
            guard let app = running(entry.id) else { continue }
            let pid = app.processIdentifier
            guard pid != front, !isIdled(pid), canIdle(pid) else { continue }
            if !critical, let woke = autoWoken[entry.id], Date().timeIntervalSince(woke) < 300 { continue }
            let bytes = Limiter.tree(of: pid).reduce(0.0) { $0 + (footprint($1) ?? 0) }
            guard bytes > entry.line * gib else { continue }
            idle(pid)
            autoIdled[pid] = entry.id
            // the app's own notice stands in for the general memory alert this time
            lastMemoryAlert = Date()
            alerts.post("autoidle", title: "\(entry.name) idled",
                        body: "Memory is short and \(entry.name) holds \(gigabytes(bytes)), past its \(lineText(entry.line)) line. It wakes when you switch to it or memory eases.",
                        category: "autoIdle", info: ["pid": Int(pid)])
        }
    }
}
