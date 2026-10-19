import AppKit

// Performance section: temperature, the fan, CPU load and memory used on one line, each coloured by its level
// (Levels.swift). The alerts, heat, CPU and memory, each with its line, sit near the end of the menu with no heading.

// the heat alert's line, set on its slider in steps of 5 °C
var heatLine: Double { store.double(forKey: "heatLine") }
let heatRange = 50.0...90.0

// the memory alert's line: memory used as a share of the Mac's memory, shown in GB
var memoryAlertLine: Double { store.double(forKey: "memoryAlertLine") }
let memoryAlertStops = stride(from: 25, through: 95, by: 5).map { Double($0) / 100 }
func memoryAlertText(_ share: Double) -> String {
    "\(Int((share * Double(ProcessInfo.processInfo.physicalMemory) / gib).rounded())) GB"
}

extension Menu {
    func addProcessorSection(_ snap: Snapshot) {
        // the heading carries Culpmit's own icon at its far right, its version on hover
        let head = kit.row("Performance", bold: true).item
        let mark = NSImageView(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.frame.size = NSSize(width: 18, height: 18)
        mark.toolTip = "Culpmit \(updater.installed)"
        kit.attach([mark], to: head)
        menu.addItem(head)
        // one line of boxes: temperature, the fan the menu bar shows, CPU load, memory used; a fanless Mac skips the fan
        let hasFans = !(smc?.fans() ?? []).isEmpty
        let temp = kit.valueField("–", template: "100 °C")
        let fan = kit.valueField("–", template: "8888 rpm")
        let load = kit.valueField("–", template: "100%")
        let memory = kit.valueField("–", template: "88.8/88 GB")
        tempLabel = temp
        fansLabel = hasFans ? fan : nil
        loadLabel = load
        memoryStatLabel = memory
        let tiles = StatTiles([("thermometer.medium", "Temperature", temp)] + (hasFans ? [("fan", "Fan speed", fan)] : [])
                              + [("gauge.with.dots.needle.50percent", "CPU load", load), ("memorychip", "Memory used", memory)],
                              size: kit.size)
        statTiles = tiles
        menu.addItem(kit.custom(tiles, need: tiles.need))
        menu.addItem(.separator())
    }

    // the alerts near the end with no heading, one row each: the name, its line on a slider while it is on, its switch
    func addAlertsSection() {
        let heatValue = kit.valueField(degrees(heatLine), template: degrees(heatRange.upperBound))
        heatLineLabel = heatValue
        let heatSlider = kit.slider(heatLine, heatRange.lowerBound, heatRange.upperBound, target: self, action: #selector(heatSlid(_:)))
        menu.addItem(lineRow("Heat alerts", "heatAlerts", store.bool(forKey: "heatAlerts"), heatSlider, heatValue))
        let cpuValue = kit.valueField(percent(cpuAlertLine), template: "100%")
        cpuLineLabel = cpuValue
        let cpuSlider = kit.slider(cpuAlertLine, cpuRange.lowerBound, cpuRange.upperBound, target: self, action: #selector(cpuSlid(_:)))
        menu.addItem(lineRow("CPU alerts", "cpuAlerts", store.bool(forKey: "cpuAlerts"), cpuSlider, cpuValue))
        let memoryValue = kit.valueField(memoryAlertText(memoryAlertLine), template: memoryAlertText(1))
        memoryAlertLabel = memoryValue
        let stop = Double(memoryAlertStops.firstIndex { $0 >= memoryAlertLine } ?? memoryAlertStops.count - 1)
        let memorySlider = kit.slider(stop, 0, Double(memoryAlertStops.count - 1), target: self, action: #selector(memoryAlertSlid(_:)))
        menu.addItem(lineRow("Memory alerts", "memoryAlerts", store.bool(forKey: "memoryAlerts"), memorySlider, memoryValue))
        menu.addItem(.separator())
    }

    // a switch row with its slider and value beside it, dimmed and still while it is off, so the switch shows what it
    // turns on; live keeps the slider usable while off, for a setting chosen before the switch
    func lineRow(_ title: String, _ key: String, _ on: Bool, _ slider: NSSlider, _ value: NSTextField, live: Bool = false) -> NSMenuItem {
        let item = kit.row(title).item
        // a shared least width lines the sliders up from row to row
        value.frame.size.width = max(value.frame.width, 64)
        // trailing controls sit from the right: the switch at the end, then the value, then the slider
        kit.attach([switchControl(key, on), value, slider], to: item)
        lineParts[key] = (slider, value, live)
        showLine(key, on)
        return item
    }

    func showLine(_ key: String, _ on: Bool) {
        guard let parts = lineParts[key] else { return }
        parts.slider.isEnabled = on || parts.live
        for v in [parts.slider, parts.value] as [NSView] { v.alphaValue = on ? 1 : 0.4 }
    }

    @objc func heatSlid(_ sender: NSSlider) {
        let line = (sender.doubleValue / 5).rounded() * 5
        sender.doubleValue = line
        heatLineLabel?.stringValue = degrees(line)
        store.set(line, forKey: "heatLine")
    }

    @objc func cpuSlid(_ sender: NSSlider) {
        let line = (sender.doubleValue / 5).rounded() * 5
        sender.doubleValue = line
        cpuLineLabel?.stringValue = percent(line)
        store.set(line, forKey: "cpuLine")
    }

    @objc func memoryAlertSlid(_ sender: NSSlider) {
        let stop = min(memoryAlertStops.count - 1, max(0, Int(sender.doubleValue.rounded())))
        sender.doubleValue = Double(stop)
        let share = memoryAlertStops[stop]
        memoryAlertLabel?.stringValue = memoryAlertText(share)
        store.set(share, forKey: "memoryAlertLine")
    }

    private func degrees(_ c: Double) -> String { "\(Int(c)) °C" }

    func tickProcessor(_ snap: Snapshot) {
        let temp = smc?.cpuTemperature(), fans = smc?.fans() ?? []
        let level = levels(temp, fans)
        tempLabel?.stringValue = temp.map { "\(Int($0.rounded())) °C" } ?? "–"
        statTiles?.paint(tempLabel, level.temp.tint)
        loadLabel?.stringValue = percent(machineLoad)
        statTiles?.paint(loadLabel, level.load.tint)
        fansLabel?.stringValue = fansText(fans)
        statTiles?.paint(fansLabel, level.fan.tint)
        if let m = memoryReading() {
            memoryStatLabel?.stringValue = String(format: "%.1f/%d GB", m.used / gib, Int((m.total / gib).rounded()))
            statTiles?.paint(memoryStatLabel, memoryLevel(m).tint)
            let tip = "Swap \(gigabytes(m.swap))"
            if memoryStatLabel?.toolTip != tip { memoryStatLabel?.toolTip = tip }
        }
        devCapLabel?.stringValue = "Dev server: " + snap.devCap
    }

    func checkHeat(_ temp: Double?) {
        guard store.bool(forKey: "heatAlerts"), let temp else { return }
        guard temp >= heatLine else {
            hotSince = nil
            return
        }
        let since = hotSince ?? Date()
        hotSince = since
        guard Date().timeIntervalSince(since) >= 60, Date().timeIntervalSince(lastHeatAlert) > 900 else { return }
        lastHeatAlert = Date()
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        postBusiest("heat", title: "\(Int(temp.rounded())) °C for \(minutes == 1 ? "1 minute" : "\(minutes) minutes")")
    }

    func handle(_ action: String, _ info: [AnyHashable: Any]) {
        let pid = (info["pid"] as? Int).map { pid_t($0) }
        switch action {
        case "cap":
            if let pid { capHalf(pid) }
        case "idle":
            if let pid { idle(pid) }
        case "wake":
            if let pid { wake(pid) }
        default: break
        }
    }
}
