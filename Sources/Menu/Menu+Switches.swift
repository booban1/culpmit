import AppKit

// Every switch in the menu: built here, applied here, and kept in step with changes made elsewhere

extension Menu {
    func switchControl(_ key: String, _ on: Bool) -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .small
        s.state = on ? .on : .off
        s.target = self
        s.action = #selector(switched(_:))
        s.identifier = NSUserInterfaceItemIdentifier(key)
        s.sizeToFit()
        switches[key] = s
        return s
    }

    func toggle(_ text: String, _ key: String, _ on: Bool) -> NSMenuItem {
        let item = kit.row(text).item
        kit.attach([switchControl(key, on)], to: item)
        return item
    }

    @objc func switched(_ sender: NSSwitch) {
        apply(sender.identifier?.rawValue ?? "", sender.state == .on)
    }

    func apply(_ key: String, _ on: Bool) {
        // a running test holds its switches on until it ends
        if !on, testing, testHolds.contains(key) {
            tickSwitches()
            return
        }
        if key.hasPrefix("app:") {
            let id = String(key.dropFirst(4))
            if let i = apps.firstIndex(where: { $0.id == id }) {
                apps[i].on = on
                saveApps(apps)
                applyApp(id)
                dimCap(id, on: on)
            }
            return
        }
        switch key {
        case "shrink":
            store.set(on, forKey: "shrink")
            on ? shrinker.start() : shrinker.stop()
            showLine(key, on)
        case "awake": awake.set(on)
        case "testLoad":
            on ? startTest() : stopTest()
            showLine(key, testing)
        case "history":
            store.set(on, forKey: key)
            on ? clips.start() : clips.stop()
        case "radios":
            store.set(on, forKey: "radios")
            if on { askBluetooth() }
        case "login": openAtLogin = on
        case "heatAlerts", "cpuAlerts", "memoryAlerts":
            store.set(on, forKey: key)
            if on { alerts.ask() }
            showLine(key, on)
        case "backToSleep": store.set(on, forKey: key)
        case "figmaSocket":
            store.set(on, forKey: key)
            on ? figma.start() : figma.stop()
            figma.cachedListener = on ? figma.cachedListener : nil
        case "touchBar":
            store.set(on, forKey: key)
            on ? strip.show() : strip.hide()
        default: break
        }
    }

    // the first Bluetooth read brings macOS's question; it waits off the main thread so the app keeps running meanwhile
    func askBluetooth() {
        let radios = radios
        DispatchQueue.global(qos: .utility).async { _ = radios.bluetooth }
    }

    func tickSwitches() {
        switches["awake"]?.state = awake.isOn ? .on : .off
        switches["testLoad"]?.state = testing ? .on : .off
        switches["heatAlerts"]?.state = store.bool(forKey: "heatAlerts") ? .on : .off
        switches["cpuAlerts"]?.state = store.bool(forKey: "cpuAlerts") ? .on : .off
        switches["memoryAlerts"]?.state = store.bool(forKey: "memoryAlerts") ? .on : .off
        for key in testHolds {
            switches[key]?.isEnabled = !testing
            switches[key]?.toolTip = testing ? "On for Test load" : nil
        }
        switches["figmaSocket"]?.state = figma.isOn ? .on : .off
        switches["touchBar"]?.state = strip.isShown ? .on : .off
        switches["shrink"]?.state = shrinker.isOn ? .on : .off
        switches["history"]?.state = clips.isOn ? .on : .off
        for entry in apps {
            switches["app:" + entry.id]?.state = entry.on ? .on : .off
            if let slider = capSliders[entry.id], (slider.alphaValue == 1) != entry.on { dimCap(entry.id, on: entry.on) }
        }
    }
}
