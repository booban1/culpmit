import AppKit

// Everything off, the row after the Touch Bar's switch: it stops a running test, wakes idled apps and turns every
// switch and cap off, keeping a note of what was on; the row then reads Everything back, which turns those on again.
// The Touch Bar and Open at login stay as they are.

private let everythingKeys = ["awake", "shrink", "history", "heatAlerts", "cpuAlerts", "memoryAlerts", "radios", "backToSleep", "figmaSocket"]

extension Menu {
    func everythingItem() -> NSMenuItem {
        let back = store.array(forKey: "everythingBefore") != nil
        let item = NSMenuItem(title: back ? "Everything back" : "Everything off",
                              action: back ? #selector(everythingBack) : #selector(everythingOff), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: back ? "play.circle" : "pause.circle", accessibilityDescription: nil)
        return item
    }

    @objc func everythingOff() {
        stopTest()
        for pid in Array(idlers.keys) { wake(pid) }
        var before: [String] = []
        for key in everythingKeys where isOn(key) {
            before.append(key)
            apply(key, false)
        }
        for app in apps where app.on {
            before.append("app:" + app.id)
            apply("app:" + app.id, false)
        }
        if !before.isEmpty { store.set(before, forKey: "everythingBefore") }
    }

    @objc func everythingBack() {
        for key in (store.array(forKey: "everythingBefore") as? [String]) ?? [] { apply(key, true) }
        store.removeObject(forKey: "everythingBefore")
    }
}
