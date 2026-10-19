import AppKit
import Carbon

// Connects the Touch Bar strip to the app: what it reads and what its buttons do

extension Menu {
    func setUpStrip() {
        strip.readout = { [weak self] in
            guard let self else { return [] }
            let temp = self.smc?.cpuTemperature(), fans = self.smc?.fans() ?? []
            let level = self.levels(temp, fans)
            var parts: [(text: String, tint: NSColor?)] = []
            if let temp { parts.append(("\(Int(temp.rounded()))°", level.temp.tint)) }
            if let fan = fans.max() { parts.append((grouped.string(from: NSNumber(value: Int(fan.rounded()))) ?? "", level.fan.tint)) }
            parts.append((percent(self.machineLoad), level.load.tint))
            return parts
        }
        strip.toggles = { [weak self] in
            guard let self else { return [:] }
            return ["awake": self.awake.isOn, "shrink": self.shrinker.isOn, "history": self.clips.isOn]
        }
        strip.setToggle = { [weak self] key, on in self?.apply(key, on) }
        strip.busiest = { [weak self] in self?.listedApps(snapshot()) ?? [] }
        strip.useOf = { [weak self] id in
            guard let app = self?.running(id) else { return nil }
            let snap = snapshot(), tree = Limiter.tree(of: app.processIdentifier)
            return Hog(name: app.localizedName ?? id, cpu: tree.reduce(0) { $0 + (snap.byPid[$1] ?? 0) },
                       memory: tree.reduce(0) { $0 + (footprint($1) ?? 0) }, app: app, pid: app.processIdentifier, mine: true)
        }
        strip.isCapped = { [weak self] hog in
            guard let self, let id = hog.app?.bundleIdentifier else { return false }
            return self.apps.contains { $0.id == id && $0.on }
        }
        strip.capHog = { [weak self] pid in self?.capHalf(pid) }
        strip.memory = { memoryReading().map { ($0.used, memoryLevel($0).tint) } }
        strip.idleState = { [weak self] pid in
            guard let self, self.canIdle(pid) else { return nil }
            return self.isIdled(pid)
        }
        strip.toggleIdle = { [weak self] pid in self?.toggleIdle(pid) }
        strip.clipItems = { [weak self] in self?.clips.history ?? [] }
        strip.copyClip = { [weak self] item in self?.clips.copy(item) }
        strip.cappedApps = { [weak self] in self?.apps ?? [] }
        strip.setCapLevel = { [weak self] id, level in
            guard let self, let i = self.apps.firstIndex(where: { $0.id == id }) else { return }
            self.apps[i].level = level
            saveApps(self.apps)
            self.applyApp(id)
        }
        strip.setCapOn = { [weak self] id, on in self?.apply("app:" + id, on) }
        strip.removeCapped = { [weak self] id in self?.removeCapped(id) }
        strip.setMemoryLine = { [weak self] id, line in
            guard let self, let i = self.apps.firstIndex(where: { $0.id == id }) else { return }
            self.apps[i].memoryLine = line
            saveApps(self.apps)
        }
        strip.details = { [weak self] in
            guard let self else { return [("–", nil), ("–", nil), ("–", nil)] }
            let temp = self.smc?.cpuTemperature(), fans = self.smc?.fans() ?? []
            let level = self.levels(temp, fans)
            let speeds = fans.map { grouped.string(from: NSNumber(value: Int($0.rounded()))) ?? "" }
            return [(temp.map { "\(Int($0.rounded())) °C" } ?? "–", level.temp.tint),
                    (speeds.joined(separator: " · ") + " RPM", level.fan.tint), (percent(self.machineLoad), level.load.tint)]
        }
        strip.shotLimit = { [weak self] in self?.shrinker.limit ?? 1500 }
        strip.setShotLimit = { [weak self] v in
            guard let self else { return }
            self.shrinker.limit = v
            store.set(v, forKey: "shotLimit")
            self.limitLabel?.stringValue = self.shrinkText(v)
        }
        if store.bool(forKey: "touchBar") { strip.show() }
        // ⌃⌥⌘C opens the strip from anywhere, whoever holds the Control Strip's slot
        if strip.available {
            stripKey = HotKey(keyCode: 8, modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
                guard let self, self.strip.isShown else { return }
                self.strip.open()
            }
        }
    }
}
